import AppKit
@testable import CorralCore
import Testing
@testable import CorralKit

/// Notifications: what gets posted (Settings › Notifications), withdrawing answered ones, the Settings
/// page, and a clicked notification revealing its session.
@MainActor
@Suite(.serialized)
struct NotificationTests {
    func fixture() -> Fixture { Fixture { $0.notifications = true } }

    func hook(_ event: String, message: String? = nil, tool: String? = nil) -> Signal {
        .hook(HookEvent(agent: .claude, event: event, message: message, tool: tool))
    }

    /// Two Claude sessions: `a` in the background, `b` selected (on screen while the app is active).
    func twoSessions(_ f: Fixture) throws -> (UUID, UUID) {
        f.manager.newSession(agent: .claude, cwd: f.dir.path)
        let a = try #require(f.selected)
        f.manager.newSession(agent: .claude, cwd: f.dir.path)
        return (a, try #require(f.selected))
    }

    @Test func postsWhatTheSettingsAskForAndNeverForTheSessionOnScreen() throws {
        let f = fixture()
        defer { f.cleanup() }
        let (a, b) = try twoSessions(f)
        f.manager.apply(hook("UserPromptSubmit"), to: a)
        f.manager.apply(hook("PermissionRequest", message: "Bash: git push", tool: "Bash"), to: a)
        let note = try #require(f.effects.notes.last)
        #expect(note.id == a.uuidString && note.session == a)
        #expect(note.subtitle == "Claude Code needs permission" && note.body == "Bash: git push" && note.sound)

        // The selected session is being looked at: nothing.
        f.manager.apply(hook("UserPromptSubmit"), to: b)
        f.manager.apply(hook("Stop"), to: b)
        #expect(f.effects.notes.count == 1)

        // Answered: the question leaves Notification Center.
        let withdrawn = f.effects.withdrawn.count
        f.manager.apply(.userSubmitted, to: a)
        #expect(f.effects.withdrawn.dropFirst(withdrawn) == [a.uuidString])

        // A switched-off kind posts nothing.
        var prefs = f.manager.workspace.settings.notifications
        prefs[.finished].on = false
        f.manager.setNotifications(prefs)
        f.manager.apply(hook("Stop"), to: a)
        #expect(f.effects.notes.count == 1)

        // Only while Corral is in the background, when asked.
        prefs[.finished].on = true
        prefs.whileActive = false
        f.manager.setNotifications(prefs)
        f.manager.apply(hook("UserPromptSubmit"), to: a)
        f.manager.apply(hook("Stop"), to: a)
        #expect(f.effects.notes.count == 1)
        f.effects.active = false
        f.manager.apply(hook("UserPromptSubmit"), to: a)
        f.manager.apply(hook("Stop"), to: a)
        #expect(f.effects.notes.last?.subtitle == "Claude Code finished" && f.effects.notes.last?.sound == false)
        // Away from the app, the selected session counts as unseen too.
        f.manager.apply(hook("UserPromptSubmit"), to: b)
        f.manager.apply(hook("PermissionRequest", tool: "AskUserQuestion"), to: b)
        #expect(f.effects.notes.last?.session == b && f.effects.notes.last?.subtitle == "Claude Code needs your input")
    }

    @Test func everyLongCommandIsNewsAndAnsweredPromptsGoEvenWhenSilenced() throws {
        let f = fixture()
        defer { f.cleanup() }
        f.manager.newSession(agent: .shell, cwd: f.dir.path)
        let shell = try #require(f.selected)
        let (a, _) = try twoSessions(f)
        for _ in 0..<2 {
            f.manager.apply(.userSubmitted, to: shell)
            f.manager.apply(.commandFinished(exitCode: 0, seconds: 20), to: shell)
        }
        #expect(f.effects.notes.filter { $0.session == shell }.map(\.subtitle) == ["Command finished", "Command finished"])

        // Its kind switched off, a prompt that ends still leaves Notification Center.
        var prefs = f.manager.workspace.settings.notifications
        prefs[.failed].on = false
        prefs.showDetails = false
        f.manager.setNotifications(prefs)
        f.manager.apply(hook("PermissionRequest", message: "Bash: export TOKEN=x", tool: "Bash"), to: a)
        #expect(f.effects.notes.last?.body == RelativeTime.abbreviatePath(f.dir.path))
        let withdrawn = f.effects.withdrawn.count
        f.manager.apply(.hook(HookEvent(agent: .claude, event: "StopFailure", message: "overloaded")), to: a)
        #expect(f.effects.withdrawn.dropFirst(withdrawn) == [a.uuidString])
        #expect(f.effects.notes.last?.subtitle != "Claude Code failed")
    }

    @Test func aBackgroundCompactIsNoFinishedTurn() throws {
        let f = fixture()
        defer { f.cleanup() }
        let (a, _) = try twoSessions(f)
        f.manager.apply(hook("UserPromptSubmit"), to: a)
        f.manager.apply(hook("Stop"), to: a)
        let posted = f.effects.notes.count
        f.manager.apply(.hook(HookEvent(agent: .claude, event: "PreCompact", trigger: "manual")), to: a)
        #expect(f.manager.status(a)?.activity == .working)
        f.manager.apply(.hook(HookEvent(agent: .claude, event: "SessionStart", source: "compact")), to: a)
        #expect(f.manager.status(a)?.activity == .done)
        #expect(f.effects.notes.count == posted)
    }

    @Test func idleCompactionPostsNothing() throws {
        let f = fixture()
        defer { f.cleanup() }
        let (a, _) = try twoSessions(f)
        f.manager.apply(hook("UserPromptSubmit"), to: a)
        f.manager.apply(hook("Stop"), to: a)
        #expect(f.effects.notes.count == 1)
        f.manager.apply(.hook(HookEvent(agent: .claude, event: "PreCompact", trigger: "auto")), to: a)
        f.manager.apply(.hook(HookEvent(agent: .claude, event: "SessionStart", source: "compact")), to: a)
        #expect(f.manager.status(a)?.activity == .done)
        #expect(f.effects.notes.count == 1)
        #expect(f.manager.workingAgents == 0)
    }

    @Test func nothingWithoutAnAppBundle() throws {
        let f = Fixture()
        defer { f.cleanup() }
        let (a, _) = try twoSessions(f)
        f.manager.apply(hook("PermissionRequest"), to: a)
        f.manager.apply(.userSubmitted, to: a)
        f.manager.sendTestNotification()
        #expect(f.effects.notes.isEmpty && f.effects.withdrawn.isEmpty)
    }

    @Test func testNotificationUsesTheSoundSettings() {
        let f = fixture()
        defer { f.cleanup() }
        f.manager.sendTestNotification()
        #expect(f.effects.notes == [SessionManager.testNote])
        var prefs = NotificationSettings()
        for kind in NotificationKind.allCases { prefs[kind].sound = false }
        f.manager.setNotifications(prefs)
        f.manager.sendTestNotification()
        #expect(f.effects.notes.last?.sound == false && f.effects.notes.last?.session == nil)
    }

    @Test func settingsAreSavedWithTheWorkspace() throws {
        let f = fixture()
        defer { f.cleanup() }
        var changes = 0
        f.manager.observe { if case .settings = $0 { changes += 1 } }
        var prefs = NotificationSettings()
        prefs[.question].on = false
        f.manager.setNotifications(prefs)
        f.manager.setNotifications(prefs)
        #expect(changes == 1)
        f.manager.saveNow(wait: true)
        #expect(f.env.store.load().settings.notifications == prefs)
    }

    @Test func revealSelectsTheSessionAndAnnouncesIt() throws {
        let f = fixture()
        defer { f.cleanup() }
        let (a, _) = try twoSessions(f)
        var revealed: [UUID] = []
        f.manager.observe { if case .reveal(let id) = $0 { revealed.append(id) } }
        f.manager.reveal(a)
        #expect(f.selected == a && revealed == [a])
        f.manager.reveal(UUID())
        #expect(f.selected == a && revealed == [a])
        // A notification outliving its session: closed ones stay closed (and lose it on close).
        let (c, _) = try twoSessions(f)
        f.manager.apply(hook("PermissionRequest"), to: c)
        f.manager.close(c)
        #expect(f.effects.withdrawn.last == c.uuidString)
        f.manager.reveal(c)
        #expect(f.selected != c && revealed == [a])
    }

    @Test func sidebarRevealOpensCollapsedFolders() throws {
        let f = fixture()
        defer { f.cleanup() }
        let s = SidebarViewController(manager: f.manager)
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 280, height: 300), styleMask: [.borderless],
                         backing: .buffered, defer: false)
        w.isReleasedWhenClosed = false
        w.contentView = s.view
        let outer = f.manager.newFolder(name: "Outer")
        let inner = f.manager.newFolder(name: "Inner", in: outer)
        f.manager.newSession(agent: .shell, cwd: f.dir.path, folder: .some(inner))
        let id = try #require(f.selected)
        for _ in 0..<20 { f.manager.newSession(agent: .shell, cwd: f.dir.path, folder: .some(nil)) }
        s.outline.collapseItem(s.node(.folder(inner)))
        s.outline.collapseItem(s.node(.folder(outer)))
        #expect(s.outline.row(forItem: s.node(.session(id))) < 0)
        f.manager.reveal(id)
        let row = s.outline.row(forItem: s.node(.session(id)))
        #expect(row >= 0 && s.outline.selectedRow == row)
        #expect(f.manager.workspace.folders[outer]?.expanded == true && f.manager.workspace.folders[inner]?.expanded == true)
        s.reveal(UUID())
    }

    // MARK: Settings › Notifications

    @Test func pageShowsAndChangesEachRule() throws {
        let f = fixture()
        defer { f.cleanup() }
        let w = SettingsWindowController(manager: f.manager)
        let pane = try #require(w.notifications)
        #expect(w.pages[.notifications] === pane.page)
        #expect(pane.page.header.arrangedSubviews.last === pane.testButton)
        #expect(NotificationsPane.entries.map(\.kind) == NotificationKind.allCases)
        for kind in NotificationKind.allCases {
            #expect(pane.switches[kind]?.state == .on)
            #expect(pane.sounds[kind]?.symbol == (kind == .permission || kind == .question ? NotificationsPane.soundOn : NotificationsPane.soundOff))
        }
        #expect(pane.page.lists.count == 4 && pane.page.sectionLabels.map(\.1) == ["Agents", "Terminal", "Delivery"])

        let finished = try #require(pane.switches[.finished])
        finished.state = .off
        pane.switchChanged(finished)
        #expect(!f.manager.workspace.settings.notifications[.finished].on)
        #expect(pane.sounds[.finished]?.isEnabled == false)
        let sound = try #require(pane.sounds[.permission])
        pane.soundClicked(sound)
        #expect(!f.manager.workspace.settings.notifications[.permission].sound)
        #expect(sound.symbol == NotificationsPane.soundOff && sound.accessibilityValue() as? String == "Off")
        pane.whileActiveSwitch.state = .off
        pane.whileActiveChanged(pane.whileActiveSwitch)
        #expect(!f.manager.workspace.settings.notifications.whileActive)
        pane.detailsSwitch.state = .off
        pane.detailsChanged(pane.detailsSwitch)
        #expect(!f.manager.workspace.settings.notifications.showDetails)

        // Changes made elsewhere (another window, a restore) show up.
        f.manager.setNotifications(NotificationSettings())
        #expect(finished.state == .on && pane.whileActiveSwitch.state == .on && sound.symbol == NotificationsPane.soundOn)
        #expect(pane.detailsSwitch.state == .on)
    }

    @Test func noticeExplainsWhyNothingShowsAndFixesIt() throws {
        let f = fixture()
        defer { f.cleanup() }
        let w = SettingsWindowController(manager: f.manager)
        let pane = try #require(w.notifications)
        #expect(pane.notice.isHidden)

        f.effects.permission = .denied
        w.show(.notifications, animated: false)
        #expect(!pane.notice.isHidden && pane.noticeButton.title == "Open System Settings" && !pane.testButton.isEnabled)
        pane.noticeClicked(nil)
        #expect(f.effects.opened.last?.scheme == "x-apple.systempreferences")

        // Allowed in System Settings meanwhile: the window coming back reads it again.
        f.effects.permission = .allowed
        w.windowDidBecomeKey(Notification(name: NSWindow.didBecomeKeyNotification))
        #expect(pane.notice.isHidden && pane.testButton.isEnabled)

        // Undecided: the notice asks; so does switching a kind on and sending a test.
        f.effects.permission = .undecided
        f.effects.permissionAnswer = .denied
        pane.refreshPermission()
        #expect(pane.noticeButton.title == "Allow…")
        pane.noticeClicked(nil)
        #expect(f.effects.permissionRequests == 1 && pane.permission == .denied)
        f.effects.permission = .undecided
        f.effects.permissionAnswer = .allowed
        pane.refreshPermission()
        let question = try #require(pane.switches[.question])
        question.state = .off
        pane.switchChanged(question)
        #expect(f.effects.permissionRequests == 1)
        question.state = .on
        pane.switchChanged(question)
        #expect(f.effects.permissionRequests == 2 && pane.notice.isHidden)
        pane.sendTest(nil)
        #expect(f.effects.notes.count == 1)
        f.effects.permission = .undecided
        pane.refreshPermission()
        pane.sendTest(nil)
        #expect(f.effects.permissionRequests == 3 && f.effects.notes.count == 2)
        f.effects.permission = .undecided
        f.effects.permissionAnswer = .denied
        pane.refreshPermission()
        pane.sendTest(nil)
        #expect(f.effects.notes.count == 2)
        pane.noticeClicked(nil)
        #expect(f.effects.opened.count == 2)
    }

    @Test func outsideAnAppBundleThePageSaysSo() throws {
        let f = Fixture()
        defer { f.cleanup() }
        let w = SettingsWindowController(manager: f.manager)
        w.show(.notifications, animated: false)
        let pane = try #require(w.notifications)
        #expect(!pane.notice.isHidden && pane.noticeButton.isHidden && !pane.testButton.isEnabled)
        #expect(pane.noticeRow.titleLabel.stringValue == "Notifications need the Corral app")
        pane.noticeClicked(nil)
        #expect(f.effects.opened.isEmpty)
    }

    @Test func systemRequestsCarryTheSession() {
        let id = UUID()
        let r = Notifier.request(CorralNote(id: id.uuidString, title: "T", subtitle: "S", body: "B", sound: true, session: id))
        #expect(r.identifier == id.uuidString)
        #expect(r.content.title == "T" && r.content.subtitle == "S" && r.content.body == "B" && r.content.sound != nil)
        #expect(r.content.userInfo["session"] as? String == id.uuidString && r.content.threadIdentifier == id.uuidString)
        let test = Notifier.request(SessionManager.testNote)
        #expect(test.content.userInfo.isEmpty && test.content.threadIdentifier.isEmpty)
        var quiet = SessionManager.testNote
        quiet.sound = false
        #expect(Notifier.request(quiet).content.sound == nil)
    }

    @Test func systemNotifierMapsPermission() {
        #expect(Notifier.permission(.notDetermined) == .undecided)
        #expect(Notifier.permission(.denied) == .denied)
        #expect(Notifier.permission(.authorized) == .allowed)
        #expect(Notifier.permission(.provisional) == .allowed)
        #expect(Notifier.settingsURL.absoluteString.hasPrefix("x-apple.systempreferences:com.apple.Notifications-Settings.extension"))
    }
}

/// Allow / Deny on a Claude permission notification.
@MainActor
@Suite(.serialized)
struct PromptAnswerTests {
    func setup() throws -> (Fixture, UUID, FakeTerminal) {
        let f = Fixture { $0.notifications = true }
        f.manager.newSession(agent: .claude, cwd: f.dir.path)
        let a = try #require(f.selected)
        f.manager.newSession(agent: .claude, cwd: f.dir.path)
        f.manager.apply(.hook(HookEvent(agent: .claude, event: "UserPromptSubmit")), to: a)
        f.manager.apply(.hook(HookEvent(agent: .claude, event: "PermissionRequest", message: "Bash: ls", tool: "Bash")), to: a)
        return (f, a, try #require(f.terminal(a)))
    }

    @Test func permissionNotesCarryTheirPrompt() throws {
        let (f, a, _) = try setup()
        defer { f.cleanup() }
        let note = try #require(f.effects.notes.last)
        let token = try #require(note.prompt)
        #expect(token == f.manager.status(a)?.promptId?.uuidString)
        let request = Notifier.request(note)
        #expect(request.content.categoryIdentifier == Notifier.permissionCategory)
        #expect(request.content.userInfo["prompt"] as? String == token)
        let category = try #require(Notifier.categories.first)
        #expect(category.actions.map(\.identifier) == [Notifier.allowAction, Notifier.denyAction])
        // Questions and other agents' prompts get no buttons.
        var s = f.manager.status(a)!
        s.need = .input
        #expect(SessionManager.promptToken(s) == nil)
        s.need = .permission
        s.agent = .opencode
        #expect(SessionManager.promptToken(s) == nil)
        // Without details the user can't see what they would allow: no buttons.
        var prefs = f.manager.workspace.settings.notifications
        prefs.showDetails = false
        f.manager.setNotifications(prefs)
        f.manager.apply(.userSubmitted, to: a)
        f.manager.apply(.hook(HookEvent(agent: .claude, event: "PermissionRequest", message: "Bash: ls", tool: "Bash")), to: a)
        #expect(f.effects.notes.last?.prompt == nil && f.effects.notes.last?.body != "Bash: ls")
    }

    @Test func onlyAToolPermissionRequestGetsButtons() throws {
        let f = Fixture { $0.notifications = true }
        defer { f.cleanup() }
        f.manager.newSession(agent: .claude, cwd: f.dir.path)
        let a = try #require(f.selected)
        f.manager.newSession(agent: .claude, cwd: f.dir.path)
        // Claude's generic notice (no PermissionRequest hook seen): "1" may not mean Yes there.
        f.manager.apply(.hook(HookEvent(agent: .claude, event: "Notification", message: "Claude needs your permission",
                                        notificationType: "permission_prompt")), to: a)
        #expect(f.effects.notes.last?.subtitle == "Claude Code needs permission" && f.effects.notes.last?.prompt == nil)
        f.manager.apply(.userSubmitted, to: a)
        f.manager.apply(.hook(HookEvent(agent: .claude, event: "PermissionRequest", message: "Permission needed")), to: a)
        #expect(f.effects.notes.last?.prompt == nil)
    }

    @Test func aSecondPromptBeforeTheFirstWasSeenAnsweredGetsItsOwnNote() throws {
        let (f, a, terminal) = try setup()
        defer { f.cleanup() }
        let first = try #require(f.effects.notes.last?.prompt)
        let posted = f.effects.notes.count
        // Answered somewhere Corral didn't see (Ctrl-C, another device), and the next prompt is up.
        f.manager.apply(.hook(HookEvent(agent: .claude, event: "PermissionRequest", message: "Bash: rm -rf x", tool: "Bash")), to: a)
        #expect(f.manager.status(a)?.activity == .needsInput)
        #expect(f.effects.notes.count == posted + 1 && f.effects.notes.last?.body == "Bash: rm -rf x")
        let second = try #require(f.effects.notes.last?.prompt)
        #expect(second != first)
        // The first note's Allow can't approve the rm: nothing typed, Corral comes forward instead.
        let typed = terminal.bindings.count
        #expect(f.manager.respondToNotification(action: Notifier.allowAction, session: a, prompt: first))
        #expect(terminal.bindings.count == typed && f.manager.status(a)?.activity == .needsInput)
        // Claude's follow-up notice for the same prompt changes nothing.
        f.manager.apply(.hook(HookEvent(agent: .claude, event: "Notification", message: "Claude needs your permission",
                                        notificationType: "permission_prompt")), to: a)
        #expect(f.manager.status(a)?.promptId?.uuidString == second && f.effects.notes.count == posted + 1)
    }

    @Test func aRefusedKeystrokeAnswersNothing() throws {
        let (f, a, terminal) = try setup()
        defer { f.cleanup() }
        let token = try #require(f.effects.notes.last?.prompt)
        terminal.bindingResult = false
        #expect(!f.manager.answerPrompt(.allow, session: a, prompt: token))
        #expect(f.manager.status(a)?.activity == .needsInput)
        #expect(f.manager.respondToNotification(action: Notifier.allowAction, session: a, prompt: token))
    }

    @Test func allowTypesYesForThatPromptOnly() throws {
        let (f, a, terminal) = try setup()
        defer { f.cleanup() }
        let token = try #require(f.effects.notes.last?.prompt)
        #expect(!f.manager.respondToNotification(action: Notifier.allowAction, session: a, prompt: token))
        #expect(terminal.bindings.last == "text:1")
        #expect(f.manager.status(a)?.activity == .working)
        #expect(f.effects.withdrawn.last == a.uuidString)
        // The same notification again: that prompt is gone, nothing is typed, Corral comes forward.
        let typed = terminal.bindings.count
        #expect(f.manager.respondToNotification(action: Notifier.allowAction, session: a, prompt: token))
        #expect(terminal.bindings.count == typed)
        // A newer prompt has another token.
        f.manager.apply(.hook(HookEvent(agent: .claude, event: "PermissionRequest", message: "Bash: rm x", tool: "Bash")), to: a)
        #expect(f.effects.notes.last?.prompt != token)
        #expect(!f.manager.answerPrompt(.allow, session: a, prompt: token))
        #expect(!f.manager.answerPrompt(.allow, session: nil, prompt: token))
        #expect(!f.manager.answerPrompt(.allow, session: a, prompt: nil))
    }

    @Test func denyPressesEscapeAndOpensTheSession() throws {
        let (f, a, terminal) = try setup()
        defer { f.cleanup() }
        let token = try #require(f.effects.notes.last?.prompt)
        #expect(f.manager.respondToNotification(action: Notifier.denyAction, session: a, prompt: token))
        #expect(terminal.bindings.last == "text:\\x1b")
        #expect(f.manager.status(a)?.activity == .idle)
        // A plain click only opens.
        let typed = terminal.bindings.count
        #expect(f.manager.respondToNotification(action: "com.apple.UNNotificationDefaultActionIdentifier", session: a, prompt: token))
        #expect(terminal.bindings.count == typed)
    }
}
