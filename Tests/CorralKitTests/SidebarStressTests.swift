import AppKit
@testable import CorralCore
import Testing
@testable import CorralKit

/// Random structure changes on a sidebar with many folders and a Closed section. The outline must show
/// exactly the model after every step, and its row views must sit on their rows: a row animation that
/// can't finish (no display) leaves them between rows, seen in the field as closed rows covering the
/// Closed header. Test windows are never on screen, so they stall animations like a sleeping display.
@MainActor
struct SidebarStressTests {
    typealias Kind = SidebarNode.Kind

    /// Deterministic, so a failing seed replays.
    struct SplitMix: RandomNumberGenerator {
        var state: UInt64
        mutating func next() -> UInt64 {
            state &+= 0x9E37_79B9_7F4A_7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
            z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
            return z ^ (z >> 31)
        }
    }

    /// Without animations nothing may leave a row view off its row, so nothing needs healing.
    @Test(arguments: [1, 2, 3, 4] as [UInt64])
    func outlineMatchesModelThroughRandomChanges(seed: UInt64) throws {
        let s = try run(seed: seed) { s, _ in s.rowViewsInPlace() }
        #expect(s.heals == 0)
    }

    /// With animations forced on, they stall here as they do in the field; the heal puts every row
    /// back. Synchronous: other main-actor tests must not run while the global switch is on.
    @Test(arguments: [1, 2] as [UInt64])
    func stalledAnimationsAreHealed(seed: UInt64) throws {
        let was = (SidebarFX.forceAnimations, Motion.enabled)
        SidebarFX.forceAnimations = true
        Motion.enabled = true
        defer { (SidebarFX.forceAnimations, Motion.enabled) = was }
        var stalled = false
        let s = try run(seed: seed) { s, step in
            guard step % 10 == 9 else { return true }
            if !s.rowViewsInPlace() { stalled = true }
            s.healIfNeeded()
            return s.rowViewsInPlace()
        }
        #expect(stalled && s.heals > 0, "the field failure reproduces here")
    }

    /// Runs random steps; `placed` is the row view check after each one.
    func run(seed: UInt64, placed: (SidebarViewController, Int) -> Bool) throws -> SidebarViewController {
        let t = SidebarTests()
        let (f, s, w) = t.makeWindowed(height: 500)
        defer { f.cleanup() }
        let m = f.manager!
        var rng = SplitMix(state: seed)
        var folders: [UUID] = []
        for i in 0..<24 {
            let parent = i > 4 && Bool.random(using: &rng) ? folders.randomElement(using: &rng) : nil
            folders.append(m.newFolder(name: "F\(i)", in: parent))
        }
        func newSession() {
            let folder: UUID?? = Bool.random(using: &rng) ? .some(folders.randomElement(using: &rng)) : .some(nil)
            m.newSession(agent: .claude, cwd: f.dir.path, folder: folder)
            if let sid = f.selected.flatMap({ m.workspace.sessions[$0]?.agentSessionId }) { f.transcripts(sid) }
        }
        for _ in 0..<30 { newSession() }
        for id in m.workspace.openSessionsInOrder.shuffled(using: &rng).prefix(12) { m.close(id) }
        t.settle(w)
        if !s.outline.isItemExpanded(s.node(.closedHeader)) { s.handleClick(row: t.row(s, .closedHeader)) }

        var log: [String] = []
        for step in 0..<200 {
            let open = m.workspace.openSessionsInOrder
            let closed = m.workspace.recentlyClosed(limit: SidebarViewController.closedLimit).map(\.id)
            switch Int.random(in: 0..<12, using: &rng) {
            case 0: newSession(); log.append("new")
            case 1: if let id = open.randomElement(using: &rng) { m.close(id); log.append("close") }
            case 2: if let id = closed.randomElement(using: &rng) {
                m.reopen(id, folder: .some(folders.randomElement(using: &rng)), at: nil); log.append("reopen")
            }
            case 3: if let id = closed.randomElement(using: &rng) { m.forget(id); log.append("forget") }
            case 4: folders.append(m.newFolder(name: "N\(step)", in: folders.randomElement(using: &rng))); log.append("folder")
            case 5: if folders.count > 3, let id = folders.randomElement(using: &rng) {
                m.deleteFolder(id); folders.removeAll { $0 == id }; log.append("delete folder")
            }
            case 6: if let id = open.randomElement(using: &rng) {
                _ = m.move(id, to: Bool.random(using: &rng) ? folders.randomElement(using: &rng) : nil, at: nil); log.append("move")
            }
            case 7: if let id = folders.randomElement(using: &rng), t.row(s, .folder(id)) >= 0 {
                s.toggle(s.node(.folder(id)), animated: true); log.append("toggle folder")
            }
            case 8: if t.row(s, .closedHeader) >= 0 { s.handleClick(row: t.row(s, .closedHeader)); log.append("toggle closed") }
            case 9:
                let n = Int.random(in: 0..<3, using: &rng)
                m.applyBackground((0..<n).map {
                    BackgroundAgent(id: "job\($0)\(step % 2)", sessionId: "s\($0)", name: "Job \($0)", cwd: f.dir.path, state: "working")
                })
                log.append("background \(n)")
            case 10: if let id = folders.randomElement(using: &rng) {
                _ = m.move(id, to: Bool.random(using: &rng) ? folders.randomElement(using: &rng) : nil, at: 0); log.append("move folder")
            }
            default: if let id = open.randomElement(using: &rng) { m.rename(id, to: "R\(step)"); log.append("rename") }
            }
            t.settle(w)
            let shown = t.shownItems(s), expected = t.expectedItems(s)
            let closedNow = !m.workspace.recentlyClosed(limit: SidebarViewController.closedLimit).isEmpty
            let header = t.row(s, .closedHeader)
            let orphans = shown.filter {
                guard case .closed = $0 else { return false }
                return (s.outline.parent(forItem: s.node($0)) as? SidebarNode)?.kind != .closedHeader
            }
            // Row heights are cached per row: they must still match each row's item.
            let wrongHeight = (0..<s.outline.numberOfRows).first { row in
                guard let item = s.outline.item(atRow: row) else { return true }
                return s.outline.rect(ofRow: row).height != s.outlineView(s.outline, heightOfRowByItem: item)
            }
            let inPlace = placed(s, step)
            guard shown == expected, closedNow == (header >= 0), orphans.isEmpty, wrongHeight == nil,
                  s.outline.hiddenRowIndexes.isEmpty, s.rowsMatchModel(), inPlace else {
                let what = "seed \(seed) step \(step) after \(log.suffix(4)): header row \(header), orphans \(orphans.count), "
                    + "rows \(shown.count)/\(expected.count), wrong height at \(String(describing: wrongHeight)), "
                    + "matches \(s.rowsMatchModel()), in place \(inPlace)"
                Issue.record(Comment(rawValue: what))
                return s
            }
        }
        return s
    }

    /// The reported layout: "Main" holding folders with loose sessions between them, empty folders,
    /// many closed sessions with Closed open; sessions close and reopen in and out of Main.
    @Test func closedHeaderStaysWithLooseSessionsBetweenFolders() throws {
        let t = SidebarTests()
        let (f, s, w) = t.makeWindowed(height: 1100)
        defer { f.cleanup() }
        let m = f.manager!
        func session(in folder: UUID?) -> UUID {
            m.newSession(agent: .claude, cwd: f.dir.path, folder: .some(folder))
            let id = f.selected!
            if let sid = m.workspace.sessions[id]?.agentSessionId { f.transcripts(sid) }
            return id
        }
        let main = m.newFolder(name: "Main")
        let high = m.newFolder(name: "High Prio", in: main)
        _ = m.newFolder(name: "Daily", in: main)
        for _ in 0..<2 { _ = session(in: high) }
        var loose = (0..<6).map { _ in session(in: main) }
        for name in ["Code reviews", "Random Requests"] { _ = m.newFolder(name: name, in: main) }
        let selfDriven = m.newFolder(name: "Self driven", in: main)
        for _ in 0..<4 { _ = session(in: selfDriven) }
        for _ in 0..<20 { m.close(session(in: nil)) }
        t.settle(w)
        if !s.outline.isItemExpanded(s.node(.closedHeader)) { s.handleClick(row: t.row(s, .closedHeader)) }
        t.settle(w)
        func check(_ what: String) {
            let header = t.row(s, .closedHeader)
            #expect(header >= 0 && t.shownItems(s) == t.expectedItems(s) && s.rowsMatchModel() && s.rowViewsInPlace(),
                    "\(what): header row \(header)")
        }
        check("start")
        for step in 0..<12 {
            let id = loose.removeFirst()
            m.close(id)
            t.settle(w)
            check("close \(step)")
            m.reopen(id, folder: .some(step % 2 == 0 ? main : selfDriven), at: nil)
            loose.append(id)
            t.settle(w)
            check("reopen \(step)")
        }
        #expect(s.heals == 0)
    }

    /// An open folder moves as a remove and an insert (with or without full motion): it stays open, and
    /// its children's rows get their own heights (moveItem left them with the replaced rows' heights).
    @Test(arguments: [false, true])
    func movedFolderKeepsItsExpansion(reduced: Bool) throws {
        let t = SidebarTests()
        let (f, s, w) = t.makeWindowed()
        defer { f.cleanup() }
        let was = (Motion.assumeVisible, Motion.reduced)
        Motion.assumeVisible = true
        Motion.setReduced(reduced)
        defer {
            Motion.assumeVisible = was.0
            Motion.setReduced(was.1)
        }
        let m = f.manager!
        let a = m.newFolder(name: "A"), b = m.newFolder(name: "B")
        m.newSession(agent: .shell, cwd: f.dir.path, folder: .some(a))
        m.newSession(agent: .shell, cwd: f.dir.path, folder: .some(b))
        m.newSession(agent: .shell, cwd: f.dir.path, folder: .some(b))
        t.settle(w)
        let reloads = s.outline.reloadCount
        _ = m.move(b, to: nil, at: 0)
        t.settle(w)
        #expect(s.outline.isItemExpanded(s.node(.folder(b))) && s.rowsMatchModel())
        #expect(t.shownItems(s) == t.expectedItems(s) && s.outline.reloadCount == reloads)
        let wrong = (0..<s.outline.numberOfRows).first { row in
            guard let item = s.outline.item(atRow: row) else { return true }
            return s.outline.rect(ofRow: row).height != s.outlineView(s.outline, heightOfRowByItem: item)
        }
        #expect(wrong == nil)
        _ = m.move(a, to: b, at: 0)
        t.settle(w)
        #expect(s.outline.isItemExpanded(s.node(.folder(a))) && s.rowsMatchModel() && s.outline.reloadCount == reloads)
    }

    /// Rows or row views out of step with the model are noticed (when structure updates settle, when
    /// Corral comes back to the front) and reloaded with the selection kept; an intact list is left alone.
    @Test func healsRowsLeftOutOfStep() async throws {
        let t = SidebarTests()
        let (f, s, w) = t.makeWindowed()
        defer { f.cleanup() }
        let m = f.manager!
        let folder = m.newFolder(name: "Main")
        for _ in 0..<3 { m.newSession(agent: .shell, cwd: f.dir.path, folder: .some(folder)) }
        let selected = try #require(f.selected)
        for _ in 0..<3 {
            m.newSession(agent: .claude, cwd: f.dir.path, folder: .some(nil))
            m.close(f.selected!)
        }
        m.select(selected)
        t.settle(w)
        if !s.outline.isItemExpanded(s.node(.closedHeader)) { s.handleClick(row: t.row(s, .closedHeader)) }
        t.settle(w)
        s.healIfNeeded()
        #expect(s.heals == 0 && s.rowsMatchModel() && s.rowViewsInPlace())

        // A row view left where an animation stopped covers the one above it: the settle check finds it.
        let header = t.row(s, .closedHeader)
        let below = try #require(s.outline.rowView(atRow: header + 1, makeIfNecessary: false))
        below.frame.origin.y -= 30
        #expect(!s.rowViewsInPlace())
        let delay = SidebarViewController.settleDelay
        SidebarViewController.settleDelay = 0.05
        defer { SidebarViewController.settleDelay = delay }
        s.scheduleSettleCheck()
        try await Task.sleep(for: .milliseconds(300))
        t.settle(w)
        #expect(s.heals == 1 && s.rowViewsInPlace())

        // A row left at another item's height in AppKit's cache: a session cut to a folder's 28 pt.
        let session = try #require(m.workspace.openSessionsInOrder.first)
        let sessionRow = t.row(s, .session(session))
        s.rowHeightOverride = { $0.kind == .session(session) ? 28 : nil }
        s.outline.noteHeightOfRows(withIndexesChanged: [sessionRow])
        s.rowHeightOverride = nil
        t.settle(w)
        #expect(s.outline.rect(ofRow: sessionRow).height == 28 && !s.rowViewsInPlace())
        s.healIfNeeded()
        t.settle(w)
        #expect(s.heals == 2 && s.outline.rect(ofRow: t.row(s, .session(session))).height == 38 && s.rowViewsInPlace())

        // Coming back to the front: the header gone from the outline while the model still has it.
        s.outline.removeItems(at: [s.roots.count - 1], inParent: nil, withAnimation: [])
        #expect(t.row(s, .closedHeader) < 0 && !s.rowsMatchModel())
        NotificationCenter.default.post(name: NSApplication.didBecomeActiveNotification, object: NSApp)
        t.settle(w)
        #expect(s.heals == 3 && t.row(s, .closedHeader) >= 0 && s.rowsMatchModel())
        #expect(m.workspace.selected == selected && s.outline.selectedRow == t.row(s, .session(selected)))
    }

    @Test func nothingAnimatesWhileDisplaysSleep() {
        let v = NSView()
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 10, height: 10), styleMask: [.borderless], backing: .buffered, defer: true)
        w.isReleasedWhenClosed = false
        w.contentView = v
        let was = (Motion.assumeVisible, Motion.displaysAsleep, Motion.enabled)
        defer { (Motion.assumeVisible, Motion.displaysAsleep, Motion.enabled) = was }
        Motion.assumeVisible = true
        Motion.enabled = true
        Motion.displaysAsleep = false
        #expect(Motion.shouldAnimate(v))
        Motion.displaysAsleep = true
        #expect(!Motion.shouldAnimate(v))
    }
}
