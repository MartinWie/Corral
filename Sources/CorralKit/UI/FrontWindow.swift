import AppKit

/// ⌘W ("Close Session") while a window other than the main one is in front: that window closes,
/// never the session behind it. The About panel never becomes main, so ⌘W there reached the session.
enum FrontWindow {
    /// True when ⌘W was taken care of: `key` closed (or cancelled, for panels without a close
    /// button such as search), or refused with a beep while a sheet is up (closing a sheet directly
    /// would skip `endSheet` and leave its parent modal).
    static func close(key: NSWindow?, main: NSWindow?) -> Bool {
        if main?.attachedSheet != nil || key?.sheetParent != nil {
            NSSound.beep()
            return true
        }
        guard let key, key !== main else { return false }
        if key.styleMask.contains(.closable) { key.performClose(nil) } else { key.cancelOperation(nil) }
        return true
    }
}
