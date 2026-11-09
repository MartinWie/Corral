import AppKit
import CorralCore

/// Settings › Notifications: a switch and a sound per event, whether they also come while Corral is in
/// front, and a notice while macOS doesn't let Corral notify. Clicking a notification opens its session.
final class NotificationsPane: NSObject {
    let manager: SessionManager
    private(set) var page: SettingsPage!
    let testButton = NSButton(title: "Send Test", target: nil, action: nil)
    private(set) var switches: [NotificationKind: NSSwitch] = [:]
    private(set) var sounds: [NotificationKind: GhostButton] = [:]
    private(set) var rows: [NotificationKind: SettingsRow] = [:]
    let whileActiveSwitch = NSSwitch()
    private(set) var whileActiveRow: SettingsRow!
    let detailsSwitch = NSSwitch()
    private(set) var detailsRow: SettingsRow!
    /// Why macOS keeps notifications from showing, and the way to fix it. Hidden once they're allowed.
    private(set) var notice: SettingsList!
    private(set) var noticeRow: SettingsRow!
    let noticeIcon = NSImageView()
    let noticeButton = NSButton(title: "", target: nil, action: nil)
    /// Last permission read from macOS; nil until the first read (or without a bundle).
    private(set) var permission: Notifier.Permission?

    static let entries: [(kind: NotificationKind, title: String, caption: String)] = [
        (.permission, "Permission requests", "An agent wants to run a command, edit a file or use a tool. "
            + "Claude Code's can be allowed or denied right from the notification."),
        (.question, "Questions", "An agent asks you something, has a plan for you to review, or waits on a prompt."),
        (.finished, "Finished turns", "An agent is done and waits for your follow-up."),
        (.failed, "Errors", "A turn stopped on an API or tool error."),
        (.command, "Long commands", "A command in a plain terminal session finished after 10 seconds or more."),
    ]
    static let agentsFootnote = "Never for the session you're looking at. A newer notification replaces a session's "
        + "older one, and answered questions disappear from Notification Center."
    static let soundOn = "speaker.wave.2.fill"
    static let soundOff = "speaker.slash.fill"

    init(manager: SessionManager) {
        self.manager = manager
        super.init()
        build()
        refresh()
    }

    private func build() {
        testButton.target = self
        testButton.action = #selector(sendTest(_:))
        testButton.controlSize = .small
        testButton.font = NSFont.systemFont(ofSize: NSFont.systemFontSize(for: .small))
        testButton.toolTip = "Post a sample notification"
        page = SettingsPage(title: SettingsPane.notifications.title, subtitle: SettingsPane.notifications.subtitle,
                            accessory: testButton)

        noticeIcon.symbolConfiguration = .init(pointSize: 15, weight: .semibold)
        noticeIcon.image = NSImage(systemSymbolName: "bell.slash.fill", accessibilityDescription: nil)
        noticeIcon.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([noticeIcon.widthAnchor.constraint(equalToConstant: 22),
                                     noticeIcon.heightAnchor.constraint(equalToConstant: 22)])
        noticeButton.target = self
        noticeButton.action = #selector(noticeClicked(_:))
        noticeButton.controlSize = .small
        noticeButton.font = NSFont.systemFont(ofSize: NSFont.systemFontSize(for: .small))
        noticeButton.setContentHuggingPriority(.required, for: .horizontal)
        noticeButton.setContentCompressionResistancePriority(.required, for: .horizontal)
        noticeRow = SettingsRow(title: "", caption: " ", leading: noticeIcon, accessory: noticeButton)
        noticeRow.titleLabel.font = NSFont.systemFont(ofSize: 13, weight: .semibold)
        notice = SettingsList([noticeRow], separatorInset: 0)
        notice.isHidden = true
        page.addSection(nil, notice)

        var agentRows: [SettingsRow] = []
        var terminalRows: [SettingsRow] = []
        for (i, entry) in Self.entries.enumerated() {
            let toggle = NSSwitch()
            toggle.controlSize = .small
            toggle.tag = i
            toggle.target = self
            toggle.action = #selector(switchChanged(_:))
            toggle.setAccessibilityLabel("Notify for \(entry.title.lowercased())")
            let sound = GhostButton(symbol: Self.soundOn, size: 12, frame: NSRect(x: 0, y: 0, width: 24, height: 22),
                                    target: self, action: #selector(soundClicked(_:)))
            sound.surface = .card
            sound.tag = i
            let accessory = NSStackView(views: [sound, toggle])
            accessory.orientation = .horizontal
            accessory.spacing = 10
            // Hug the pair: a stretched stack would leave it wherever the caption ends.
            accessory.setHuggingPriority(.required, for: .horizontal)
            let row = SettingsRow(title: entry.title, caption: entry.caption, accessory: accessory)
            switches[entry.kind] = toggle
            sounds[entry.kind] = sound
            rows[entry.kind] = row
            if entry.kind == .command { terminalRows.append(row) } else { agentRows.append(row) }
        }
        page.addSection("Agents", SettingsList(agentRows), footnote: Self.agentsFootnote)
        page.addSection("Terminal", SettingsList(terminalRows))

        whileActiveSwitch.controlSize = .small
        whileActiveSwitch.target = self
        whileActiveSwitch.action = #selector(whileActiveChanged(_:))
        whileActiveSwitch.setAccessibilityLabel("Notify while Corral is in front")
        whileActiveRow = SettingsRow(title: "While Corral is in front",
                                     caption: "Also for the sessions you aren't looking at. Off: only while you're in another app.",
                                     accessory: whileActiveSwitch)
        detailsSwitch.controlSize = .small
        detailsSwitch.target = self
        detailsSwitch.action = #selector(detailsChanged(_:))
        detailsSwitch.setAccessibilityLabel("Show details in notifications")
        detailsRow = SettingsRow(title: "Show details",
                                 caption: "The command, file or question, also on the lock screen if macOS shows previews "
                                     + "there. Off: just the session and what it needs.",
                                 accessory: detailsSwitch)
        page.addSection("Delivery", SettingsList([whileActiveRow, detailsRow]))
        applyTheme()
    }

    // MARK: State

    /// Controls from `workspace.settings.notifications`.
    func refresh() {
        let prefs = manager.workspace.settings.notifications
        for entry in Self.entries {
            let rule = prefs[entry.kind]
            if let toggle = switches[entry.kind] {
                let state: NSControl.StateValue = rule.on ? .on : .off
                if toggle.state != state { toggle.state = state }
            }
            if let sound = sounds[entry.kind] {
                let symbol = rule.sound ? Self.soundOn : Self.soundOff
                if sound.symbol != symbol { sound.symbol = symbol }
                if sound.isEnabled != rule.on { sound.isEnabled = rule.on }
                sound.toolTip = rule.sound ? "Plays a sound (click to mute)" : "Silent (click to play a sound)"
                sound.setAccessibilityLabel("Sound for \(entry.title.lowercased())")
                sound.setAccessibilityValue(rule.sound ? "On" : "Off")
            }
        }
        let state: NSControl.StateValue = prefs.whileActive ? .on : .off
        if whileActiveSwitch.state != state { whileActiveSwitch.state = state }
        let details: NSControl.StateValue = prefs.showDetails ? .on : .off
        if detailsSwitch.state != details { detailsSwitch.state = details }
    }

    /// Asks macOS whether Corral may notify (it may have changed in System Settings meanwhile).
    func refreshPermission() {
        guard manager.env.notifications else {
            show(permission: nil)
            return
        }
        manager.env.notifier.permission { [weak self] in self?.show(permission: $0) }
    }

    /// The notice: hidden when allowed; otherwise what's wrong and the button that fixes it.
    func show(permission p: Notifier.Permission?) {
        permission = p
        let hidden = p == .allowed
        switch p {
        case .allowed:
            break
        case .denied:
            noticeRow.titleLabel.stringValue = "Notifications are off for Corral"
            noticeRow.caption = "macOS blocks them. Turn on Allow Notifications for Corral in System Settings."
            noticeButton.title = "Open System Settings"
        case .undecided:
            noticeRow.titleLabel.stringValue = "Allow notifications"
            noticeRow.caption = "macOS asks once: now, or the first time Corral has something to show."
            noticeButton.title = "Allow…"
        case nil:
            noticeRow.titleLabel.stringValue = "Notifications need the Corral app"
            noticeRow.caption = "This build runs outside an app bundle, and macOS only notifies for apps."
        }
        noticeButton.isHidden = p == nil
        testButton.isEnabled = p != nil && p != .denied
        guard notice.isHidden != hidden else { return }
        notice.isHidden = hidden
        if !hidden, Motion.shouldAnimate(notice), let layer = notice.layer {
            layer.add(Motion.basic("opacity", from: 0, to: 1, duration: Motion.base), forKey: "in")
        }
    }

    func applyTheme() {
        noticeIcon.contentTintColor = Theme.tokens.status.needsInput.fill
        for sound in sounds.values { sound.surface = .card }
    }

    // MARK: Actions

    private func kind(_ sender: NSControl) -> NotificationKind { Self.entries[sender.tag].kind }

    private func update(_ change: (inout NotificationSettings) -> Void) {
        var prefs = manager.workspace.settings.notifications
        change(&prefs)
        manager.setNotifications(prefs)
        refresh()
    }

    @objc func switchChanged(_ sender: NSSwitch) {
        let kind = kind(sender)
        let on = sender.state == .on
        update { $0[kind].on = on }
        // The moment the user wants notifications is the moment to ask macOS for them.
        if on, permission == .undecided { askPermission() }
    }

    @objc func soundClicked(_ sender: GhostButton) {
        let kind = kind(sender)
        update { $0[kind].sound.toggle() }
        if Motion.shouldAnimate(sender), let layer = sender.layer {
            layer.add(Motion.basic("opacity", from: 0.25, to: 1, duration: Motion.base), forKey: "toggle")
        }
    }

    @objc func whileActiveChanged(_ sender: NSSwitch) {
        let on = sender.state == .on
        update { $0.whileActive = on }
    }

    @objc func detailsChanged(_ sender: NSSwitch) {
        let on = sender.state == .on
        update { $0.showDetails = on }
    }

    @objc func sendTest(_ sender: Any?) {
        guard permission == .undecided else {
            manager.sendTestNotification()
            return
        }
        askPermission { [weak self] in if $0 == .allowed { self?.manager.sendTestNotification() } }
    }

    @objc func noticeClicked(_ sender: Any?) {
        switch permission {
        case .undecided: askPermission()
        case .denied: manager.env.openURL(Notifier.settingsURL)
        default: break
        }
    }

    private func askPermission(then: ((Notifier.Permission) -> Void)? = nil) {
        manager.env.notifier.requestPermission { [weak self] p in
            self?.show(permission: p)
            then?(p)
        }
    }
}
