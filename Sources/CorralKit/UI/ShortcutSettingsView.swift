import AppKit

/// Settings › Shortcuts: every Corral command with its shortcut, grouped like the menu. Click a field
/// and type; a shortcut another command had moves here (that row flashes and reads "None"). ↺ restores
/// one command's shortcut, Restore Defaults (placed in the page header) all of them.
final class ShortcutSettingsView: NSView {
    struct Row {
        let id: String
        let name: NSTextField
        let recorder: ShortcutRecorderView
        let reset: GhostButton
    }

    let store: ShortcutStore
    let restoreButton = NSButton(title: "Restore Defaults", target: nil, action: nil)
    private(set) var rows: [Row] = []
    private(set) var sectionLabels: [NSTextField] = []
    private var sectionTitles: [String] = []
    private(set) var groups: [SettingsGroupView] = []
    let stack = NSStackView()
    var surface: Surface = .card { didSet { applyTheme() } }

    static let rowHeight: CGFloat = 38
    static let rowPadding: CGFloat = 14
    static let introText = "Click a shortcut and type the new keys. ⌫ removes it, esc cancels. "
        + "Taking a shortcut another command uses leaves that one without."

    init(store: ShortcutStore) {
        self.store = store
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 0
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
        ])
        for (title, actions) in sections() {
            let label = NSTextField(labelWithString: "")
            sectionLabels.append(label)
            sectionTitles.append(title)
            stack.addArrangedSubview(label)
            stack.setCustomSpacing(8, after: label)
            let group = SettingsGroupView(rows: actions.count, rowHeight: Self.rowHeight, separatorInset: Self.rowPadding)
            group.surface = surface
            group.translatesAutoresizingMaskIntoConstraints = false
            group.setAccessibilityElement(true)
            group.setAccessibilityRole(.group)
            group.setAccessibilityLabel(title)
            for (i, action) in actions.enumerated() {
                let row = makeRow(action)
                group.addSubview(row)
                NSLayoutConstraint.activate([
                    row.leadingAnchor.constraint(equalTo: group.leadingAnchor),
                    row.trailingAnchor.constraint(equalTo: group.trailingAnchor),
                    row.topAnchor.constraint(equalTo: group.topAnchor, constant: CGFloat(i) * Self.rowHeight),
                    row.heightAnchor.constraint(equalToConstant: Self.rowHeight),
                ])
            }
            groups.append(group)
            stack.addArrangedSubview(group)
            stack.setCustomSpacing(26, after: group)
            NSLayoutConstraint.activate([
                group.widthAnchor.constraint(equalTo: stack.widthAnchor),
                group.heightAnchor.constraint(equalToConstant: CGFloat(actions.count) * Self.rowHeight),
            ])
        }
        restoreButton.target = self
        restoreButton.action = #selector(restoreDefaults(_:))
        restoreButton.controlSize = .small
        restoreButton.font = NSFont.systemFont(ofSize: NSFont.systemFontSize(for: .small))
        NotificationCenter.default.addObserver(self, selector: #selector(shortcutsChanged),
                                               name: .corralShortcutsChanged, object: store)
        sync(animated: false)
        applyTheme()
    }

    required init?(coder: NSCoder) { fatalError() }

    deinit { NotificationCenter.default.removeObserver(self) }

    /// The store's commands grouped by menu, in menu order.
    func sections() -> [(String, [ShortcutAction])] {
        var out: [(String, [ShortcutAction])] = []
        for a in store.actions where !a.hidden {
            if let i = out.firstIndex(where: { $0.0 == a.section }) { out[i].1.append(a) } else { out.append((a.section, [a])) }
        }
        return out
    }

    /// `[name]  ≥8  [↺]─6─[recorder 140]`
    private func makeRow(_ action: ShortcutAction) -> NSView {
        let row = NSView()
        row.translatesAutoresizingMaskIntoConstraints = false
        let name = NSTextField(labelWithString: action.title)
        name.font = NSFont.systemFont(ofSize: 13)
        name.lineBreakMode = .byTruncatingTail
        name.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        if action.isNumbered { name.toolTip = "1–8 pick a session in sidebar order, 9 the last one. Only the modifiers change." }

        let recorder = ShortcutRecorderView()
        recorder.surface = surface
        recorder.name = action.title
        recorder.keyLabel = action.isNumbered ? "1–9" : nil
        recorder.setCombo(store.combo(for: action.id), animated: false)
        let id = action.id
        recorder.onRecord = { [weak self] combo in self?.record(combo, for: id) ?? .refused("Settings closed") }

        let reset = GhostButton(symbol: "arrow.uturn.backward", size: 11, frame: NSRect(x: 0, y: 0, width: 18, height: 18),
                                target: self, action: #selector(resetRow(_:)))
        reset.surface = surface
        reset.tag = rows.count
        reset.toolTip = "Restore the built-in shortcut"
        reset.setAccessibilityLabel("Restore \(action.title) shortcut")

        for v in [name, reset, recorder] as [NSView] {
            v.translatesAutoresizingMaskIntoConstraints = false
            row.addSubview(v)
        }
        NSLayoutConstraint.activate([
            name.leadingAnchor.constraint(equalTo: row.leadingAnchor, constant: Self.rowPadding),
            name.centerYAnchor.constraint(equalTo: row.centerYAnchor),
            name.trailingAnchor.constraint(lessThanOrEqualTo: reset.leadingAnchor, constant: -8),
            reset.widthAnchor.constraint(equalToConstant: 18),
            reset.heightAnchor.constraint(equalToConstant: 18),
            reset.centerYAnchor.constraint(equalTo: row.centerYAnchor),
            reset.trailingAnchor.constraint(equalTo: recorder.leadingAnchor, constant: -6),
            recorder.centerYAnchor.constraint(equalTo: row.centerYAnchor),
            recorder.trailingAnchor.constraint(equalTo: row.trailingAnchor, constant: -(Self.rowPadding - 4)),
        ])
        rows.append(Row(id: action.id, name: name, recorder: recorder, reset: reset))
        return row
    }

    func row(_ id: String) -> Row? { rows.first { $0.id == id } }

    // MARK: State

    /// Offers a recorded combo to the store.
    func record(_ combo: KeyCombo?, for id: String) -> ShortcutRecorderView.Answer {
        if case .rejected(let reason) = store.set(combo, for: id) { return .refused(reason) }
        return .taken(store.combo(for: id))
    }

    @objc private func shortcutsChanged() { MainActor.assumeIsolated { sync(animated: true) } }

    /// Brings every row to the store's shortcuts. A row that lost its shortcut flashes. A row being
    /// recorded only takes the new value (it shows the keys held; esc then shows the right shortcut).
    func sync(animated: Bool) {
        for row in rows {
            let target = store.combo(for: row.id)
            if row.recorder.combo == target {
                // Up to date.
            } else if row.recorder.isRecording {
                row.recorder.setCombo(target, animated: false)
            } else {
                let lost = target == nil && row.recorder.combo != nil
                row.recorder.setCombo(target, change: lost ? .displaced : .plain, animated: animated)
            }
            setResetShown(row.reset, store.isCustomized(row.id), animated: animated)
        }
        restoreButton.isEnabled = store.hasOverrides
    }

    private func setResetShown(_ button: GhostButton, _ shown: Bool, animated: Bool) {
        let alpha: CGFloat = shown ? 1 : 0
        button.isEnabled = shown
        button.setAccessibilityElement(shown)
        guard button.alphaValue != alpha else { return }
        if animated, Motion.shouldAnimate(button) {
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = Motion.base
                button.animator().alphaValue = alpha
            }
        } else {
            button.alphaValue = alpha
        }
    }

    @objc func resetRow(_ sender: NSButton) {
        guard sender.tag >= 0, sender.tag < rows.count else { return }
        window?.makeFirstResponder(nil)
        let row = rows[sender.tag]
        if case .rejected(let reason) = store.reset(row.id) { row.recorder.refuse(reason) }
    }

    @objc func restoreDefaults(_ sender: Any?) {
        window?.makeFirstResponder(nil)
        store.resetAll()
    }

    /// Ends any recording (leaving the page or closing the window).
    func endRecording() {
        for row in rows where row.recorder.isRecording { row.recorder.cancelRecording() }
    }

    func applyTheme() {
        let r = Theme.ramp(surface)
        for (label, title) in zip(sectionLabels, sectionTitles) {
            label.attributedStringValue = Fonts.sectionString(title, color: r.tertiary)
        }
        for row in rows {
            row.name.textColor = r.primary
            row.recorder.surface = surface
            row.reset.surface = surface
        }
        for g in groups {
            g.surface = surface
            g.needsDisplay = true
        }
    }
}
