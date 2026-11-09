import AppKit
@testable import CorralCore
import Testing
@testable import CorralKit

/// Budgets for everything Corral does around the terminal (fake terminals, debug build).
/// Real-terminal numbers (surface creation, shell ready, rendering) come from `CORRAL_BENCH`.
/// Debug builds are ~3-5x slower than release, so passing here means release has headroom.
/// Budgets are enforced by scripts/perf.sh (CORRAL_PERF=1, release, serial). In the normal parallel
/// test run the numbers are only printed: other suites share the main thread and skew them.
@MainActor
@Suite(.serialized)
struct PerformanceTests {
    static let enforce = ProcessInfo.processInfo.environment["CORRAL_PERF"] != nil

    func p95(_ xs: [Double]) -> Double { BenchRunner.Metric.percentile(xs, 0.95) }

    func budget(_ name: String, _ value: Double, below limit: Double) {
        print("PERF \(name): \(String(format: "%.3f", value)) (budget \(limit))")
        if Self.enforce { #expect(value < limit, "\(name) over budget") }
    }

    func time(_ body: () -> Void) -> Double {
        let t0 = BenchRunner.now()
        body()
        return BenchRunner.ms(since: t0)
    }

    /// Manager + sidebar + container + window, like the real app.
    func makeApp(sessions: Int, folders: Int = 10, closed: Int = 0) -> (Fixture, MainWindowController) {
        let f = Fixture()
        let w = MainWindowController(manager: f.manager)
        var folderIds: [UUID] = []
        for i in 0..<folders { folderIds.append(f.manager.newFolder(name: "Folder \(i)")) }
        for i in 0..<(sessions + closed) {
            let folder: UUID? = folders > 0 && i % 3 != 0 ? folderIds[i % folders] : nil
            f.manager.newSession(agent: i % 2 == 0 ? .claude : .shell, cwd: f.dir.path, folder: .some(folder))
        }
        for id in f.manager.workspace.openSessionsInOrder.prefix(closed) { f.manager.close(id) }
        return (f, w)
    }

    @Test func benchRunnerEndToEndWithFakeTerminals() async throws {
        let f = Fixture()
        defer { f.cleanup() }
        f.factory.emitReady = true
        let marker = BenchRunner.stubMarker
        f.factory.onBinding = { t, binding in
            guard binding.hasPrefix("text:") else { return }
            // `exit` in the follow-up shell: libghostty (patched, no forced wait-after-command) closes it.
            if binding == "text:exit\\n" {
                DispatchQueue.main.async { f.manager.closeRequested(t, processAlive: false) }
                return
            }
            // Typed stub (old path): echoed command line, then its output.
            if binding.contains(marker) { t.text = "~ ❯ printf '%s\\n' \(marker); sleep 0.5\n\(marker)\n" }
            if binding.contains("INTEG") { t.text += "INTEG=1\n" }
            DispatchQueue.main.async {
                _ = f.manager.perform(.commandFinished(exitCode: 0, seconds: 0.01), terminal: t)
            }
        }
        // Direct stub agent: first frame, exit report, then the follow-up shell's prompt.
        f.factory.onMake = { t in
            guard t.launch.command != nil else { return }
            t.text = "\n\(marker)\n"
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                f.manager.handleHook(HookWire.Message(surface: t.sessionId,
                                                      event: HookEvent(agent: .claude, event: AgentLaunch.exitEvent, exitCode: 3)))
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                    _ = f.manager.perform(.pwd(f.dir.path), terminal: t)
                }
            }
        }
        let w = MainWindowController(manager: f.manager)
        let out = f.dir.appendingPathComponent("bench.json")
        let bench = BenchRunner(manager: f.manager, window: w, output: out)
        bench.tabCheck = false  // needs a real shell (scripts/perf.sh --app)
        bench.sessionCount = 12
        bench.commandRounds = 5
        bench.idleSeconds = Self.enforce ? 5 : 0.2
        await withCheckedContinuation { c in bench.run { c.resume() } }

        let metrics = try JSONDecoder().decode([BenchRunner.Metric].self, from: Data(contentsOf: out))
        let byName = Dictionary(uniqueKeysWithValues: metrics.map { ($0.name, $0) })
        for name in ["launch_to_ready", "memory_baseline", "session_create_sync", "session_shell_ready",
                     "memory_with_sessions", "command_round_trip", "switch_session", "status_update",
                     "idle_cpu", "session_close", "memory_after_close"] {
            #expect(byName[name] != nil, "\(name) missing")
        }
        #expect(byName["session_create_sync"]?.samples.count == 12)
        #expect(byName["agent_launch_clean"]?.p50 == 1)
        #expect((byName["agent_launch_ready"]?.p50 ?? -1) >= 0)
        #expect(byName["agent_exit_code"]?.p50 == 3)
        #expect(byName["followup_integration"]?.p50 == 1)
        #expect(byName["followup_command_finished"]?.p50 == 1)
        #expect(byName["followup_exit_closes"]?.p50 == 1)
        #expect(byName["agent_launch_orphans"]?.p50 == 0)
        #expect(byName["split_hosted"]?.p50 == 1)
        #expect(byName["split_exit_closes"]?.p50 == 1)
        #expect(byName["typed_launch_clean"]?.p50 == 0)
        #expect(byName["command_round_trip"]?.samples.count == 5)
        #expect(f.manager.live.isEmpty)
        // No polling: idle CPU is ~0. In-test this includes the test harness's own threads;
        // the real number comes from `scripts/perf.sh --app`.
        budget("idle CPU % (incl. test harness)", byName["idle_cpu"]?.p50 ?? 100, below: 2)
        print("PERF bench(fake terminals):", metrics.map { "\($0.name)=p50 \(String(format: "%.2f", $0.p50)) p95 \(String(format: "%.2f", $0.p95))\($0.unit)" }.joined(separator: ", "))

        // Benchmark environment never touches real state.
        let benchEnv = BenchRunner.environment()
        #expect(benchEnv.claudeBinary == nil)
        #expect(!benchEnv.notifications)
        #expect(benchEnv.store.url.path.contains("corral-bench-"))
        benchEnv.openURL(URL(fileURLWithPath: "/"))
        benchEnv.alert("", "")
        benchEnv.setBadge(nil)
        #expect(BenchRunner.footprintMB() > 0)
        #expect(BenchRunner.msSinceProcessStart() > 0)
        #expect(BenchRunner.Metric.percentile([], 0.5) == 0)
    }

    @Test func creatingSessionsStaysFast() {
        let (f, w) = makeApp(sessions: 0)
        defer { f.cleanup() }
        _ = w
        var samples: [Double] = []
        for _ in 0..<150 {
            samples.append(time { f.manager.newSession(agent: .shell, cwd: f.dir.path) })
        }
        budget("create session p95 ms (150 sessions, sidebar+container live)", p95(samples), below: 5)
    }

    @Test func switchingSessionsIsInstant() {
        let (f, w) = makeApp(sessions: 120)
        defer { f.cleanup() }
        var samples: [Double] = []
        for _ in 0..<300 {
            samples.append(time {
                f.manager.selectRelative(1)
                w.window?.contentView?.layoutSubtreeIfNeeded()
            })
        }
        budget("switch session p95 ms (120 sessions)", p95(samples), below: 4)
    }

    @Test func statusUpdatesAreCheap() {
        let (f, w) = makeApp(sessions: 120)
        defer { f.cleanup() }
        _ = w
        let ids = f.manager.workspace.openSessionsInOrder
        var samples: [Double] = []
        for i in 0..<1000 {
            let id = ids[i % ids.count]
            samples.append(time { f.manager.apply(.progress(i % 2 == 0 ? .active : .removed), to: id) })
        }
        budget("status update p95 ms", p95(samples), below: 1)
    }

    @Test func sidebarFullReloadScales() {
        let (f, w) = makeApp(sessions: 200, folders: 20, closed: 40)
        defer { f.cleanup() }
        var samples: [Double] = []
        for _ in 0..<30 {
            samples.append(time { w.sidebar.reload() })
        }
        budget("sidebar in-place refresh p95 ms (200 open, 20 folders, 40 closed)", p95(samples), below: 16)

        // Structural change through the animated diff path (one row in, one row out).
        var ops: [Double] = []
        for i in 0..<20 {
            ops.append(time {
                let id = f.manager.newFolder(name: "tmp \(i)")
                f.manager.deleteFolder(id)
            })
        }
        budget("sidebar insert+remove via diff p95 ms (2 structural updates)", p95(ops), below: 16)

        // Worst case: the diff gives up and the outline reloads everything.
        w.sidebar.planner = { _, _ in .reload }
        var full: [Double] = []
        for i in 0..<20 {
            full.append(time {
                let id = f.manager.newFolder(name: "tmp \(i)")
                f.manager.deleteFolder(id)
            })
        }
        budget("sidebar full reloadData p95 ms (2 full reloads, 280 rows)", p95(full), below: 32)
    }

    @Test func closingSessionsIncludingScrollback() {
        let (f, w) = makeApp(sessions: 60)
        defer { f.cleanup() }
        _ = w
        let scrollback = (0..<10_000).map { "line \($0): ./gradlew test --tests Foo" }.joined(separator: "\n")
        for t in f.factory.made { t.text = scrollback }
        var samples: [Double] = []
        for id in f.manager.workspace.openSessionsInOrder {
            samples.append(time { f.manager.close(id) })
        }
        budget("close session p95 ms (10k-line scrollback, indexed off-main)", p95(samples), below: 8)
    }

    @Test func hookToStatusLatency() async throws {
        let f = Fixture(start: true)
        defer { f.cleanup() }
        f.manager.newSession(agent: .claude, cwd: f.dir.path)
        let id = f.selected!
        // Timestamp the status change itself instead of polling for it.
        var changedAt: UInt64 = 0
        f.manager.observe { change in
            if case .status(let s) = change, s == id { changedAt = BenchRunner.now() }
        }
        var samples: [Double] = []
        for i in 0..<50 {
            let event = i % 2 == 0 ? "UserPromptSubmit" : "Stop"
            let line = try #require(HookWire.encode(surface: id.uuidString, agent: "claude", event: event, payload: nil))
            changedAt = 0
            let t0 = BenchRunner.now()
            EventClient.send(line, to: f.env.socketPath)
            await waitUntil(timeout: 2) { changedAt != 0 }
            samples.append(Double(changedAt &- t0) / 1e6)
        }
        budget("hook→status p95 ms (socket → reducer → sidebar)", p95(samples), below: 5)
    }

    @Test func workspaceSaveAndLoad() throws {
        let f = Fixture()
        defer { f.cleanup() }
        var ws = Workspace()
        for i in 0..<500 {
            var r = SessionRecord(cwd: "/repo/\(i)", agent: .claude, title: "Session \(i)", agentSessionId: UUID().uuidString)
            if i % 5 == 0 { r.closedAt = Date() }
            ws.addSession(r)
        }
        ws.repair()
        let store = f.env.store
        let save = time { try? store.save(ws) }
        var loaded = Workspace()
        let load = time { loaded = store.load() }
        #expect(loaded.sessions.count == 500)
        budget("save state ms (500 sessions)", save, below: 30)
        budget("load state ms (500 sessions)", load, below: 30)
    }

    @Test func searchPanelQueryLatency() async throws {
        let f = Fixture(start: true)
        defer { f.cleanup() }
        for i in 0..<300 {
            f.manager.index.addScrollback(session: UUID(), title: "s\(i)", cwd: "/r",
                                          text: (0..<200).map { "row \($0) token\(i % 7) kafka consumer lag" }.joined(separator: "\n"),
                                          created: Date(), closed: Date())
        }
        f.manager.index.queue.sync {}
        var samples: [Double] = []
        for q in ["kafka", "token3 lag", "consumer", "row 42", "zzz"] {
            let t0 = BenchRunner.now()
            _ = try f.manager.index.readQueue.sync { try f.manager.index.searchSync(q) }
            samples.append(BenchRunner.ms(since: t0))
        }
        budget("search p95 ms (300 sessions × 200 lines)", p95(samples), below: 15)
    }

    @Test func hookProcessOverhead() throws {
        // The C binary every Claude hook runs synchronously; the agent waits for it.
        // posix_spawn directly: Foundation.Process adds tens of ms of its own in a busy test process.
        guard let hook = HookBinary.path else { return }
        let input = FileManager.default.temporaryDirectory.appendingPathComponent("hook-in-\(UUID().uuidString)")
        try Data(#"{"hook_event_name":"Stop","session_id":"x"}"#.utf8).write(to: input)
        defer { try? FileManager.default.removeItem(at: input) }
        var samples: [Double] = []
        for _ in 0..<40 {
            let t0 = BenchRunner.now()
            #expect(Self.spawn(hook.path, ["claude", "Stop"], stdin: input.path,
                               env: ["CORRAL_SURFACE_ID=\(UUID().uuidString)", "CORRAL_SOCKET=/nonexistent.sock", "LLVM_PROFILE_FILE=/dev/null"]) == 0)
            samples.append(BenchRunner.ms(since: t0))
        }
        budget("corral-hook p95 ms per hook (incl. spawn)", p95(samples), below: 10)
    }

    static func spawn(_ path: String, _ args: [String], stdin: String, env: [String]) -> Int32 {
        var actions: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&actions)
        posix_spawn_file_actions_addopen(&actions, 0, stdin, O_RDONLY, 0)
        posix_spawn_file_actions_addopen(&actions, 1, "/dev/null", O_WRONLY, 0)
        defer { posix_spawn_file_actions_destroy(&actions) }
        let argv = ([path] + args).map { strdup($0) } + [nil]
        let envp = env.map { strdup($0) } + [nil]
        defer { (argv + envp).forEach { free($0) } }
        var pid: pid_t = 0
        guard posix_spawn(&pid, path, &actions, nil, argv, envp) == 0 else { return -1 }
        var status: Int32 = 0
        waitpid(pid, &status, 0)
        return (status >> 8) & 0xff
    }
}
