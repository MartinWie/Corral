import AppKit
@testable import CorralCore
import Testing
@testable import CorralKit

@MainActor
struct TrackerTakeoverTests {
    func fakeTracker(_ dir: URL, rows: String) throws -> (bin: URL, log: URL) {
        let log = dir.appendingPathComponent("forgot")
        let bin = dir.appendingPathComponent("claude-sessions")
        try """
        #!/bin/sh
        if [ "$1" = list ]; then echo '\(rows)'; exit 0; fi
        if [ "$1" = forget ]; then shift; echo "$@" > "\(log.path)"; exit 0; fi
        exit 2
        """.write(to: bin, atomically: true, encoding: .utf8)
        chmod(bin.path, 0o755)
        return (bin, log)
    }

    @Test func importCreatesSessionsInAFolder() {
        let f = Fixture()
        defer { f.cleanup() }
        let rows = [
            TrackerImport.Row(sid: "s-1", status: "restore", background: false, cwd: f.dir.path, name: "Library Sync"),
            TrackerImport.Row(sid: "jobjobjob-2", status: "running", background: true, cwd: f.dir.path, name: "Job"),
        ]
        let ids = f.manager.importTracked(TrackerImport.plan(rows, known: []))
        #expect(ids == ["s-1", "jobjobjob-2"])
        let folder = f.manager.workspace.folders.values.first { $0.name == "From Ghostty" }
        #expect(folder != nil)
        let inFolder = f.manager.workspace.children(of: folder!.id).map(\.id)
        #expect(inFolder.count == 2)
        let resumed = f.manager.workspace.sessions[inFolder[0]]!
        #expect(resumed.customName == "Library Sync")
        #expect(resumed.agentSessionId == "s-1")
        #expect(f.terminal(inFolder[0])?.launch.agentInput == "claude --resume s-1")
        let attached = f.manager.workspace.sessions[inFolder[1]]!
        #expect(attached.bgJobId == "jobjobjo")
        #expect(f.terminal(inFolder[1])?.launch.agentInput == "claude attach jobjobjo")
        #expect(f.manager.knownAgentSessionIds.isSuperset(of: ["s-1", "jobjobjob-2"]))
        // Importing again finds nothing new.
        #expect(TrackerImport.plan(rows, known: f.manager.knownAgentSessionIds).isEmpty)
    }

    @Test func singleImportGoesNextToSelection() {
        let f = Fixture()
        defer { f.cleanup() }
        f.manager.importTracked(TrackerImport.plan([.init(sid: "one", status: "restore", background: false, cwd: f.dir.path, name: "-")], known: []))
        #expect(f.manager.workspace.folders.isEmpty)
        #expect(f.manager.workspace.sessions[f.selected!]?.customName == nil)
    }

    /// Waits are long: the fake tracker is a script, slow to start while the whole suite runs.
    @Test func menuFlowConfirmsImportsAndForgets() async throws {
        let f = Fixture()
        defer { f.cleanup() }
        let rows = #"[{"sid":"s-1","status":"restore","background":false,"cwd":"\#(f.dir.path)","name":"A"},{"sid":"s-2","status":"running","background":false,"cwd":"/","name":"Busy"}]"#
        let (bin, log) = try fakeTracker(f.dir, rows: rows)
        var env = f.env
        env.trackerBinary = bin.path
        let d = AppDelegate(makeTerminals: { f.factory }, environment: { env })
        var titles: [String] = []
        var answer: NSApplication.ModalResponse = .alertSecondButtonReturn
        d.runAlert = { titles.append($0.messageText); return answer }
        d.launch(showWindow: false)
        defer { d.manager.prepareForTermination() }

        d.importFromTracker(nil)
        await waitUntil(timeout: 30) { titles.count == 1 }
        #expect(titles.last == "Take over 1 session from Ghostty?")
        #expect(d.manager.live.isEmpty, "cancel imports nothing")

        answer = .alertFirstButtonReturn
        d.importFromTracker(nil)
        await waitUntil(timeout: 30) { FileManager.default.fileExists(atPath: log.path) }
        #expect(d.manager.live.count == 1)
        #expect(try String(contentsOf: log, encoding: .utf8) == "s-1\n")

        d.importFromTracker(nil)
        await waitUntil(timeout: 30) { titles.count == 3 }
        #expect(titles.last == "Nothing to take over yet")
    }

    @Test func missingOrBrokenTracker() async throws {
        let f = Fixture()
        defer { f.cleanup() }
        var env = f.env
        env.trackerBinary = nil
        let d = AppDelegate(makeTerminals: { f.factory }, environment: { env })
        var titles: [String] = []
        d.runAlert = { titles.append($0.messageText); return .alertFirstButtonReturn }
        d.launch(showWindow: false)
        defer { d.manager.prepareForTermination() }
        d.importFromTracker(nil)
        #expect(titles.last == "claude-sessions not found")

        let broken = f.dir.appendingPathComponent("broken")
        try "#!/bin/sh\necho nope >&2\nexit 1\n".write(to: broken, atomically: true, encoding: .utf8)
        chmod(broken.path, 0o755)
        var env2 = f.env
        env2.trackerBinary = broken.path
        let d2 = AppDelegate(makeTerminals: { f.factory }, environment: { env2 })
        d2.runAlert = { titles.append($0.messageText); return .alertFirstButtonReturn }
        d2.launch(showWindow: false)
        defer { d2.manager.prepareForTermination() }
        d2.importFromTracker(nil)
        await waitUntil { titles.count == 2 }
        #expect(titles.last == "Couldn't read claude-sessions")
    }
}
