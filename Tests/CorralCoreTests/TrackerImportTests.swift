import Foundation
import Testing
@testable import CorralCore

struct TrackerImportTests {
    let rows: [TrackerImport.Row] = [
        .init(sid: "aaaaaaaa-1", status: "restore", background: false, cwd: "/repo", name: "Library Sync"),
        .init(sid: "bbbbbbbb-2", status: "restore", background: true, cwd: "/repo", name: "-"),
        .init(sid: "cccccccc-3", status: "running", background: true, cwd: "/repo", name: "Job"),
        .init(sid: "dddddddd-4", status: "running", background: false, cwd: "/repo", name: "In Ghostty"),
        .init(sid: "eeeeeeee-5", status: "skip", background: true, cwd: "/repo", name: "Done job", skip: "background job done"),
        .init(sid: "ffffffff-6", status: "restore", background: false, cwd: "/repo", name: "Known"),
    ]

    @Test func planSortsRowsIntoActions() {
        let plan = TrackerImport.plan(rows, known: ["ffffffff-6"])
        #expect(plan.actions == [.resume(rows[0]), .resumeBackground(rows[1]), .attach(rows[2])])
        #expect(plan.runningElsewhere == [rows[3]])
        #expect(plan.skipped.map(\.reason) == ["background job done", "already in Corral"])
        #expect(plan.forgetIds == ["aaaaaaaa-1", "bbbbbbbb-2", "cccccccc-3"])
        #expect(!plan.isEmpty)
        #expect(plan == TrackerImport.plan(rows, known: ["ffffffff-6"]))
    }

    @Test func inputsAndTitles() {
        #expect(TrackerImport.input(for: .resume(rows[0])) == "claude --resume aaaaaaaa-1")
        #expect(TrackerImport.input(for: .resumeBackground(rows[1])) == "claude --bg --resume bbbbbbbb-2 && claude attach bbbbbbbb")
        #expect(TrackerImport.input(for: .attach(rows[2])) == "claude attach cccccccc")
        #expect(rows[1].title == "")
        #expect(rows[0].title == "Library Sync")
        #expect(TrackerImport.Row(sid: "x", status: "restore", background: false, cwd: "/", name: "code-9b").title == "")
    }

    @Test func summaryExplainsWhatHappens() {
        let s = TrackerImport.summary(TrackerImport.plan(rows, known: []))
        #expect(s.contains("Resume 3 sessions"))
        #expect(s.contains("Attach 1 running background job."))
        #expect(s.contains("1 still running in Ghostty"))
        #expect(s.contains("In Ghostty"))
        let many = (0..<10).map { TrackerImport.Row(sid: "r\($0)", status: "running", background: false, cwd: "/", name: "n\($0)") }
        #expect(TrackerImport.summary(TrackerImport.plan(many, known: [])).contains("…and 2 more"))
        #expect(TrackerImport.plan([], known: []).isEmpty)
    }

    @Test func parsesTrackerJSON() throws {
        let json = #"[{"sid":"a","status":"restore","background":false,"cwd":"/r","name":"n","skip":null,"cmd":"x"}]"#
        #expect(try TrackerImport.parse(Data(json.utf8)).first?.sid == "a")
        #expect(throws: (any Error).self) { try TrackerImport.parse(Data("nope".utf8)) }
    }

    @Test func cliRunsTrackerBinary() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("tracker-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let log = dir.appendingPathComponent("forgot")
        let bin = dir.appendingPathComponent("claude-sessions")
        try """
        #!/bin/sh
        if [ "$1" = list ]; then echo '[{"sid":"a1","status":"restore","background":false,"cwd":"/r","name":"n"}]'; exit 0; fi
        if [ "$1" = forget ]; then shift; echo "$@" > "\(log.path)"; exit 0; fi
        echo boom >&2; exit 3
        """.write(to: bin, atomically: true, encoding: .utf8)
        chmod(bin.path, 0o755)

        let rows = await withCheckedContinuation { c in TrackerCLI.list(binary: bin.path) { c.resume(returning: $0) } }
        #expect((try? rows.get())?.first?.sid == "a1")
        let forgot = await withCheckedContinuation { c in TrackerCLI.forget(binary: bin.path, ids: ["a1", "b2"]) { c.resume(returning: $0) } }
        #expect((try? forgot.get()) != nil)
        #expect(try String(contentsOf: log, encoding: .utf8) == "a1 b2\n")
        let none = await withCheckedContinuation { c in TrackerCLI.forget(binary: bin.path, ids: []) { c.resume(returning: $0) } }
        #expect((try? none.get()) != nil)
        let failed = await withCheckedContinuation { c in TrackerCLI.run(bin.path, ["other"]) { c.resume(returning: $0) } }
        if case .failure(let e) = failed { #expect(e.localizedDescription.contains("boom")) } else { Issue.record("expected failure") }
        let missing = await withCheckedContinuation { c in TrackerCLI.run(dir.appendingPathComponent("nope").path, []) { c.resume(returning: $0) } }
        if case .success = missing { Issue.record("expected failure") }
        _ = TrackerCLI.defaultBinary
    }
}
