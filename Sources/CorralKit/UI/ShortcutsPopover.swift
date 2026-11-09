import AppKit

/// One group of the keyboard-shortcuts sheet (a top-level menu).
struct ShortcutSection: Equatable {
    struct Row: Equatable {
        var name: String
        var keys: String
    }

    var title: String
    var rows: [Row]
}

/// Corral's shortcuts, read from the main menu so the sheet never drifts from the real bindings.
enum ShortcutList {
    /// Standard macOS commands, window management and the sheet itself (named in its footer), left
    /// out to keep the sheet about Corral.
    static let skipped: Set<Selector> = [
        #selector(NSText.copy(_:)), #selector(NSText.paste(_:)), #selector(NSResponder.selectAll(_:)),
        #selector(NSApplication.hide(_:)), #selector(NSApplication.hideOtherApplications(_:)),
        #selector(NSApplication.terminate(_:)), #selector(NSWindow.performMiniaturize(_:)),
        #selector(NSWindow.performZoom(_:)), #selector(NSWindow.toggleFullScreen(_:)),
        #selector(AppDelegate.showMain(_:)), #selector(MainWindowController.showShortcuts(_:)),
    ]

    /// Splits sections into two columns of about equal height, keeping their order.
    static func columns(_ sections: [ShortcutSection]) -> [[ShortcutSection]] {
        let weight = { (s: ShortcutSection) in s.rows.count + 2 }  // header ≈ two rows of height
        let total = sections.map(weight).reduce(0, +)
        var left: [ShortcutSection] = [], used = 0
        for s in sections {
            if !left.isEmpty, used + weight(s) / 2 > total / 2 { break }
            left.append(s)
            used += weight(s)
        }
        let right = Array(sections.dropFirst(left.count))
        return right.isEmpty ? [left] : [left, right]
    }

    static func sections(from menu: NSMenu) -> [ShortcutSection] {
        menu.items.compactMap { top -> ShortcutSection? in
            guard let sub = top.submenu else { return nil }
            var rows: [ShortcutSection.Row] = []
            var run: [NSMenuItem] = []
            func flush() {
                guard let first = run.first, let last = run.last else { return }
                if run.count == 1 {
                    rows.append(row(first))
                } else {
                    // "Session 1" … "Session 8" → "Session 1–8", "⌘1–8".
                    let base = first.title.dropLast(first.keyEquivalent.count).trimmingCharacters(in: .whitespaces)
                    rows.append(.init(name: "\(base) \(first.keyEquivalent)–\(last.keyEquivalent)",
                                      keys: KeyHint.format(first.keyEquivalent, first.keyEquivalentModifierMask) + "–" + last.keyEquivalent))
                }
                run = []
            }
            for item in sub.items where !item.isSeparatorItem && !item.keyEquivalent.isEmpty && !item.isHidden {
                if let action = item.action, skipped.contains(action) { continue }
                if let prev = run.last, isNumbered(item), isNumbered(prev), item.action == prev.action,
                   item.keyEquivalentModifierMask == prev.keyEquivalentModifierMask,
                   Int(item.keyEquivalent) == Int(prev.keyEquivalent).map({ $0 + 1 }),
                   item.title.dropLast(item.keyEquivalent.count) == prev.title.dropLast(prev.keyEquivalent.count) {
                    run.append(item)
                    continue
                }
                flush()
                run = [item]
            }
            flush()
            return rows.isEmpty ? nil : ShortcutSection(title: top.title, rows: rows)
        }
    }

    private static func isNumbered(_ item: NSMenuItem) -> Bool {
        item.keyEquivalent.count == 1 && Int(item.keyEquivalent) != nil && item.title.hasSuffix(item.keyEquivalent)
    }

    private static func row(_ item: NSMenuItem) -> ShortcutSection.Row {
        var name = item.title
        if name.hasSuffix("…") { name.removeLast() }
        return .init(name: name, keys: KeyHint.format(item.keyEquivalent, item.keyEquivalentModifierMask))
    }
}

/// The sheet's content: sections of name / key cap rows in two columns, on the popover's material.
final class ShortcutsView: NSView {
    static let columnWidth: CGFloat = 250
    private(set) var rowLabels: [NSTextField] = []
    private(set) var keyCaps: [KeyCap] = []
    /// Opens Settings › Shortcuts (through the responder chain, to the app delegate).
    let customizeButton = NSButton(title: "Customize…", target: nil, action: #selector(AppDelegate.customizeShortcuts(_:)))

    init(sections: [ShortcutSection]) {
        super.init(frame: .zero)
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        stack.edgeInsets = NSEdgeInsets(top: 14, left: 16, bottom: 14, right: 16)
        stack.translatesAutoresizingMaskIntoConstraints = false

        let title = NSTextField(labelWithString: "Keyboard Shortcuts")
        title.font = NSFont.systemFont(ofSize: 13, weight: .semibold)
        title.textColor = .labelColor
        customizeButton.isBordered = false
        customizeButton.font = Fonts.hint
        customizeButton.contentTintColor = .controlAccentColor
        customizeButton.attributedTitle = NSAttributedString(string: "Customize…", attributes: [
            .font: Fonts.hint, .foregroundColor: NSColor.controlAccentColor,
        ])
        customizeButton.setContentHuggingPriority(.required, for: .horizontal)
        let header = NSStackView(views: [title, NSView(), customizeButton])
        header.orientation = .horizontal
        header.alignment = .firstBaseline
        stack.addArrangedSubview(header)

        let columns = NSStackView()
        columns.orientation = .horizontal
        columns.alignment = .top
        columns.spacing = 24
        for group in ShortcutList.columns(sections) {
            let column = NSStackView()
            column.orientation = .vertical
            column.alignment = .leading
            column.spacing = 6
            column.widthAnchor.constraint(equalToConstant: Self.columnWidth).isActive = true
            for (i, section) in group.enumerated() {
                addSection(section, to: column, last: i == group.count - 1)
            }
            columns.addArrangedSubview(column)
        }
        stack.addArrangedSubview(columns)

        let note = NSTextField(wrappingLabelWithString: Self.note)
        note.font = Fonts.hint
        note.textColor = .secondaryLabelColor
        note.isSelectable = false
        stack.addArrangedSubview(note)

        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
            note.widthAnchor.constraint(equalTo: columns.widthAnchor),
            header.widthAnchor.constraint(equalTo: columns.widthAnchor),
        ])
        setAccessibilityLabel("Keyboard Shortcuts")
    }

    static var note: String {
        let sheet = KeyHint.string(for: #selector(MainWindowController.showShortcuts(_:))).map { "\($0) shows this sheet. " } ?? ""
        return sheet + "Hold ⌘ to see the session numbers in the sidebar."
    }

    private func addSection(_ section: ShortcutSection, to stack: NSStackView, last: Bool) {
        let header = NSTextField(labelWithAttributedString: Fonts.sectionString(section.title, color: .tertiaryLabelColor))
        stack.addArrangedSubview(header)
        let grid = NSGridView()
        grid.rowSpacing = 4
        grid.columnSpacing = 12
        grid.rowAlignment = .none
        for r in section.rows {
            let name = NSTextField(labelWithString: r.name)
            name.font = Fonts.hint
            name.textColor = .labelColor
            name.lineBreakMode = .byTruncatingTail
            name.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            let cap = KeyCap(r.keys, surface: .elevated)
            grid.addRow(with: [name, cap])
            rowLabels.append(name)
            keyCaps.append(cap)
        }
        grid.column(at: 1).xPlacement = .trailing
        for row in 0..<grid.numberOfRows { grid.row(at: row).yPlacement = .center }
        grid.translatesAutoresizingMaskIntoConstraints = false
        stack.addArrangedSubview(grid)
        grid.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        if !last { stack.setCustomSpacing(14, after: grid) }
    }

    required init?(coder: NSCoder) { fatalError() }

    /// A transient popover around the sheet, in the chrome's light/dark appearance.
    static func popover(menu: NSMenu?) -> NSPopover {
        let view = ShortcutsView(sections: menu.map(ShortcutList.sections(from:)) ?? [])
        view.layoutSubtreeIfNeeded()
        let vc = NSViewController()
        vc.view = view
        let p = NSPopover()
        p.behavior = .transient
        p.animates = Motion.full
        p.appearance = Theme.tokens.chromeAppearance
        p.contentViewController = vc
        p.contentSize = view.fittingSize
        return p
    }
}
