import AppKit

/// All sheets and panels go through here so tests can answer them without putting UI on screen.
enum Presenter {
    /// Shows `alert` as a sheet on `window` (modal without a window); reports the button.
    static var alert: (NSAlert, NSWindow?, @escaping (NSApplication.ModalResponse) -> Void) -> Void = { alert, window, done in
        if let window {
            alert.beginSheetModal(for: window, completionHandler: done)
        } else {
            done(alert.runModal())
        }
    }

    /// Shows an open panel; reports the chosen URL or nil.
    static var openPanel: (NSOpenPanel, NSWindow?, @escaping (URL?) -> Void) -> Void = { panel, window, done in
        if let window {
            panel.beginSheetModal(for: window) { done($0 == .OK ? panel.url : nil) }
        } else {
            done(panel.runModal() == .OK ? panel.url : nil)
        }
    }

    /// Shows `popover` anchored to `rect` in `view`.
    static var popover: (NSPopover, NSRect, NSView, NSRectEdge) -> Void = { popover, rect, view, edge in
        popover.show(relativeTo: rect, of: view, preferredEdge: edge)
    }

    static func chooseDirectory(start: String?, prompt: String, message: String? = nil,
                                accessory: NSView? = nil, window: NSWindow?, done: @escaping (URL?) -> Void) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.prompt = prompt
        if let message { panel.message = message }
        panel.directoryURL = start.map { URL(fileURLWithPath: $0) }
        if let accessory {
            panel.accessoryView = accessory
            panel.isAccessoryViewDisclosed = true
        }
        openPanel(panel, window, done)
    }
}
