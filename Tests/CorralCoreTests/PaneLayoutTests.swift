import Foundation
import Testing
@testable import CorralCore

struct PaneLayoutTests {
    let main = UUID(), a = UUID(), b = UUID(), c = UUID()

    @Test func splitsPlaceThePaneOnTheRequestedSide() {
        let root = PaneLayout.leaf(main)
        #expect(root.splitting(main, with: a, direction: .right) == .split(sideBySide: true, first: .leaf(main), second: .leaf(a)))
        #expect(root.splitting(main, with: a, direction: .down) == .split(sideBySide: false, first: .leaf(main), second: .leaf(a)))
        #expect(root.splitting(main, with: a, direction: .left) == .split(sideBySide: true, first: .leaf(a), second: .leaf(main)))
        #expect(root.splitting(main, with: a, direction: .up) == .split(sideBySide: false, first: .leaf(a), second: .leaf(main)))
        // Splitting a leaf that isn't there changes nothing.
        #expect(root.splitting(b, with: a, direction: .right) == root)
    }

    @Test func nestedSplitsRemoveAndNavigate() {
        let l = PaneLayout.leaf(main)
            .splitting(main, with: a, direction: .right)
            .splitting(a, with: b, direction: .down)
            .splitting(main, with: c, direction: .down)
        #expect(l.leaves == [main, c, a, b])
        #expect(l.contains(b) && !l.contains(UUID()))
        #expect(l.neighbor(of: main, offset: 1) == c)
        #expect(l.neighbor(of: b, offset: 1) == main)
        #expect(l.neighbor(of: main, offset: -1) == b)
        #expect(l.neighbor(of: UUID(), offset: 1) == nil)
        #expect(PaneLayout.leaf(main).neighbor(of: main, offset: 1) == nil)
        // Removing a pane gives its space to the sibling.
        let without = l.removing(a)
        #expect(without?.leaves == [main, c, b])
        #expect(without?.removing(c)?.removing(b) == .leaf(main))
        #expect(PaneLayout.leaf(main).removing(main) == nil)
        #expect(l.removing(UUID()) == l)
    }
}

struct SideBySideLayoutTests {
    let a = UUID(), b = UUID(), c = UUID()

    @Test func addingWrapsTheWholeLayout() {
        let ab = PaneLayout.leaf(a).splitting(a, with: b, direction: .right)
        #expect(ab.adding(.leaf(c), direction: .down) == .split(sideBySide: false, first: ab, second: .leaf(c)))
        #expect(ab.adding(.leaf(c), direction: .left) == .split(sideBySide: true, first: .leaf(c), second: ab))
        #expect(PaneLayout.leaf(a).inserting(ab, at: a, direction: .up) == .split(sideBySide: false, first: ab, second: .leaf(a)))
        #expect(ab.isSplit && !PaneLayout.leaf(a).isSplit)
    }

    @Test func filteringKeepsTheShape() {
        let l = PaneLayout.split(sideBySide: true, first: .leaf(a), second: .split(sideBySide: false, first: .leaf(b), second: .leaf(c)))
        #expect(l.filtered { $0 != b } == .split(sideBySide: true, first: .leaf(a), second: .leaf(c)))
        #expect(l.filtered { $0 == c } == .leaf(c))
        #expect(l.filtered { _ in false } == nil)
        #expect(l.filtered { _ in true } == l)
    }

    @Test func layoutsRoundTrip() throws {
        let l = PaneLayout.split(sideBySide: false, first: .leaf(a), second: .leaf(b))
        #expect(try JSONDecoder().decode(PaneLayout.self, from: JSONEncoder().encode(l)) == l)
    }

    @Test func workspaceKeepsOpenSplitsOnly() throws {
        var w = Workspace()
        for id in [a, b, c] { w.addSession(SessionRecord(id: id, cwd: "/tmp", agent: .claude), in: nil, at: nil) }
        let abc = PaneLayout.split(sideBySide: true, first: .leaf(a), second: .split(sideBySide: false, first: .leaf(b), second: .leaf(c)))
        w.setSplits([a: abc, b: .leaf(b)])
        #expect(w.splits == [a: abc])
        // Saved and loaded with the rest.
        let back = try JSONDecoder().decode(Workspace.self, from: JSONEncoder().encode(w))
        #expect(back.splits == [a: abc] && back == w)
        // Closing the holder hands the card to the next session.
        w.close(a)
        #expect(w.splits == [b: .split(sideBySide: false, first: .leaf(b), second: .leaf(c))])
        w.forget(c)
        #expect(w.splits.isEmpty)
        // State from an older run: closed or unknown members drop out.
        var old = Workspace()
        for id in [a, b] { old.addSession(SessionRecord(id: id, cwd: "/tmp", agent: .claude), in: nil, at: nil) }
        let stale = UUID()
        old.setSplits([stale: .split(sideBySide: true, first: .leaf(stale), second: .split(sideBySide: true, first: .leaf(a), second: .leaf(b)))])
        #expect(old.openSplits == [a: .split(sideBySide: true, first: .leaf(a), second: .leaf(b))])
        old.close(b)
        #expect(old.openSplits.isEmpty)
        // Files without splits load fine.
        #expect(try JSONDecoder().decode(Workspace.self, from: Data("{}".utf8)).splits.isEmpty)
    }
}

struct DirectionalFocusTests {
    let a = UUID(), b = UUID(), c = UUID(), d = UUID()

    @Test func boxesHalveEachSplit() {
        // [a | (b / c)]
        let l = PaneLayout.split(sideBySide: true, first: .leaf(a), second: .split(sideBySide: false, first: .leaf(b), second: .leaf(c)))
        let boxes = l.boxes()
        #expect(boxes[a] == PaneBox(x: 0, y: 0, width: 0.5, height: 1))
        #expect(boxes[b] == PaneBox(x: 0.5, y: 0, width: 0.5, height: 0.5))
        #expect(boxes[c] == PaneBox(x: 0.5, y: 0.5, width: 0.5, height: 0.5))
        #expect(boxes[c]?.maxX == 1 && boxes[c]?.maxY == 1)
    }

    @Test func neighborsFollowTheGeometryNotTheReadingOrder() {
        // [a | (b / c)]: from c, left is a (reading order would give b).
        let l = PaneLayout.split(sideBySide: true, first: .leaf(a), second: .split(sideBySide: false, first: .leaf(b), second: .leaf(c)))
        #expect(l.neighbor(of: c, toward: .left) == a)
        #expect(l.neighbor(of: c, toward: .up) == b)
        #expect(l.neighbor(of: b, toward: .down) == c)
        #expect(l.neighbor(of: a, toward: .right) == b)  // b and c touch a equally: the first in reading order
        #expect(l.neighbor(of: a, toward: .left) == nil)
        #expect(l.neighbor(of: a, toward: .down) == nil)
        #expect(l.neighbor(of: b, toward: .up) == nil)
        #expect(l.neighbor(of: d, toward: .up) == nil)

        // [(a | b) / (c | d)] with a different split: nearest first, then most shared edge.
        let grid = PaneLayout.split(sideBySide: false, first: .split(sideBySide: true, first: .leaf(a), second: .leaf(b)),
                                    second: .split(sideBySide: true, first: .leaf(c), second: .leaf(d)))
        #expect(grid.neighbor(of: d, toward: .up) == b)
        #expect(grid.neighbor(of: d, toward: .left) == c)
        #expect(grid.neighbor(of: a, toward: .down) == c)
        // [a / (b | (c / d))]: from d up, b's box doesn't overlap d horizontally; a does, at a gap.
        let deep = PaneLayout.split(sideBySide: false, first: .leaf(a),
                                    second: .split(sideBySide: true, first: .leaf(b), second: .split(sideBySide: false, first: .leaf(c), second: .leaf(d))))
        #expect(deep.neighbor(of: d, toward: .up) == c)
        #expect(deep.neighbor(of: c, toward: .up) == a)
        #expect(deep.neighbor(of: b, toward: .right) == c)
        #expect(PaneLayout.leaf(a).neighbor(of: a, toward: .right) == nil)
    }

    @Test func realPositionsAndTiesThatGoBack() {
        // [(a / b) | (c / d)], left divider dragged to 80 %, right one to 20 %.
        let grid = PaneLayout.split(sideBySide: true, first: .split(sideBySide: false, first: .leaf(a), second: .leaf(b)),
                                    second: .split(sideBySide: false, first: .leaf(c), second: .leaf(d)))
        let dragged: [UUID: PaneBox] = [
            a: PaneBox(x: 0, y: 0, width: 0.5, height: 0.8), b: PaneBox(x: 0, y: 0.8, width: 0.5, height: 0.2),
            c: PaneBox(x: 0.5, y: 0, width: 0.5, height: 0.2), d: PaneBox(x: 0.5, y: 0.2, width: 0.5, height: 0.8),
        ]
        #expect(grid.neighbor(of: a, toward: .right) == c)  // even halves: c
        #expect(grid.neighbor(of: a, toward: .right, boxes: dragged) == d)  // shares more of a's edge
        #expect(grid.neighbor(of: d, toward: .left, boxes: dragged) == a)
        // Leaves not on screen (a session still starting) aren't candidates.
        var shown = dragged
        shown[d] = nil
        #expect(grid.neighbor(of: a, toward: .right, boxes: shown) == c)
        // Ties: back where focus came from, else the first.
        let l = PaneLayout.split(sideBySide: true, first: .split(sideBySide: false, first: .leaf(a), second: .leaf(b)), second: .leaf(c))
        #expect(l.neighbor(of: c, toward: .left) == a)
        #expect(l.neighbor(of: c, toward: .left, prefer: b) == b)
        #expect(l.neighbor(of: c, toward: .left, prefer: d) == a)
    }
}
