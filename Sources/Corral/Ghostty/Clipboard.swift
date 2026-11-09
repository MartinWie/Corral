import AppKit
import GhosttyKit
import UniformTypeIdentifiers

/// Clipboard callbacks for libghostty (paste, OSC 52 read/write with confirmation).
enum Clipboard {
    struct Content {
        var mime: String
        var data: Data
    }

    static let selectionPasteboard = NSPasteboard(name: NSPasteboard.Name("dev.corral.selection"))

    static func pasteboard(_ location: ghostty_clipboard_e) -> NSPasteboard? {
        switch location {
        case GHOSTTY_CLIPBOARD_STANDARD: return .general
        case GHOSTTY_CLIPBOARD_SELECTION: return selectionPasteboard
        default: return nil
        }
    }

    private static func view(_ userdata: UnsafeMutableRawPointer?) -> TerminalView? {
        guard let userdata else { return nil }
        return Unmanaged<TerminalView>.fromOpaque(userdata).takeUnretainedValue()
    }

    static func data(_ pb: NSPasteboard, mime: String) -> Data? {
        switch mime {
        case "text/plain":
            if let urls = pb.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL],
               !urls.isEmpty {
                return Data(urls.map { shellEscapePath($0.path) }.joined(separator: " ").utf8)
            }
            return pb.string(forType: .string).map { Data($0.utf8) }
        case "text/uri-list":
            let urls = pb.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
            guard !urls.isEmpty else { return nil }
            return Data(urls.map { $0.absoluteString + "\r\n" }.joined().utf8)
        default:
            guard let type = UTType(mimeType: mime) else { return nil }
            return pb.data(forType: NSPasteboard.PasteboardType(type.identifier))
        }
    }

    static func availableMimes(_ pb: NSPasteboard) -> [String] {
        var out: [String] = []
        let types = pb.types ?? []
        if types.contains(.string) || types.contains(.fileURL) { out.append("text/plain") }
        if types.contains(.fileURL) { out.append("text/uri-list") }
        for t in types {
            if let mime = UTType(t.rawValue)?.preferredMIMEType, !out.contains(mime), mime != "text/plain;charset=utf-8" {
                out.append(mime)
            }
        }
        return out
    }

    static func read(_ userdata: UnsafeMutableRawPointer?, location: ghostty_clipboard_e,
                     state: UnsafeMutableRawPointer?, mimes: UnsafePointer<UnsafePointer<CChar>?>?,
                     mimesLen: Int, list: Bool) -> ghostty_clipboard_read_result_e {
        guard let view = view(userdata), let surface = view.surface, let pb = pasteboard(location) else {
            return GHOSTTY_CLIPBOARD_READ_UNSUPPORTED
        }
        var contents: [Content] = []
        var seen = Set<String>()
        if let mimes {
            for i in 0..<mimesLen {
                guard let p = mimes[i] else { continue }
                let mime = String(cString: p)
                guard seen.insert(mime).inserted, let d = data(pb, mime: mime) else { continue }
                contents.append(Content(mime: mime, data: d))
            }
        }
        let available = list ? availableMimes(pb) : []
        if contents.isEmpty && !list { return GHOSTTY_CLIPBOARD_READ_UNAVAILABLE }
        complete(surface, contents: contents, available: available, state: state)
        return GHOSTTY_CLIPBOARD_READ_STARTED
    }

    static func confirmRead(_ userdata: UnsafeMutableRawPointer?, confirm: UnsafePointer<ghostty_clipboard_confirm_s>?,
                            state: UnsafeMutableRawPointer?, request: ghostty_clipboard_request_e) {
        guard let view = view(userdata), let surface = view.surface else { return }
        guard let confirm else { ghostty_surface_deny_clipboard_request(surface, state); return }
        let c = confirm.pointee
        var reps: [Content] = []
        if let list = c.contents {
            for i in 0..<c.contents_len {
                let item = list[i]
                let d = item.len > 0 && item.data != nil ? Data(bytes: item.data, count: item.len) : Data()
                reps.append(Content(mime: String(cString: item.mime), data: d))
            }
        }
        var avail: [String] = []
        if let a = c.available {
            for i in 0..<c.available_len { if let p = a[i] { avail.append(String(cString: p)) } }
        }
        // Show what is shared even when it isn't text (images etc.).
        let preview = reps.first { $0.mime == "text/plain" }.map { String(decoding: $0.data, as: UTF8.self) }
            ?? reps.map { "\($0.mime), \($0.data.count) bytes" }.joined(separator: "\n")
        let title: String
        switch request {
        case GHOSTTY_CLIPBOARD_REQUEST_PASTE: title = "Paste text that may run commands?"
        default: title = "Allow the terminal program to read the clipboard?"
        }
        DispatchQueue.main.async {
            let alert = NSAlert()
            alert.messageText = title
            alert.informativeText = String(preview.prefix(600))
            alert.addButton(withTitle: "Allow")
            alert.addButton(withTitle: "Deny")
            let finish: (Bool) -> Void = { ok in
                guard let surface = view.surface else { return }
                if ok {
                    complete(surface, contents: reps, available: avail, state: state, confirmed: true)
                } else {
                    ghostty_surface_deny_clipboard_request(surface, state)
                }
            }
            if let window = view.window {
                alert.beginSheetModal(for: window) { finish($0 == .alertFirstButtonReturn) }
            } else {
                finish(alert.runModal() == .alertFirstButtonReturn)
            }
        }
    }

    static func write(_ userdata: UnsafeMutableRawPointer?, location: ghostty_clipboard_e,
                      content: UnsafePointer<ghostty_clipboard_content_s>?, len: Int, confirm: Bool) {
        guard let pb = pasteboard(location), let content, len > 0 else { return }
        var items: [Content] = []
        for i in 0..<len {
            let c = content[i]
            guard let mimeP = c.mime else { continue }
            let d = c.len > 0 && c.data != nil ? Data(bytes: c.data, count: c.len) : Data()
            items.append(Content(mime: String(cString: mimeP), data: d))
        }
        guard !items.isEmpty else { return }
        let apply = {
            pb.clearContents()
            for item in items {
                if item.mime == "text/plain" || item.mime.hasPrefix("text/plain;") {
                    pb.setString(String(decoding: item.data, as: UTF8.self), forType: .string)
                } else if let type = UTType(mimeType: item.mime) {
                    pb.setData(item.data, forType: NSPasteboard.PasteboardType(type.identifier))
                }
            }
        }
        guard confirm else { apply(); return }
        // Confirmation can only show text; refuse rather than approve something invisible.
        guard let text = items.first(where: { $0.mime.hasPrefix("text/plain") }).map({ String(decoding: $0.data, as: UTF8.self) }) else { return }
        let window = view(userdata)?.window
        DispatchQueue.main.async {
            let alert = NSAlert()
            alert.messageText = "Allow the terminal program to set the clipboard?"
            alert.informativeText = String(text.prefix(600))
            alert.addButton(withTitle: "Allow")
            alert.addButton(withTitle: "Deny")
            if let window {
                alert.beginSheetModal(for: window) { if $0 == .alertFirstButtonReturn { apply() } }
            } else if alert.runModal() == .alertFirstButtonReturn {
                apply()
            }
        }
    }

    static func complete(_ surface: ghostty_surface_t, contents: [Content], available: [String],
                         state: UnsafeMutableRawPointer?, confirmed: Bool = false) {
        var strings: [UnsafeMutablePointer<CChar>] = []
        var buffers: [UnsafeMutableRawPointer] = []
        defer {
            strings.forEach { free($0) }
            buffers.forEach { $0.deallocate() }
        }
        var cContents: [ghostty_clipboard_content_s] = []
        for entry in contents {
            guard let mime = strdup(entry.mime) else { continue }
            strings.append(mime)
            let buf = UnsafeMutableRawPointer.allocate(byteCount: max(entry.data.count, 1), alignment: 1)
            buffers.append(buf)
            entry.data.withUnsafeBytes { src in
                if let base = src.baseAddress { buf.copyMemory(from: base, byteCount: src.count) }
            }
            cContents.append(ghostty_clipboard_content_s(
                mime: mime, data: buf.assumingMemoryBound(to: CChar.self), len: entry.data.count))
        }
        var cAvailable: [UnsafePointer<CChar>?] = []
        for mime in available {
            guard let s = strdup(mime) else { continue }
            strings.append(s)
            cAvailable.append(UnsafePointer(s))
        }
        cContents.withUnsafeBufferPointer { cb in
            cAvailable.withUnsafeBufferPointer { ab in
                var complete = ghostty_clipboard_complete_s(
                    contents: cb.baseAddress, contents_len: cb.count,
                    available: ab.baseAddress, available_len: ab.count,
                    confirmed: confirmed, remember: false)
                ghostty_surface_complete_clipboard_request(surface, &complete, state)
            }
        }
    }

    static func shellEscapePath(_ path: String) -> String {
        var out = ""
        for ch in path {
            if " \\'\"()[]{}<>&;|*?$`!#~".contains(ch) { out.append("\\") }
            out.append(ch)
        }
        return out
    }
}
