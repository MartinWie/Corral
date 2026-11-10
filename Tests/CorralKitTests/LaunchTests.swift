import AppKit
import Carbon
@testable import CorralCore
import Testing
@testable import CorralKit

/// Direct agent launch: launch spec, launching state and its ready signals, the launch cover.
@MainActor
struct LaunchTests {
    // MARK: Launch spec

    @Test func zshLoginShellLaunchesTheAgentDirectly() throws {
        let f = Fixture()
        defer { f.cleanup() }
        f.manager.newSession(agent: .claude, cwd: f.dir.path)
        let id = try #require(f.selected)
        let t = try #require(f.terminal(id))
        #expect(t.launch.initialInput == nil)
        let start = "claude --session-id \(try #require(f.manager.workspace.sessions[id]?.agentSessionId))"
        #expect(t.launch.agentInput == start)
        #expect(t.launch.command == AgentLaunch.command(input: start, shell: "/bin/zsh", agent: .claude))
        #expect(t.launch.env["CORRAL_HOOK"] == "/bin/true")
        #expect(f.manager.launchKind(id) == .starting)
        #expect(f.manager.launchingCount == 1)
        // The terminal's process is the agent from the start.
        #expect(f.manager.status(id)?.agent == .claude)
        #expect(f.manager.workspace.sessions[id]?.agentRunning == true)
    }

    @Test func otherShellsKeepTheTypedFallback() throws {
        let f = Fixture { $0.loginShell = "/opt/homebrew/bin/fish" }
        defer { f.cleanup() }
        f.manager.newSession(agent: .opencode, cwd: f.dir.path)
        let id = try #require(f.selected)
        let t = try #require(f.terminal(id))
        #expect(t.launch.command == nil)
        #expect(t.launch.initialInput == "opencode")
        #expect(t.launch.agentInput == "opencode")
        #expect(f.manager.launchKind(id) == nil)
        #expect(f.manager.status(id)?.agent == .shell)
        #expect(!f.manager.launchProbeScheduled)
    }

    @Test func shellsNeverLaunchDirectly() throws {
        let f = Fixture()
        defer { f.cleanup() }
        f.manager.newSession(agent: .shell, cwd: f.dir.path)
        let t = try #require(f.terminal(f.selected))
        #expect(t.launch.command == nil && t.launch.initialInput == nil && t.launch.agentInput == nil)
        #expect(f.manager.launchingCount == 0)
        #expect(!f.manager.launchProbeScheduled)
    }

    @Test func kindsForResumeAttachAndReopen() throws {
        let f = Fixture()
        defer { f.cleanup() }
        f.manager.open(hit: SearchHit(key: "claude:s1", agent: .claude, sessionId: "s1", cwd: f.dir.path, title: "T",
                                      updated: Date(), snippets: []))
        let resumed = try #require(f.selected)
        #expect(f.manager.launchKind(resumed) == .resuming)
        #expect(f.terminal(resumed)?.launch.command?.contains("claude --resume s1") == true)

        f.manager.attach(BackgroundAgent(id: "job1", sessionId: "s-job1", name: "Job", cwd: f.dir.path, state: "working"))
        let attached = try #require(f.selected)
        #expect(f.manager.launchKind(attached) == .attaching)

        f.manager.launchReady(resumed)
        f.transcripts("s1")
        f.manager.close(resumed)
        f.manager.reopen(resumed)
        #expect(f.manager.launchKind(resumed) == .resuming)
    }

    // MARK: Ready signals

    func launching(_ f: Fixture, _ agent: AgentKind = .claude) -> UUID {
        f.manager.newSession(agent: agent, cwd: f.dir.path)
        let id = f.selected!
        #expect(f.manager.launchKind(id) != nil)
        return id
    }

    @Test func firstVisibleOutputRevealsAndTheProbeStops() async throws {
        let f = Fixture { $0.launchProbeInterval = 0.01 }
        defer { f.cleanup() }
        let id = launching(f)
        var changes: [UUID] = []
        f.manager.observe { if case .status(let s) = $0 { changes.append(s) } }
        #expect(f.manager.launchProbeScheduled)
        // Blank screen (rows of spaces and newlines) is not the agent yet.
        f.terminal(id)?.text = "   \n\n \t\n"
        try await Task.sleep(for: .milliseconds(60))
        #expect(f.manager.launchKind(id) != nil)
        f.terminal(id)?.text = "\n ╭─ Claude Code ─╮\n"
        await waitUntil { f.manager.launchKind(id) == nil }
        #expect(f.manager.launchKind(id) == nil)
        #expect(changes.contains(id))
        // Nothing launching: the one-shot chain ends.
        try await Task.sleep(for: .milliseconds(40))
        #expect(!f.manager.launchProbeScheduled)
    }

    @Test func probeCapCountsAsReady() {
        let f = Fixture()
        defer { f.cleanup() }
        let id = launching(f)
        let started = f.manager.live[id]!.launch!.started
        f.manager.probeLaunches(now: started + f.env.launchProbeCap - 0.5)
        #expect(f.manager.launchKind(id) != nil)
        f.manager.probeLaunches(now: started + f.env.launchProbeCap)
        #expect(f.manager.launchKind(id) == nil)
    }

    @Test func hookTitleKeyAndExitReveal() {
        let f = Fixture()
        defer { f.cleanup() }
        let viaHook = launching(f)
        f.manager.handleHook(HookWire.Message(surface: viaHook, event: HookEvent(agent: .claude, event: "SessionStart", sessionId: "x")))
        #expect(f.manager.launchKind(viaHook) == nil)

        let viaTitle = launching(f)
        _ = f.manager.perform(.setTitle("✳ Claude Code"), terminal: f.terminal(viaTitle))
        #expect(f.manager.launchKind(viaTitle) == nil)

        let viaKey = launching(f)
        f.manager.handleKey(keyEvent(UInt16(kVK_ANSI_2), chars: "2", modifiers: .command), session: viaKey)
        #expect(f.manager.launchKind(viaKey) != nil, "⌘ shortcuts are not typing")
        f.manager.handleKey(keyEvent(UInt16(kVK_ANSI_C), chars: "\u{3}", modifiers: .control), session: viaKey)
        #expect(f.manager.launchKind(viaKey) == nil)

        let viaChildExit = launching(f)
        _ = f.manager.perform(.childExited, terminal: f.terminal(viaChildExit))
        #expect(f.manager.launchKind(viaChildExit) == nil)

        let viaExitReport = launching(f, .opencode)
        f.manager.handleHook(HookWire.Message(surface: viaExitReport,
                                              event: HookEvent(agent: .opencode, event: AgentLaunch.exitEvent, exitCode: 127)))
        #expect(f.manager.launchKind(viaExitReport) == nil)

        // A signal for a session that already showed changes nothing.
        f.manager.launchReady(viaHook)
        f.manager.launchReady(UUID())
        #expect(f.manager.launchingCount == 0)
    }

    @Test func agentExitReportMatchesTheTypedPathOutcome() {
        let f = Fixture()
        defer { f.cleanup() }
        let id = launching(f)
        f.manager.launchReady(id)
        f.manager.apply(.hook(HookEvent(agent: .claude, event: "UserPromptSubmit")), to: id)
        #expect(f.manager.status(id)?.hooksSeen == true)
        var seen: [HookWire.Message] = []
        f.manager.onHook = { seen.append($0) }
        f.manager.handleHook(HookWire.Message(surface: id, event: HookEvent(agent: .claude, event: AgentLaunch.exitEvent, exitCode: 0)))
        #expect(seen.count == 1)
        #expect(f.manager.status(id)?.agent == .shell)
        #expect(f.manager.status(id)?.activity == .idle)
        #expect(f.manager.status(id)?.hooksSeen == false)
        // Restore must not resume an agent that exited.
        #expect(f.manager.workspace.sessions[id]?.agentRunning == false)
        #expect(f.manager.workspace.sessions[id]?.restoreInput == nil)

        // Without hooks the report never turns hooks on (terminal heuristics stay in charge).
        let plain = launching(f, .pi)
        f.manager.handleHook(HookWire.Message(surface: plain, event: HookEvent(agent: .pi, event: AgentLaunch.exitEvent, exitCode: 1)))
        #expect(f.manager.status(plain)?.hooksSeen == false)
        f.manager.apply(.foregroundProcess(.pi), to: plain)
        f.manager.apply(.desktopNotification(title: "", body: "Approve?"), to: plain)
        #expect(f.manager.status(plain)?.activity == .needsInput)
    }

    @Test func closingDuringLaunchDropsIt() async throws {
        let f = Fixture { $0.launchProbeInterval = 0.01 }
        defer { f.cleanup() }
        let id = launching(f)
        f.manager.close(id)
        #expect(f.manager.launchKind(id) == nil)
        #expect(f.manager.launchingCount == 0)
        try await Task.sleep(for: .milliseconds(40))
        #expect(!f.manager.launchProbeScheduled)
    }

    @Test func restoredSessionsAllResolve() async throws {
        let f = Fixture()
        defer { f.cleanup() }
        var ids: [UUID] = []
        for i in 0..<12 {
            f.manager.newSession(agent: i % 3 == 0 ? .shell : .claude, cwd: f.dir.path)
            let id = f.selected!
            if i % 3 != 0 {
                f.manager.apply(.hook(HookEvent(agent: .claude, event: "SessionStart", sessionId: "s\(i)", cwd: f.dir.path)), to: id)
                ids.append(id)
            }
        }
        f.manager.prepareForTermination()

        f.env.launchProbeInterval = 0.01
        f.env.launchProbeCap = 0.3
        f.env.launchResumeCap = 0.3
        f.makeManager()
        f.manager.start()
        #expect(f.manager.launchingCount == ids.count)
        #expect(ids.allSatisfy { f.manager.launchKind($0) == .resuming })
        // Some draw their first frame, the rest (hidden, slow) hit the cap.
        for id in ids.prefix(3) { f.terminal(id)?.text = "resumed" }
        await waitUntil(timeout: 5) { f.manager.launchingCount == 0 }
        #expect(f.manager.launchingCount == 0)
        f.manager.prepareForTermination()
        #expect(!f.manager.launchProbeScheduled || f.manager.launchingCount == 0)
    }

    /// A resume replays its transcript top to bottom: the cover waits until the screen has stopped
    /// changing, so the finished screen appears at once. Hooks and titles (sent before the replay)
    /// don't lift it; a fresh start still shows on its first output.
    @Test func resumesRevealOnceTheScreenSettles() throws {
        let f = Fixture()
        defer { f.cleanup() }
        let m = f.manager!
        m.newSession(agent: .claude, cwd: f.dir.path, agentSessionId: "r1")
        let resumed = f.selected!
        let t = try #require(f.terminal(resumed))
        #expect(m.launchKind(resumed) == .resuming)
        m.handleHook(HookWire.Message(surface: resumed, event: HookEvent(agent: .claude, event: "SessionStart", sessionId: "r1")))
        _ = m.perform(.setTitle("✳ Old work"), terminal: t)
        #expect(m.launchKind(resumed) == .resuming)
        let start = ProcessInfo.processInfo.systemUptime
        t.text = "line 1"
        m.probeLaunches(now: start + 0.1)
        t.text = "line 1\nline 2"
        m.probeLaunches(now: start + 0.2)
        m.probeLaunches(now: start + 0.3)
        #expect(m.launchKind(resumed) == .resuming)  // one unchanged probe isn't settled yet
        m.probeLaunches(now: start + 0.4)
        #expect(m.launchKind(resumed) == nil)

        // Fresh start: first output (or a hook) is enough.
        m.newSession(agent: .claude, cwd: f.dir.path)
        let fresh = f.selected!
        m.handleHook(HookWire.Message(surface: fresh, event: HookEvent(agent: .claude, event: "SessionStart")))
        #expect(m.launchKind(fresh) == nil)
        // The exit report ends any launch.
        m.newSession(agent: .claude, cwd: f.dir.path, agentSessionId: "r2")
        let gone = f.selected!
        m.handleHook(HookWire.Message(surface: gone, event: HookEvent(agent: .claude, event: AgentLaunch.exitEvent, exitCode: 1)))
        #expect(m.launchKind(gone) == nil)
        // A replay that never settles still shows at the resume cap.
        m.newSession(agent: .claude, cwd: f.dir.path, agentSessionId: "r3")
        let busy = f.selected!
        f.terminal(busy)?.text = "a"
        m.probeLaunches(now: ProcessInfo.processInfo.systemUptime + f.env.launchResumeCap + 1)
        #expect(m.launchKind(busy) == nil)
    }

    /// At app start the selected session resumes first, the rest a few at a time; picking a queued
    /// one starts it at once.
    @Test func restoreStartsTheSelectedFirstThenAFewAtATime() throws {
        let f = Fixture { $0.restoreConcurrency = 2 }
        defer { f.cleanup() }
        var ids: [UUID] = []
        for i in 0..<5 {
            f.manager.newSession(agent: .claude, cwd: f.dir.path, agentSessionId: "s\(i)")
            ids.append(f.selected!)
        }
        f.manager.newSession(agent: .shell, cwd: f.dir.path)
        let shell = f.selected!
        f.manager.select(ids[3])
        f.manager.prepareForTermination()
        f.makeManager()
        let m = f.manager!
        let w = MainWindowController(manager: m)
        m.start()
        // ids[3] (selected) and ids[0]: two launching; the shell is cheap and starts right away.
        #expect(Set(m.live.keys) == [ids[3], ids[0], shell])
        #expect(m.pendingRestore == [ids[1], ids[2], ids[4]])
        #expect(m.isPendingRestore(ids[1]) && !m.isPendingRestore(ids[3]))
        #expect(w.sidebar.sessionModel(ids[1])?.subtitle == "Resuming…")
        // A restore that finished lets the next one start, already placed in the window.
        m.launchReady(ids[0])
        #expect(m.live[ids[1]] != nil && m.pendingRestore == [ids[2], ids[4]])
        #expect(f.terminal(ids[1])?.view.superview === w.container.stack)
        // Looked at: starts now, regardless of the queue.
        m.select(ids[4])
        #expect(m.live[ids[4]] != nil && m.pendingRestore == [ids[2]])
        // Closing a queued one just drops it from the queue.
        m.requestClose(ids[2])
        #expect(m.pendingRestore.isEmpty && m.workspace.sessions[ids[2]]?.closedAt != nil)
    }

    // MARK: Launch cover

    func makeContainer(_ f: Fixture) -> TerminalContainerViewController {
        let c = TerminalContainerViewController(manager: f.manager)
        c.view.frame = NSRect(x: 0, y: 0, width: 800, height: 500)
        c.view.layoutSubtreeIfNeeded()
        return c
    }

    @Test func coverFollowsTheShownSession() throws {
        let f = Fixture()
        defer { f.cleanup() }
        let c = makeContainer(f)
        let agent = launching(f)
        c.showSelected(focus: false)
        #expect(c.launchCover.isShowing)
        #expect(c.launchCover.session == agent)
        #expect(c.launchCover.titleLabel.stringValue == "Starting Claude Code")
        #expect(c.launchCover.pathLabel.stringValue == RelativeTime.compactPath(f.dir.path))
        #expect(c.launchCover.spinner.look == .working)
        #expect(c.launchCover.accessibilityLabel() == "Starting Claude Code")
        // The terminal underneath stays laid out and visible, so its first frame is ready.
        let t = try #require(f.terminal(agent))
        #expect(!t.view.isHidden)
        #expect(t.visibility.last == true)
        c.view.layoutSubtreeIfNeeded()
        #expect(c.launchCover.frame == c.stack.frame)

        // Switching is instant per session state.
        f.manager.newSession(agent: .shell, cwd: f.dir.path)
        let shell = f.selected!
        c.showSelected(focus: false)
        #expect(c.launchCover.isHidden)
        #expect(!c.launchCover.dismissing)
        f.manager.select(agent)
        c.showSelected(focus: false)
        #expect(c.launchCover.isShowing)
        #expect(c.launchCover.layer?.opacity == 1)

        // Placeholders hide it.
        c.showBackground(BackgroundAgent(id: "j", sessionId: "s", name: "Job", cwd: "/", state: "working"))
        #expect(c.launchCover.isHidden)
        f.manager.select(agent)
        c.showSelected(focus: false)
        #expect(c.launchCover.isShowing)

        // The agent shows up: the cover goes (no visible window here, so without the fade).
        f.manager.launchReady(agent)
        c.sessionStatusChanged(agent)
        #expect(c.launchCover.isHidden)
        // Status of other sessions never touches it.
        c.sessionStatusChanged(shell)
        #expect(c.launchCover.isHidden)
        f.manager.select(nil)
        c.showSelected(focus: false)
        #expect(c.launchCover.isHidden)
    }

    @Test func coverTitlesPerKindAndAgent() {
        let f = Fixture()
        defer { f.cleanup() }
        let c = makeContainer(f)
        f.manager.newSession(agent: .opencode, cwd: f.dir.path, input: "opencode -s ses_1", agentSessionId: "ses_1")
        c.showSelected(focus: false)
        #expect(c.launchCover.titleLabel.stringValue == "Resuming OpenCode")
        #expect(c.launchCover.agent == .opencode)
        f.manager.attach(BackgroundAgent(id: "job1", sessionId: "s-job1", name: "Job", cwd: f.dir.path, state: "working"))
        c.showSelected(focus: false)
        #expect(c.launchCover.titleLabel.stringValue == "Attaching to background agent")
        #expect(c.launchCover.agent == .claude)
    }

    @Test func crossfadeOutAndInterruptions() throws {
        let f = Fixture()
        defer { f.cleanup() }
        let c = makeContainer(f)
        let id = launching(f)
        c.showSelected(focus: false)
        let cover = c.launchCover
        cover.dismiss(animated: true)
        #expect(cover.dismissing)
        #expect(!cover.isShowing)
        #expect(!cover.isHidden, "still on screen while it fades")
        let fade = try #require(cover.layer?.animation(forKey: LaunchCoverView.fadeKey) as? CABasicAnimation)
        #expect(fade.keyPath == "opacity")
        #expect(fade.toValue as? Int == 0)
        #expect(fade.duration == Motion.base)
        #expect(fade.timingFunction == Motion.std)
        #expect(cover.layer?.opacity == 0)
        // A second dismiss while fading is a no-op.
        let gen = cover.generation
        cover.dismiss(animated: true)
        #expect(cover.generation == gen)
        // A stale completion is ignored; the current one hides and resets.
        cover.finishDismiss(gen - 1)
        #expect(!cover.isHidden)
        cover.finishDismiss(gen)
        #expect(cover.isHidden)
        #expect(cover.layer?.opacity == 1)
        #expect(cover.layer?.animation(forKey: LaunchCoverView.fadeKey) == nil)

        // Shown again mid-fade (switching back to another launching session): fade cancelled.
        c.updateLaunchCover(animated: false)
        #expect(cover.isShowing)
        cover.dismiss(animated: true)
        c.updateLaunchCover(animated: false)
        #expect(cover.isShowing)
        #expect(cover.layer?.opacity == 1)
        #expect(cover.layer?.animation(forKey: LaunchCoverView.fadeKey) == nil)
        // An instant dismiss during a fade finishes it.
        cover.dismiss(animated: true)
        cover.dismiss(animated: false)
        #expect(cover.isHidden)
        #expect(!cover.dismissing)
        _ = id
    }

    @Test func coverNeverTakesFocusAndAClickReveals() throws {
        let f = Fixture()
        defer { f.cleanup() }
        let c = makeContainer(f)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 500), styleMask: [.borderless],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = c.view
        let id = launching(f)
        c.showSelected(focus: true)
        let t = try #require(f.terminal(id))
        #expect(c.launchCover.isShowing)
        #expect(window.firstResponder === t.view)
        #expect(!c.launchCover.acceptsFirstResponder)
        #expect(c.launchCover.acceptsFirstMouse(for: nil))
        window.makeFirstResponder(nil)
        c.launchCover.mouseDown(with: NSEvent())
        #expect(f.manager.launchKind(id) == nil)
        #expect(window.firstResponder === t.view)
        c.sessionStatusChanged(id)
        #expect(c.launchCover.isHidden)

        // Accessibility press does the same.
        let other = launching(f)
        c.showSelected(focus: false)
        #expect(c.launchCover.accessibilityPerformPress())
        #expect(f.manager.launchKind(other) == nil)
    }

    @Test func windowDropsTheCoverWhenTheAgentShows() throws {
        let f = Fixture()
        defer { f.cleanup() }
        let w = MainWindowController(manager: f.manager)
        let id = launching(f)
        #expect(w.container.launchCover.isShowing)
        f.terminal(id)?.text = "Claude"
        f.manager.probeLaunches()
        #expect(w.container.launchCover.isHidden)
    }

    @Test func coverEntranceIsTheSharedPageEntrance() throws {
        #expect(Motion.pageEntrance(full: true) == (rise: -8, duration: 0.22))
        // Reduce Motion: opacity only, 0.15 s (M2).
        #expect(Motion.pageEntrance(full: false) == (rise: 0, duration: 0.15))
        let saved = Motion.enabled
        Motion.enabled = true
        defer { Motion.enabled = saved }
        let cover = LaunchCoverView()
        #expect(cover.titleLabel.font == Fonts.coverTitle)
        cover.show(session: UUID(), kind: .starting, agent: .claude, cwd: "/tmp/x", entrance: true)
        let fade = try #require(cover.content.layer?.animation(forKey: "entrance.opacity") as? CABasicAnimation)
        #expect(fade.duration == Motion.pageEntrance(full: Motion.full).duration)
        #expect((cover.content.layer?.animation(forKey: "entrance.rise") != nil) == Motion.full)
    }

    @Test func coverRecolorsWithTheTheme() {
        let cover = LaunchCoverView()
        Theme.update(background: RGB(hex: 0xFDF6E3).color, foreground: RGB(hex: 0x657B83).color, windowTheme: nil)
        #expect(cover.titleLabel.textColor == Theme.ramp(.card).primary)
        #expect(cover.pathLabel.textColor == Theme.ramp(.card).tertiary)
        cover.updateLayer()
        #expect(cover.layer?.backgroundColor == Theme.tokens.card.cgColor)
        Theme.update(background: nil, foreground: nil, windowTheme: nil)
        #expect(cover.titleLabel.textColor == Theme.ramp(.card).primary)
    }

    // MARK: Sidebar

    @Test func rowSubtitleWhileLaunching() {
        var s = LiveStatus()
        let starting = SessionRowModel.make(title: "T", status: s, agent: .claude, cwd: "/tmp/x", launching: .starting)
        #expect(starting.subtitle == "Starting…")
        #expect(!starting.subtitleIsPath)
        #expect(starting.accessibilityState == "Starting")
        #expect(SessionRowModel.make(title: "T", status: s, agent: .claude, cwd: "/tmp/x", launching: .resuming).subtitle == "Resuming…")
        #expect(SessionRowModel.make(title: "T", status: s, agent: .claude, cwd: "/tmp/x", launching: .attaching).subtitle == "Attaching…")
        let ready = SessionRowModel.make(title: "T", status: s, agent: .claude, cwd: "/tmp/x")
        #expect(ready.subtitle == "x")
        #expect(ready.subtitleIsPath)
        #expect(ready.accessibilityState == "Idle")
        // Real states win over the launch label.
        s.activity = .needsInput
        let asking = SessionRowModel.make(title: "T", status: s, agent: .claude, cwd: "/tmp/x", launching: .starting)
        #expect(asking.subtitle == "Waiting for your input")
        #expect(asking.accessibilityState == "Needs input")
    }
}
