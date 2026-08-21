import Foundation

/// Shared mutable state for the switcher.
///
/// The state is shared between `Switcher` (event tap + conversion logic)
/// and `UIManager` (menu bar, panels, editors). Both hold a reference to
/// the same `SwitcherState` instance — this avoids circular dependencies
/// while keeping all state in one traceable place.
final class SwitcherState {

    // MARK: - Double-Shift detection

    var lastShiftPress: CFTimeInterval = 0
    var lastShiftRelease: CFTimeInterval = 0

    // MARK: - Conversion flags

    /// True while a conversion (backspace + retype) is in progress.
    /// Prevents re-entrant conversions and buffers real keystrokes.
    var busy = false

    /// True during synthetic backspace/type replacement. Real keystrokes
    /// are buffered in `pendingCharacters` and replayed after.
    var isReplacing = false

    /// Safety timeout: if isReplacing is true for longer than this, force-reset.
    /// Prevents keyboard from being permanently stuck if a completion never fires.
    var isReplacingSince: CFTimeInterval = 0
    static let isReplacingTimeout: CFTimeInterval = 3.0

    /// Generation token for async callback invalidation (BUG #4/#5 fix).
    /// Incremented on every invalidation event (timeout force-reset, .reset
    /// during isReplacing). Every async callback captures the generation at
    /// start and checks before modifying state — stale callbacks become no-ops.
    var generation: UInt64 = 0

    /// True once the event tap is active (permissions granted).
    var tapActive = false

    /// After converting a selection via clipboard — true. Another double-Shift
    /// (with nothing in between) undoes via Cmd+Z toggle.
    var lastWasSelectionConvert = false

    // MARK: - Auto-convert undo

    /// After auto-converting a word — stores info to undo. Double-Shift right
    /// after auto-convert reverts to the original text and layout.
    /// Any real (non-synthetic) keystroke cancels the undo window.
    var lastAutoConvertInfo: (
        original: String,
        backspaceCount: Int,
        undoToRussian: Bool,
        triggerWord: String
    )?

    /// Remembers recent auto-converted word pairs (original → converted).
    /// Survives real keystrokes (unlike `lastAutoConvertInfo`) so that when
    /// the user manually converts the result back via clipboard, we can
    /// detect it and add the trigger word to exceptions.
    var recentAutoConvertedWords: [(original: String, converted: String)] = []
    let maxRecentAutoWords = 20

    /// Characters typed during replacement (isReplacing) are buffered here
    /// and replayed after the replacement completes. Without this, fast
    /// typists' keystrokes land in wrong positions.
    var pendingCharacters = ""

    // MARK: - Settings (loaded from UserDefaults)

    /// Auto-learn: if user undoes an auto-conversion, add the word to
    /// the exceptions list automatically (Caramba-style).
    var autoLearnExceptions = true

    /// Auto mode (Punto Switcher style): automatically converts words
    /// at word boundaries using NSSpellChecker.
    var autoModeEnabled = false

    // MARK: - Typing tracking

    /// A secure field (password) is focused: we neither listen nor convert it.
    var secureField = false

    /// Typing buffer: remembers what the user typed (like Punto/Caramba).
    /// This lets us erase with Backspaces and retype the converted text in
    /// ANY app (VS Code, Slack included) — no Accessibility needed.
    var typedBuffer = ""

    /// True when typedBuffer contains converted text from a previous
    /// conversion (for toggle-back). New typing clears it — the user is
    /// typing a NEW fragment, not continuing the converted one.
    /// Without this, converted text pollutes the buffer and the next
    /// conversion sees stale data (e.g. «если» leaking into «масяськи»).
    var typedBufferIsFromConversion = false

    // MARK: - Event tap retry

    var tapRetryTimer: Timer?
}
