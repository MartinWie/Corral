import AppKit

/// A shortcut as an NSMenuItem stores it: the unshifted key ("k", "]", "1", "\r", an arrow's function-key
/// character) plus ⌃⌥⇧⌘. ⇧⌘] is ("]", ⇧⌘), like the menu's own defaults.
struct KeyCombo: Hashable {
    static let modifierMask: NSEvent.ModifierFlags = [.control, .option, .shift, .command]

    let key: String
    let modsRaw: UInt

    init(key: String, mods: NSEvent.ModifierFlags) {
        self.key = key.lowercased()
        // An uppercase letter key equivalent implies ⇧ (NSMenuItem semantics).
        let shift: NSEvent.ModifierFlags = key != key.lowercased() ? .shift : []
        self.modsRaw = mods.union(shift).intersection(Self.modifierMask).rawValue
    }

    var mods: NSEvent.ModifierFlags { NSEvent.ModifierFlags(rawValue: modsRaw) }

    var display: String { KeyHint.format(key, mods) }

    init?(item: NSMenuItem) {
        guard !item.keyEquivalent.isEmpty else { return nil }
        self.init(key: item.keyEquivalent, mods: item.keyEquivalentModifierMask)
    }

    /// The combo a key press records, or nil for a press without a usable key. The key is read as typed
    /// without modifiers in the current layout, so ⌥ or ⇧ never turn it into another character.
    init?(event: NSEvent) {
        guard event.type == .keyDown else { return nil }
        var key = event.characters(byApplyingModifiers: []) ?? ""
        if key.isEmpty || key.unicodeScalars.count != 1 { key = event.charactersIgnoringModifiers ?? "" }
        guard key.unicodeScalars.count == 1 else { return nil }
        switch key {
        case "\u{7f}": key = "\u{8}"  // the delete key types DEL; menus spell it backspace
        case "\u{3}": key = "\r"      // keypad enter
        default: break
        }
        guard Self.isUsable(key) else { return nil }
        self.init(key: key, mods: event.modifierFlags)
    }

    /// Keys menus and Ghostty both name: not function-key characters outside the named set (F21+, Clear,
    /// Insert…), not `>` (Ghostty's key-sequence separator).
    static func isUsable(_ key: String) -> Bool {
        guard let v = key.unicodeScalars.first?.value else { return false }
        if key == ">" { return false }
        guard (0xF700...0xF8FF).contains(v) else { return true }
        return functionKeyNumber(key) != nil || ghosttyKey(key) != key
    }

    /// Stored form: "<modifier bits>|<key>".
    var encoded: String { "\(modsRaw)|\(key)" }

    init?(encoded: String) {
        guard let bar = encoded.firstIndex(of: "|"), let raw = UInt(encoded[..<bar]) else { return nil }
        let key = String(encoded[encoded.index(after: bar)...])
        guard key.unicodeScalars.count == 1 else { return nil }
        self.init(key: key, mods: NSEvent.ModifierFlags(rawValue: raw))
    }

    var isFunctionKey: Bool { Self.functionKeyNumber(key) != nil }

    /// F1… F20 → 1… 20.
    static func functionKeyNumber(_ key: String) -> Int? {
        guard let v = key.unicodeScalars.first?.value, key.unicodeScalars.count == 1,
              v >= UInt32(NSF1FunctionKey), v <= UInt32(NSF20FunctionKey) else { return nil }
        return Int(v) - NSF1FunctionKey + 1
    }

    /// The same combo as Ghostty triggers (`super+shift+k`), for unbinding it in terminals. Digits come
    /// twice: Ghostty binds ⌘1… both by character and by physical key (`digit_1`), for AZERTY.
    var ghosttyTriggers: [String] {
        var parts: [String] = []
        if mods.contains(.control) { parts.append("ctrl") }
        if mods.contains(.option) { parts.append("alt") }
        if mods.contains(.shift) { parts.append("shift") }
        if mods.contains(.command) { parts.append("super") }
        var keys = [Self.ghosttyKey(key)]
        if key.count == 1, let c = key.first, c.isASCII, let d = c.wholeNumberValue { keys.append("digit_\(d)") }
        return keys.map { (parts + [$0]).joined(separator: "+") }
    }

    static func ghosttyKey(_ key: String) -> String {
        if let n = functionKeyNumber(key) { return "f\(n)" }
        switch key {
        case "\r": return "enter"
        case "\t": return "tab"
        case "\u{8}": return "backspace"
        case "\u{1b}": return "escape"
        case " ": return "space"
        case String(UnicodeScalar(NSUpArrowFunctionKey)!): return "arrow_up"
        case String(UnicodeScalar(NSDownArrowFunctionKey)!): return "arrow_down"
        case String(UnicodeScalar(NSLeftArrowFunctionKey)!): return "arrow_left"
        case String(UnicodeScalar(NSRightArrowFunctionKey)!): return "arrow_right"
        case String(UnicodeScalar(NSHomeFunctionKey)!): return "home"
        case String(UnicodeScalar(NSEndFunctionKey)!): return "end"
        case String(UnicodeScalar(NSPageUpFunctionKey)!): return "page_up"
        case String(UnicodeScalar(NSPageDownFunctionKey)!): return "page_down"
        case String(UnicodeScalar(NSDeleteFunctionKey)!): return "delete"
        default: return key  // single characters are Ghostty unicode triggers ("super+]", "super++")
        }
    }
}

/// One command whose shortcut can be changed: a main-menu item, or the numbered Session 1–9 items
/// together (they share one set of modifiers; the digits stay).
struct ShortcutAction: Equatable {
    let id: String
    let title: String
    let section: String
    /// In the menu but hidden (Import from claude-sessions without the tracker): its shortcut is kept,
    /// the Shortcuts page doesn't list it.
    var hidden = false
    var isNumbered: Bool { id == ShortcutStore.numberedId }
}

extension Notification.Name {
    /// Posted after the main menu's shortcuts changed; hint labels and tooltips re-read the menu.
    static let corralShortcutsChanged = Notification.Name("CorralShortcutsChanged")
}

/// User shortcuts layered over the menu's built-in ones. Overrides live in UserDefaults; the menu is the
/// single place they take effect (every hint in the app reads the menu), so applying means rewriting its
/// key equivalents. A shortcut that is taken moves: the command that had it is left without one.
final class ShortcutStore {
    enum Override: Equatable {
        case cleared
        case set(KeyCombo)
    }

    enum Outcome: Equatable {
        /// Applied; `displaced` lost their shortcut to it.
        case accepted(displaced: [String])
        case rejected(String)
    }

    static let defaultsKey = "CorralShortcuts"
    static let numbered = #selector(MainWindowController.selectSessionByNumber(_:))
    static let numberedId = NSStringFromSelector(numbered)
    static let numberedKeys = (1...9).map(String.init)

    /// Standard macOS commands keep their shortcuts; their combos can't be taken.
    static let fixed: Set<Selector> = [
        #selector(NSApplication.orderFrontStandardAboutPanel(_:)),
        #selector(NSText.copy(_:)), #selector(NSText.paste(_:)), #selector(NSResponder.selectAll(_:)),
        #selector(NSApplication.hide(_:)), #selector(NSApplication.hideOtherApplications(_:)),
        #selector(NSApplication.terminate(_:)), #selector(NSWindow.performMiniaturize(_:)),
        #selector(NSWindow.performZoom(_:)), #selector(NSWindow.toggleFullScreen(_:)),
    ]

    /// Combos macOS or text editing own, outside Corral's menu.
    static let system: [KeyCombo: String] = [
        KeyCombo(key: "x", mods: .command): "Cut",
        KeyCombo(key: "z", mods: .command): "Undo",
        KeyCombo(key: "z", mods: [.command, .shift]): "Redo",
        KeyCombo(key: "`", mods: .command): "macOS window switching",
        KeyCombo(key: "\t", mods: .command): "the app switcher",
        KeyCombo(key: " ", mods: .command): "Spotlight",
        KeyCombo(key: "q", mods: [.command, .control]): "Lock Screen",
        KeyCombo(key: "3", mods: [.command, .shift]): "Screenshot",
        KeyCombo(key: "4", mods: [.command, .shift]): "Screenshot",
        KeyCombo(key: "5", mods: [.command, .shift]): "Screenshot",
        KeyCombo(key: "3", mods: [.command, .shift, .control]): "Screenshot",
        KeyCombo(key: "4", mods: [.command, .shift, .control]): "Screenshot",
    ]

    let defaults: UserDefaults
    private(set) var actions: [ShortcutAction] = []
    /// Built-in shortcuts, read from the freshly built menu.
    private(set) var builtIn: [String: KeyCombo] = [:]
    private(set) var overrides: [String: Override] = [:]
    /// Combos of fixed menu items and the system, with the name a rejection shows.
    private var reserved: [KeyCombo: String] = system
    private weak var menu: NSMenu?
    /// Runs after every change (the app reloads the terminals' key bindings).
    var onChange: ((ShortcutStore) -> Void)?

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        load()
    }

    static func id(_ item: NSMenuItem) -> String? {
        guard let action = item.action, !fixed.contains(action) else { return nil }
        if action == numbered { return numberedId }
        return item.tag == 0 ? NSStringFromSelector(action) : "\(NSStringFromSelector(action))#\(item.tag)"
    }

    // MARK: Menu

    /// Reads the commands and their built-in shortcuts from a freshly built `menu`, then applies the
    /// user's shortcuts to it. Later changes rewrite this menu.
    func register(_ menu: NSMenu) {
        self.menu = menu
        actions = []
        builtIn = [:]
        reserved = Self.system
        var seen = Set<String>()
        for top in menu.items {
            guard let sub = top.submenu else { continue }
            for item in sub.items where !item.isSeparatorItem {
                guard let action = item.action else { continue }
                guard let id = Self.id(item) else {
                    if Self.fixed.contains(action), let c = KeyCombo(item: item) { reserved[c] = Self.title(item) }
                    continue
                }
                if id == Self.numberedId, item.tag != 1 { continue }
                guard seen.insert(id).inserted else { continue }
                let title = id == Self.numberedId ? "Session by Number" : Self.title(item)
                actions.append(ShortcutAction(id: id, title: title, section: top.title, hidden: item.isHidden))
                if let c = KeyCombo(item: item) { builtIn[id] = c }
            }
        }
        sanitize()
        apply()
    }

    /// Stored shortcuts against today's menu: commands that are gone and combos that became reserved
    /// are dropped; a new built-in shortcut that collides with one the user chose gives way to it.
    private func sanitize() {
        var dirty = false
        var dropped: [KeyCombo] = []
        for (id, o) in overrides {
            let known = actions.contains { $0.id == id }
            guard !known || { if case .set(let c) = o { return problem(c, for: id) != nil } else { return false } }() else { continue }
            overrides[id] = nil
            dirty = true
            if case .set(let c) = o { dropped.append(c) }
        }
        // A dropped shortcut had taken its key from another command: that one gets it back.
        for c in dropped {
            for a in actions where overrides[a.id] == .cleared && builtIn[a.id] == c { overrides[a.id] = nil }
        }
        var claimed = Set<KeyCombo>()
        for (id, o) in overrides { if case .set(let c) = o { claimed.formUnion(combos(for: id, c)) } }
        for a in actions where overrides[a.id] == nil {
            guard !claimed.isDisjoint(with: combos(for: a.id, builtIn[a.id])) else { continue }
            overrides[a.id] = .cleared
            dirty = true
        }
        if dirty { save() }
    }

    static func title(_ item: NSMenuItem) -> String {
        var t = item.title
        if t.hasSuffix("…") { t.removeLast() }
        return t
    }

    /// Writes the effective shortcuts into the menu's key equivalents.
    func apply() {
        guard let menu else { return }
        func walk(_ m: NSMenu) {
            for item in m.items {
                if let sub = item.submenu { walk(sub) }
                guard let id = Self.id(item), actions.contains(where: { $0.id == id }) else { continue }
                var c = combo(for: id)
                if id == Self.numberedId {
                    c = c.map { KeyCombo(key: "\(item.tag)", mods: $0.mods) }
                }
                let key = c?.key ?? ""
                let mods = c?.mods ?? []
                if item.keyEquivalent != key { item.keyEquivalent = key }
                if item.keyEquivalentModifierMask != mods { item.keyEquivalentModifierMask = mods }
            }
        }
        walk(menu)
    }

    // MARK: Reading

    /// The shortcut in effect (for Session by Number: the one for Session 1).
    func combo(for id: String) -> KeyCombo? {
        switch overrides[id] {
        case .cleared: return nil
        case .set(let c): return c
        case nil: return builtIn[id]
        }
    }

    func isCustomized(_ id: String) -> Bool { overrides[id] != nil }

    var hasOverrides: Bool { !overrides.isEmpty }

    func action(_ id: String) -> ShortcutAction? { actions.first { $0.id == id } }

    /// Every key press a command answers to (Session by Number: all nine).
    private func combos(for id: String, _ c: KeyCombo?) -> [KeyCombo] {
        guard let c else { return [] }
        return id == Self.numberedId ? Self.numberedKeys.map { KeyCombo(key: $0, mods: c.mods) } : [c]
    }

    /// Terminal bindings on keys that Corral's shortcuts moved to or away from: unbound, so the moved
    /// shortcut works over a terminal and a freed key reaches the terminal instead of a Ghostty action.
    var ghosttyUnbinds: [String] {
        var triggers = Set<String>()
        for id in overrides.keys {
            for c in combos(for: id, builtIn[id]) + combos(for: id, combo(for: id)) { triggers.formUnion(c.ghosttyTriggers) }
        }
        return triggers.sorted()
    }

    // MARK: Changing

    /// Why `combo` can't be `id`'s shortcut, or nil when it can.
    func problem(_ combo: KeyCombo, for id: String) -> String? {
        if id == Self.numberedId, !Self.numberedKeys.contains(combo.key) {
            return "Press a number key"
        }
        if !combo.mods.contains(.command), !combo.isFunctionKey {
            return "Needs ⌘ (⌃ and ⌥ belong to the terminal)"
        }
        // The terminal view hands ⌃↩ to the terminal before the menu sees it (as Ghostty.app does).
        if combo.key == "\r", combo.mods.contains(.control) { return "⌃↩ belongs to the terminal" }
        for c in combos(for: id, combo) {
            if let name = reserved[c] { return "\(c.display) is \(name)" }
            if id != Self.numberedId, Self.numberedKeys.contains(c.key),
               let mine = self.combo(for: Self.numberedId), mine.mods == c.mods {
                return "\(c.display) is \(c.key == "9" ? "Last Session" : "Session \(c.key)")"
            }
        }
        return nil
    }

    /// Makes `combo` the shortcut of `id` (nil: no shortcut). A command that had it loses its shortcut.
    @discardableResult
    func set(_ combo: KeyCombo?, for id: String) -> Outcome {
        guard actions.contains(where: { $0.id == id }) else { return .rejected("Unknown command") }
        var displaced: [String] = []
        if let combo {
            if let p = problem(combo, for: id) { return .rejected(p) }
            let wanted = Set(combos(for: id, combo))
            for other in actions where other.id != id {
                guard !wanted.isDisjoint(with: combos(for: other.id, self.combo(for: other.id))) else { continue }
                overrides[other.id] = builtIn[other.id] == nil ? nil : .cleared
                displaced.append(other.id)
            }
            let value = id == Self.numberedId ? KeyCombo(key: "1", mods: combo.mods) : combo
            overrides[id] = value == builtIn[id] ? nil : .set(value)
        } else {
            overrides[id] = builtIn[id] == nil ? nil : .cleared
        }
        changed()
        return .accepted(displaced: displaced)
    }

    /// Back to the built-in shortcut (taking it back from a command that has it now).
    @discardableResult
    func reset(_ id: String) -> Outcome {
        guard isCustomized(id) else { return .accepted(displaced: []) }
        return set(builtIn[id], for: id)
    }

    /// Every command back to its built-in shortcut; returns the ones that changed.
    @discardableResult
    func resetAll() -> [String] {
        let ids = Array(overrides.keys)
        guard !ids.isEmpty else { return [] }
        overrides = [:]
        changed()
        return ids
    }

    private func changed() {
        save()
        apply()
        onChange?(self)
        NotificationCenter.default.post(name: .corralShortcutsChanged, object: self)
    }

    // MARK: Persistence

    private func load() {
        guard let stored = defaults.dictionary(forKey: Self.defaultsKey) as? [String: String] else { return }
        for (id, value) in stored {
            if value.isEmpty {
                overrides[id] = .cleared
            } else if let c = KeyCombo(encoded: value) {
                overrides[id] = .set(c)
            }
        }
    }

    private func save() {
        var out: [String: String] = [:]
        for (id, o) in overrides {
            switch o {
            case .cleared: out[id] = ""
            case .set(let c): out[id] = c.encoded
            }
        }
        if out.isEmpty { defaults.removeObject(forKey: Self.defaultsKey) } else { defaults.set(out, forKey: Self.defaultsKey) }
    }
}
