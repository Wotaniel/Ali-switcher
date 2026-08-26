import Foundation

/// Log levels for filtered logging. Higher rawValue = more important.
/// Set via UserDefaults: `defaults write com.aliswitcher.AliSwitcher logLevel -int 0` (debug)
enum LogLevel: Int, Comparable {
    case debug = 0
    case info  = 1
    case warn  = 2
    case error = 3

    var prefix: String {
        switch self {
        case .debug: return "DEBUG"
        case .info:  return "INFO "
        case .warn:  return "WARN "
        case .error: return "ERROR"
        }
    }

    static func < (lhs: LogLevel, rhs: LogLevel) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

/// Thread-safe logger with levels and file rotation.
///
/// Writes to `~/Library/Logs/AliSwitcher.log`. When the file exceeds 1 MB,
/// it rotates: `.log → .1.log → .2.log` (oldest is deleted). Max 3 files.
///
/// Minimum level is read from UserDefaults key `logLevel` (rawValue).
/// Default: `.info`. Set to `0` for debug output:
/// ```
/// defaults write com.aliswitcher.AliSwitcher logLevel -int 0
/// ```
final class Logger {
    static let shared = Logger()

    private let logURL: URL
    private let maxFileSize: Int = 1_048_576  // 1 MB
    private let maxFiles: Int = 3
    private let queue = DispatchQueue(label: "AliSwitcher.Logger")

    /// Minimum level to log. Read from UserDefaults each time so the
    /// user can change it without restarting the app.
    private var minLevel: LogLevel {
        // Default to .info if not explicitly set.
        // UserDefaults.integer returns 0 (= .debug) for missing keys,
        // so we check if the key actually exists.
        if let raw = UserDefaults.standard.object(forKey: "logLevel") as? Int {
            return LogLevel(rawValue: raw) ?? .info
        }
        return .info
    }

    private init() {
        let dir = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask).first!
            .appendingPathComponent("Logs", isDirectory: true)
        logURL = dir.appendingPathComponent("AliSwitcher.log")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    func log(_ message: String, level: LogLevel = .info) {
        guard level >= minLevel else { return }
        let timestamp = String(format: "%.3f", Date().timeIntervalSince1970)
        let line = "[\(timestamp)] \(level.prefix) \(message)\n"
        guard let data = line.data(using: .utf8) else { return }
        queue.sync {
            rotateIfNeeded()
            if let handle = try? FileHandle(forWritingTo: logURL) {
                defer { try? handle.close() }
                handle.seekToEndOfFile()
                handle.write(data)
            } else {
                try? data.write(to: logURL)
            }
        }
    }

    /// Rotates log files when the current file exceeds `maxFileSize`.
    /// `.2.log` is deleted, `.1.log → .2.log`, `.log → .1.log`.
    private func rotateIfNeeded() {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: logURL.path),
              let size = attrs[.size] as? Int,
              size >= maxFileSize else { return }

        // Build base path without extension: .../AliSwitcher
        let basePath = logURL.deletingPathExtension().path

        // Delete the oldest file (.2.log if maxFiles=3, since .log and .1.log are the other two)
        let oldest = "\(basePath).\(maxFiles - 1).log"
        try? FileManager.default.removeItem(atPath: oldest)

        // Shift: .1.log → .2.log, .log → .1.log
        for i in stride(from: maxFiles - 2, through: 0, by: -1) {
            let current: URL
            if i == 0 {
                current = logURL  // .log (no number)
            } else {
                current = URL(fileURLWithPath: "\(basePath).\(i).log")
            }
            let next = URL(fileURLWithPath: "\(basePath).\(i + 1).log")
            try? FileManager.default.moveItem(at: current, to: next)
        }
    }
}

// MARK: - Global convenience (backward compatible)

/// Logs at `.info` level. Existing `log("message")` calls stay unchanged.
func log(_ message: String) {
    Logger.shared.log(message, level: .info)
}

/// Logs at the specified level: `log(.debug, "verbose detail")`.
func log(_ level: LogLevel, _ message: String) {
    Logger.shared.log(message, level: level)
}
