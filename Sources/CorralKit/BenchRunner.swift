import AppKit
import CorralCore

/// `CORRAL_BENCH=<out.json> Corral` runs this instead of normal startup: launch, creation,
/// shell-ready, command round trip, switching, status updates, idle CPU, close and memory,
/// against throwaway state. Also drives the perf tests with fake terminals.
final class BenchRunner {
    struct Metric: Codable, Equatable {
        var name: String
        var unit: String
        var samples: [Double]
        var p50: Double { Self.percentile(samples, 0.5) }
        var p95: Double { Self.percentile(samples, 0.95) }
        var max: Double { samples.max() ?? 0 }

        static func percentile(_ xs: [Double], _ p: Double) -> Double {
            guard !xs.isEmpty else { return 0 }
            let sorted = xs.sorted()
            return sorted[min(sorted.count - 1, Int((Double(sorted.count - 1) * p).rounded()))]
        }

        enum CodingKeys: String, CodingKey { case name, unit, samples, p50, p95, max }
        func encode(to encoder: Encoder) throws {
            var c = encoder.container(keyedBy: CodingKeys.self)
            try c.encode(name, forKey: .name)
            try c.encode(unit, forKey: .unit)
            try c.encode(samples, forKey: .samples)
            try c.encode(p50, forKey: .p50)
            try c.encode(p95, forKey: .p95)
            try c.encode(max, forKey: .max)
        }
        init(name: String, unit: String, samples: [Double]) {
            self.name = name
            self.unit = unit
            self.samples = samples
        }
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            name = try c.decode(String.self, forKey: .name)
            unit = try c.decode(String.self, forKey: .unit)
            samples = try c.decode([Double].self, forKey: .samples)
        }
    }

    let manager: SessionManager
    weak var window: MainWindowController?
    let output: URL?
    var sessionCount: Int
    var commandRounds: Int
    var idleSeconds: Double
    var readyTimeout: Double
    /// Direct agent launch check with a stub agent (CORRAL_BENCH_AGENT=0 skips it).
    var agentLaunchCheck: Bool
    /// Tab completion through the real key path (CORRAL_BENCH_TAB=0 skips it).
    var tabCheck: Bool
    private(set) var metrics: [Metric] = []
    private var readyWaiters: [UUID: () -> Void] = [:]
    private var commandWaiters: [UUID: () -> Void] = [:]
    private var exitWaiters: [UUID: (Int?) -> Void] = [:]

    init(manager: SessionManager, window: MainWindowController?, output: URL?) {
        let e = ProcessInfo.processInfo.environment
        self.manager = manager
        self.window = window
        self.output = output
        sessionCount = Int(e["CORRAL_BENCH_SESSIONS"] ?? "") ?? 20
        commandRounds = Int(e["CORRAL_BENCH_COMMANDS"] ?? "") ?? 10
        idleSeconds = Double(e["CORRAL_BENCH_IDLE"] ?? "") ?? 5
        readyTimeout = 8
        agentLaunchCheck = e["CORRAL_BENCH_AGENT"] != "0"
        tabCheck = e["CORRAL_BENCH_TAB"] != "0"
        manager.onTerminalAction = { [weak self] id, action in self?.observe(id, action) }
        manager.onHook = { [weak self] msg in
            guard msg.event.event == AgentLaunch.exitEvent else { return }
            self?.exitWaiters.removeValue(forKey: msg.surface)?(msg.event.exitCode)
        }
    }

    /// Throwaway state, no transcript indexing, no background agents, no notifications.
    static var benchDirectory: URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("corral-bench-\(getpid())")
    }

    static func environment() -> ManagerEnvironment {
        let dir = benchDirectory
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let empty = dir.appendingPathComponent("none")
        var env = ManagerEnvironment.standard
        env.store = WorkspaceStore(url: dir.appendingPathComponent("state.json"))
        env.indexPath = dir.appendingPathComponent("index.sqlite").path
        env.socketPath = NSTemporaryDirectory() + "corral-bench-\(getpid()).sock"
        env.roots = SearchIndex.Roots(claudeProjects: empty, opencodeDB: empty.appendingPathComponent("oc.db"),
                                      piSessions: empty)
        env.jobsDir = empty.appendingPathComponent("jobs")
        env.claudeBinary = nil
        env.notifications = false
        env.openURL = { _ in }
        env.alert = { _, _ in }
        env.setBadge = { _ in }
        return env
    }

    // MARK: Signals from terminals

    private func observe(_ id: UUID?, _ action: TerminalAction) {
        guard let id else { return }
        switch action {
        case .pwd, .setTitle:
            readyWaiters.removeValue(forKey: id)?()
        case .commandFinished:
            readyWaiters.removeValue(forKey: id)?()
            commandWaiters.removeValue(forKey: id)?()
        default:
            break
        }
    }

    // MARK: Run

    func run(completion: @escaping () -> Void) {
        record("launch_to_ready", "ms", [Self.msSinceProcessStart()])
        record("memory_baseline", "MB", [Self.footprintMB()])
        createSessions(remaining: sessionCount, create: [], ready: []) { [weak self] in
            guard let self else { return }
            self.record("memory_with_sessions", "MB", [Self.footprintMB()])
            self.commandRoundTrips(remaining: self.commandRounds, samples: []) {
                self.measureSwitching()
                self.measureStatusUpdates()
                self.measureIdle {
                    self.measureAgentLaunch {
                        self.measureTabCompletion {
                            self.measureSplit { self.measureResumeReveal { self.finish(completion) } }
                        }
                    }
                }
            }
        }
    }

    private func finish(_ completion: @escaping () -> Void) {
        measureClose()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            self.record("memory_after_close", "MB", [Self.footprintMB()])
            self.write()
            // Throwaway state only: never touch a real state directory.
            if self.manager.env.store.url.path.hasPrefix(Self.benchDirectory.path) {
                self.manager.prepareForTermination()
                try? FileManager.default.removeItem(at: Self.benchDirectory)
            }
            completion()
        }
    }

    private func record(_ name: String, _ unit: String, _ samples: [Double]) {
        metrics.append(Metric(name: name, unit: unit, samples: samples))
    }

    private func createSessions(remaining: Int, create: [Double], ready: [Double], done: @escaping () -> Void) {
        guard remaining > 0 else {
            record("session_create_sync", "ms", create)
            record("session_shell_ready", "ms", ready)
            done()
            return
        }
        let t0 = Self.now()
        manager.newSession(agent: .shell)
        window?.window?.displayIfNeeded()
        let syncMs = Self.ms(since: t0)
        guard let id = manager.workspace.selected else { done(); return }
        wait(for: id, in: \.readyWaiters) { [weak self] in
            self?.createSessions(remaining: remaining - 1, create: create + [syncMs], ready: ready + [Self.ms(since: t0)], done: done)
        }
    }

    private func commandRoundTrips(remaining: Int, samples: [Double], done: @escaping () -> Void) {
        guard remaining > 0, let id = manager.workspace.selected, let ls = manager.live[id] else {
            record("command_round_trip", "ms", samples)
            done()
            return
        }
        let t0 = Self.now()
        wait(for: id, in: \.commandWaiters) { [weak self] in
            self?.commandRoundTrips(remaining: remaining - 1, samples: samples + [Self.ms(since: t0)], done: done)
        }
        ls.terminal.perform(binding: "text:true\\n")
    }

    /// Calls `then` when the waiter fires or after `readyTimeout` (timeouts are recorded as such).
    private func wait(for id: UUID, in path: ReferenceWritableKeyPath<BenchRunner, [UUID: () -> Void]>,
                      then: @escaping () -> Void) {
        var fired = false
        self[keyPath: path][id] = {
            guard !fired else { return }
            fired = true
            then()
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + readyTimeout) { [weak self] in
            guard let self, !fired else { return }
            fired = true
            self[keyPath: path][id] = nil
            then()
        }
    }

    func measureSwitching() {
        var samples: [Double] = []
        let n = max(1, manager.workspace.openSessionsInOrder.count) * 3
        for _ in 0..<n {
            let t0 = Self.now()
            manager.selectRelative(1)
            window?.window?.displayIfNeeded()
            samples.append(Self.ms(since: t0))
        }
        record("switch_session", "ms", samples)
    }

    func measureStatusUpdates() {
        guard let id = manager.workspace.selected else { return }
        var samples: [Double] = []
        for i in 0..<200 {
            let t0 = Self.now()
            manager.apply(.progress(i % 2 == 0 ? .active : .removed), to: id)
            samples.append(Self.ms(since: t0))
        }
        record("status_update", "ms", samples)
    }

    private func measureIdle(done: @escaping () -> Void) {
        let cpu0 = Self.cpuSeconds()
        let t0 = Self.now()
        DispatchQueue.main.asyncAfter(deadline: .now() + idleSeconds) { [weak self] in
            let wall = Double(Self.now() - t0) / 1e9
            self?.record("idle_cpu", "%", [100 * (Self.cpuSeconds() - cpu0) / max(wall, 0.001)])
            done()
        }
    }

    func measureClose() {
        var samples: [Double] = []
        for id in manager.workspace.openSessionsInOrder {
            let t0 = Self.now()
            manager.close(id)
            window?.window?.displayIfNeeded()
            samples.append(Self.ms(since: t0))
        }
        record("session_close", "ms", samples)
    }

    // MARK: Direct agent launch

    /// Prints the marker, then exits 3.
    static let stubMarker = "CORRAL-STUB-READY"
    static let stubAgent = "printf '%s\\n' \(stubMarker); sleep 0.5; (exit 3)"
    static let integrationProbe = "print -r -- INTEG=${+functions[_ghostty_precmd]}"

    /// A Claude session running a stub agent: time to the marker and to the cover dropping, nothing
    /// shown before the marker (no prompt, no echoed command), exit report, and Ghostty shell
    /// integration in the follow-up shell. Then the old typed path for comparison.
    func measureAgentLaunch(done: @escaping () -> Void) {
        guard agentLaunchCheck else { done(); return }
        guard AgentLaunch.supportsDirect(shell: manager.env.loginShell) else {
            record("agent_launch_direct", "bool", [0])
            done()
            return
        }
        let t0 = Self.now()
        var readyMs: Double?
        let token = UUID()
        manager.newSession(agent: .claude, input: Self.stubAgent)
        window?.window?.displayIfNeeded()
        guard let id = manager.workspace.selected, manager.launchKind(id) != nil else { done(); return }
        launchObservers[token] = { [weak self] changed in
            guard changed == id, readyMs == nil, self?.manager.launchKind(id) == nil else { return }
            readyMs = Self.ms(since: t0)
        }
        var exitCode: Int?
        var exitMs: Double?
        exitWaiters[id] = { code in
            exitCode = code
            exitMs = Self.ms(since: t0)
        }
        poll(timeout: readyTimeout, until: { [weak self] in self?.text(id).contains(Self.stubMarker) == true }) { [weak self] in
            guard let self else { return }
            let markerMs = Self.ms(since: t0)
            let screen = self.text(id)
            let before = screen.components(separatedBy: Self.stubMarker).first ?? screen
            let clean = screen.contains(Self.stubMarker) && !SessionManager.hasVisibleText(before)
            self.poll(timeout: self.readyTimeout, until: { exitMs != nil && readyMs != nil }) {
                self.record("agent_launch_marker", "ms", [markerMs])
                self.record("agent_launch_ready", "ms", [readyMs ?? -1])
                self.record("agent_launch_clean", "bool", [clean ? 1 : 0])
                self.record("agent_exit_report", "ms", [exitMs ?? -1])
                self.record("agent_exit_code", "code", [Double(exitCode ?? -1)])
                self.launchObservers[token] = nil
                self.exitWaiters[id] = nil
                self.checkFollowUpShell(id) {
                    self.checkFollowUpExitCloses(id) {
                        self.checkNoOrphans { self.measureTypedLaunch(done: done) }
                    }
                }
            }
        }
    }

    /// After the stub exits: wait for the follow-up shell's prompt, then ask it whether Ghostty's
    /// shell integration is loaded (its command-finished report is the second proof).
    private func checkFollowUpShell(_ id: UUID, done: @escaping () -> Void) {
        poll(timeout: readyTimeout, until: { [weak self] in self?.manager.status(id)?.agent == .shell }) { [weak self] in
            guard let self else { return }
            let t0 = Self.now()
            self.wait(for: id, in: \.readyWaiters) {
                let promptMs = Self.ms(since: t0)
                var finished = false
                self.wait(for: id, in: \.commandWaiters) { finished = true }
                self.manager.live[id]?.terminal.perform(binding: "text:\(Self.integrationProbe)\\n")
                self.poll(timeout: self.readyTimeout, until: { finished || self.text(id).contains("INTEG=1") }) {
                    self.poll(timeout: 1, until: { finished }) {
                        self.record("followup_prompt", "ms", [promptMs])
                        self.record("followup_integration", "bool", [self.text(id).contains("INTEG=1") ? 1 : 0])
                        self.record("followup_command_finished", "bool", [finished ? 1 : 0])
                        done()
                    }
                }
            }
        }
    }

    /// `exit` in the follow-up shell closes the session like a plain shell's (libghostty must not
    /// hold a command-started surface open with "Process exited. Press any key…").
    private func checkFollowUpExitCloses(_ id: UUID, done: @escaping () -> Void) {
        let t0 = Self.now()
        manager.live[id]?.terminal.perform(binding: "text:exit\\n")
        poll(timeout: readyTimeout, until: { [weak self] in self?.manager.live[id] == nil }) { [weak self] in
            guard let self else { return }
            let closed = self.manager.live[id] == nil
            self.record("followup_exit_closes", "bool", [closed ? 1 : 0])
            if closed { self.record("followup_exit_close", "ms", [Self.ms(since: t0)]) }
            done()
        }
    }

    /// Nothing of the launch outlives the session: a launch shell that never prompts must not leave
    /// processes behind (gitstatus/p10k left one zsh per launch blocked on its FIFO).
    private func checkNoOrphans(done: @escaping () -> Void) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            self?.record("agent_launch_orphans", "count", [Double(Self.orphans(matching: Self.stubMarker))])
            done()
        }
    }

    /// Processes reparented to launchd whose command line contains `marker`.
    static func orphans(matching marker: String) -> Int {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/ps")
        p.arguments = ["-Ao", "ppid=,command="]
        let out = Pipe()
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice
        guard (try? p.run()) != nil else { return -1 }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return String(decoding: data, as: UTF8.self).split(separator: "\n").filter { line in
            let t = line.drop { $0 == " " }
            return t.hasPrefix("1 ") && t.contains(marker)
        }.count
    }

    /// Tab completion in a plain shell: a real Tab key event (AppKit keyDown → libghostty → the user's
    /// zsh completion) must complete a unique directory prefix; a raw tab byte is the comparison that
    /// tells a key-path problem from a shell one.
    func measureTabCompletion(done: @escaping () -> Void) {
        guard tabCheck else { done(); return }
        let target = "corral-tab-probe-target"
        try? FileManager.default.createDirectory(at: Self.benchDirectory.appendingPathComponent(target),
                                                 withIntermediateDirectories: true)
        manager.newSession(agent: .shell, cwd: Self.benchDirectory.path)
        guard let id = manager.workspace.selected, let ls = manager.live[id] else { done(); return }
        let completed = { [weak self] in self?.text(id).contains("\(target)/") == true }
        wait(for: id, in: \.readyWaiters) { [weak self] in
            guard let self else { return }
            ls.terminal.perform(binding: "text:cd corral-tab-pro")
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                let view = ls.terminal.view
                self.window?.window?.makeFirstResponder(view)
                let t0 = Self.now()
                for type in [NSEvent.EventType.keyDown, .keyUp] {
                    if let tab = NSEvent.keyEvent(with: type, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                                  windowNumber: self.window?.window?.windowNumber ?? 0, context: nil,
                                                  characters: "\t", charactersIgnoringModifiers: "\t", isARepeat: false, keyCode: 48) {
                        type == .keyDown ? view.keyDown(with: tab) : view.keyUp(with: tab)
                    }
                }
                self.poll(timeout: 3, until: completed) {
                    let viaKey = completed()
                    self.record("tab_completion_key", "bool", [viaKey ? 1 : 0])
                    if viaKey {
                        self.record("tab_completion_key_ms", "ms", [Self.ms(since: t0)])
                        self.measureTabMenu(id, done: done)
                        return
                    }
                    // Same line, raw tab byte straight to the pty.
                    ls.terminal.perform(binding: "text:\\t")
                    self.poll(timeout: 3, until: completed) {
                        self.record("tab_completion_raw", "bool", [completed() ? 1 : 0])
                        done()
                    }
                }
            }
        }
    }

    /// Several matches: the user's completion menu (e.g. fzf-tab) must list them.
    private func measureTabMenu(_ id: UUID, done: @escaping () -> Void) {
        guard let ls = manager.live[id] else { done(); return }
        for n in ["corral-tab-menu-alpha", "corral-tab-menu-beta"] {
            try? FileManager.default.createDirectory(at: Self.benchDirectory.appendingPathComponent(n), withIntermediateDirectories: true)
        }
        ls.terminal.perform(binding: "text:\\x03")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            ls.terminal.perform(binding: "text:cd corral-tab-menu-")
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                let view = ls.terminal.view
                for type in [NSEvent.EventType.keyDown, .keyUp] {
                    if let tab = NSEvent.keyEvent(with: type, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                                  windowNumber: self.window?.window?.windowNumber ?? 0, context: nil,
                                                  characters: "\t", charactersIgnoringModifiers: "\t", isARepeat: false, keyCode: 48) {
                        type == .keyDown ? view.keyDown(with: tab) : view.keyUp(with: tab)
                    }
                }
                let listed = { [weak self] in
                    let t = self?.text(id) ?? ""
                    return t.contains("alpha") && t.contains("beta")
                }
                self.poll(timeout: 3, until: listed) {
                    self.record("tab_menu_lists_matches", "bool", [listed() ? 1 : 0])
                    ls.terminal.perform(binding: "text:\\x1b")
                    done()
                }
            }
        }
    }

    /// ⌘D: a split pane's shell comes up next to the session's terminal, and `exit` closes the pane.
    func measureSplit(done: @escaping () -> Void) {
        guard let id = manager.workspace.selected, manager.live[id] != nil else { done(); return }
        let t0 = Self.now()
        manager.split(id, direction: .right)
        guard let pane = manager.panes.values.first(where: { $0.owner == id }) else { done(); return }
        wait(for: pane.id, in: \.readyWaiters) { [weak self] in
            guard let self else { return }
            self.record("split_pane_ready", "ms", [Self.ms(since: t0)])
            self.record("split_hosted", "bool", [self.window?.container.splitHosts[id] != nil ? 1 : 0])
            pane.terminal.perform(binding: "text:exit\\n")
            self.poll(timeout: self.readyTimeout, until: { self.manager.panes[pane.id] == nil }) {
                self.record("split_exit_closes", "bool", [self.manager.panes[pane.id] == nil ? 1 : 0])
                self.record("split_unhosted", "bool", [self.window?.container.splitHosts[id] == nil ? 1 : 0])
                done()
            }
        }
    }

    static let replayMarker = "CORRAL-REPLAY-DONE"
    /// Stands in for `claude --resume` drawing a transcript: 40 lines over ~1 s, then the end.
    static let replayStub = "for i in $(seq 1 40); do echo history line $i; sleep 0.025; done; echo \(replayMarker); sleep 3"

    /// A resume replays its transcript top to bottom; the cover must lift only once that is done,
    /// so the finished screen appears at once (never a half-drawn one).
    func measureResumeReveal(done: @escaping () -> Void) {
        guard agentLaunchCheck, AgentLaunch.supportsDirect(shell: manager.env.loginShell) else { done(); return }
        let t0 = Self.now()
        let token = UUID()
        manager.newSession(agent: .claude, input: Self.replayStub, agentSessionId: "corral-bench-replay")
        guard let id = manager.workspace.selected, manager.launchKind(id) == .resuming else { done(); return }
        var completeAtReveal: Bool?
        launchObservers[token] = { [weak self] changed in
            guard let self, changed == id, completeAtReveal == nil, self.manager.launchKind(id) == nil else { return }
            completeAtReveal = self.manager.live[id]?.terminal.viewportText().contains(Self.replayMarker) == true
            self.record("resume_reveal", "ms", [Self.ms(since: t0)])
        }
        poll(timeout: readyTimeout, until: { completeAtReveal != nil }) { [weak self] in
            guard let self else { return }
            self.launchObservers[token] = nil
            self.record("resume_reveal_complete", "bool", [completeAtReveal == true ? 1 : 0])
            self.manager.close(id)
            done()
        }
    }

    /// The old path for comparison: the stub typed into a fresh shell's first prompt.
    private func measureTypedLaunch(done: @escaping () -> Void) {
        let t0 = Self.now()
        manager.newSession(agent: .shell)
        guard let id = manager.workspace.selected else { done(); return }
        manager.live[id]?.terminal.perform(binding: "text:\(Self.stubAgent.replacingOccurrences(of: "\\", with: "\\\\"))\\n")
        poll(timeout: readyTimeout, until: { [weak self] in
            (self?.text(id).components(separatedBy: Self.stubMarker).count ?? 0) > 2
        }) { [weak self] in
            guard let self else { return }
            let ms = Self.ms(since: t0)
            let before = self.text(id).components(separatedBy: Self.stubMarker).first ?? ""
            self.record("typed_launch_marker", "ms", [ms])
            self.record("typed_launch_clean", "bool", [SessionManager.hasVisibleText(before) ? 0 : 1])
            done()
        }
    }

    private var launchObservers: [UUID: (UUID) -> Void] = [:]
    private var observing = false

    private func text(_ id: UUID) -> String { manager.live[id]?.terminal.screenText() ?? "" }

    /// Bench-only polling (10 ms) for screen contents; calls `then` once on success or timeout.
    private func poll(timeout: Double, until condition: @escaping () -> Bool, then: @escaping () -> Void) {
        if !observing {
            observing = true
            manager.observe { [weak self] change in
                if case .status(let id) = change { self?.launchObservers.values.forEach { $0(id) } }
            }
        }
        let deadline = Self.now() + UInt64(timeout * 1e9)
        func tick() {
            if condition() || Self.now() >= deadline { then(); return }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.01, execute: tick)
        }
        tick()
    }

    private func write() {
        guard let output else { return }
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        try? enc.encode(metrics).write(to: output)
    }

    // MARK: Measurement helpers

    static func now() -> UInt64 { DispatchTime.now().uptimeNanoseconds }
    static func ms(since t0: UInt64) -> Double { Double(now() - t0) / 1e6 }

    static func footprintMB() -> Double {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
        let kr = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        return kr == KERN_SUCCESS ? Double(info.phys_footprint) / 1_048_576 : 0
    }

    static func cpuSeconds() -> Double {
        var u = rusage()
        getrusage(RUSAGE_SELF, &u)
        return Double(u.ru_utime.tv_sec + u.ru_stime.tv_sec) + Double(u.ru_utime.tv_usec + u.ru_stime.tv_usec) / 1e6
    }

    static func msSinceProcessStart() -> Double {
        var kp = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.size
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, getpid()]
        guard sysctl(&mib, 4, &kp, &size, nil, 0) == 0 else { return 0 }
        let start = kp.kp_proc.p_starttime
        let started = Double(start.tv_sec) + Double(start.tv_usec) / 1e6
        return (Date().timeIntervalSince1970 - started) * 1000
    }
}
