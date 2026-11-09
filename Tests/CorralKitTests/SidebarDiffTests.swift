import AppKit
import Foundation
import Testing
@testable import CorralKit

/// Pure checks run off the main actor; only the NSOutlineView cross-checks hop to it.
struct SidebarDiffTests {
    typealias Tree = [String?: [String]]
    typealias Op = SidebarDiff.Op<String>
    typealias Kind = SidebarNode.Kind
    typealias Kinds = [Kind?: [Kind]]

    /// The plan, after checking that the scanning and the indexed lookups agree on it.
    func plan<K: Hashable>(_ old: [K?: [K]], _ new: [K?: [K]],
                           sourceLocation: SourceLocation = #_sourceLocation) -> SidebarDiff.Plan<K> {
        let scanned = SidebarDiff.plan(old: old, new: new, scanLimit: .max)
        #expect(SidebarDiff.plan(old: old, new: new, scanLimit: 0) == scanned, "lookups disagree",
                sourceLocation: sourceLocation)
        #expect(SidebarDiff.plan(old: old, new: new) == scanned, sourceLocation: sourceLocation)
        return scanned
    }

    /// The plan is exactly `expected`, and applying it (to lists, and to a real outline with every
    /// folder expanded or every folder collapsed) yields `new`.
    @MainActor
    func expectPlan<K: Hashable>(_ old: [K?: [K]], _ new: [K?: [K]], _ expected: [SidebarDiff.Op<K>],
                                 sourceLocation: SourceLocation = #_sourceLocation) {
        let p = plan(old, new, sourceLocation: sourceLocation)
        #expect(p == .ops(expected), sourceLocation: sourceLocation)
        guard case .ops(let ops) = p else { return }
        #expect(DiffHarness.apply(ops, old: old, new: new) == DiffHarness.normalized(new), sourceLocation: sourceLocation)
        #expect(DiffHarness.inApplyOrder(ops), sourceLocation: sourceLocation)
        let rows = DiffHarness.rows(new)
        #expect(DiffHarness.outlineRows(ops, old: old, new: new) == rows, sourceLocation: sourceLocation)
        let parents = Set(old.keys.compactMap { $0 })
        #expect(DiffHarness.outlineRows(ops, old: old, new: new, collapsed: parents) == rows, sourceLocation: sourceLocation)
    }

    @MainActor
    func expectOps(_ old: Tree, _ new: Tree, _ expected: [Op], sourceLocation: SourceLocation = #_sourceLocation) {
        expectPlan(old, new, expected, sourceLocation: sourceLocation)
    }

    func expectReload(_ old: Tree, _ new: Tree, sourceLocation: SourceLocation = #_sourceLocation) {
        #expect(plan(old, new, sourceLocation: sourceLocation) == .reload, sourceLocation: sourceLocation)
    }

    // MARK: No change

    @MainActor @Test func identicalTreesHaveNoOps() {
        let t: Tree = [nil: ["a", "F"], "F": ["x", "y"]]
        expectOps(t, t, [])
        expectOps([:], [:], [])
    }

    @MainActor @Test func representationOnlyDifferencesHaveNoOps() {
        // Empty entry vs no entry, stale entries of unreachable keys.
        expectOps([nil: ["a", "F"], "F": []], [nil: ["a", "F"], "a": []], [])
        expectOps([nil: ["a"]], [nil: ["a"], "gone": ["x", "y"]], [])
        expectOps([nil: []], [:], [])
    }

    // MARK: Inserts

    @MainActor @Test func insertsAtStartMiddleAndEnd() {
        let old: Tree = [nil: ["a", "b", "c"]]
        expectOps(old, [nil: ["x", "a", "b", "c"]], [.insert(parent: nil, index: 0)])
        expectOps(old, [nil: ["a", "x", "b", "c"]], [.insert(parent: nil, index: 1)])
        expectOps(old, [nil: ["a", "b", "c", "x"]], [.insert(parent: nil, index: 3)])
        expectOps(old, [nil: ["x", "a", "y", "b", "c", "z"]],
                  [.insert(parent: nil, index: 0), .insert(parent: nil, index: 2), .insert(parent: nil, index: 5)])
        expectOps(old, [nil: ["a", "b", "x", "y", "c"]], [.insert(parent: nil, index: 2), .insert(parent: nil, index: 3)])
        expectOps([:], [nil: ["a", "b"]], [.insert(parent: nil, index: 0), .insert(parent: nil, index: 1)])
    }

    @MainActor @Test func insertsAcrossParentsComeInTreeOrder() {
        let old: Tree = [nil: ["G", "a", "F"], "F": ["x"], "G": ["y"]]
        let new: Tree = [nil: ["G", "a", "b", "F"], "F": ["x", "x2"], "G": ["y0", "y"]]
        expectOps(old, new, [
            .insert(parent: nil, index: 2), .insert(parent: "G", index: 0), .insert(parent: "F", index: 1),
        ])
    }

    @MainActor @Test func insertIntoNestedAndPreviouslyEntrylessFolder() {
        // F existed but had no entry (empty); G is nested inside F.
        let old: Tree = [nil: ["F", "H"], "H": ["G"], "G": ["g1"]]
        let new: Tree = [nil: ["F", "H"], "F": ["f1"], "H": ["G"], "G": ["g1", "g2"]]
        expectOps(old, new, [.insert(parent: "F", index: 0), .insert(parent: "G", index: 1)])
    }

    @MainActor @Test func appearingParentIsOneInsertWithItsChildren() {
        // A section header appears with children; a new folder arrives with a subfolder.
        expectOps([nil: ["a", "b"]], [nil: ["a", "b", "bgHeader"], "bgHeader": ["j1", "j2"]],
                  [.insert(parent: nil, index: 2)])
        expectOps([nil: ["a"], "F": ["x"]], [nil: ["N", "a"], "F": ["x"], "N": ["M", "n1"], "M": ["m1"]],
                  [.insert(parent: nil, index: 0)])
    }

    // MARK: Removes

    @MainActor @Test func removesUseOldIndexesDescending() {
        let old: Tree = [nil: ["a", "b", "c", "d", "e"]]
        expectOps(old, [nil: ["b", "c", "d", "e"]], [.remove(parent: nil, index: 0)])
        expectOps(old, [nil: ["a", "b", "d", "e"]], [.remove(parent: nil, index: 2)])
        expectOps(old, [nil: ["a", "b", "c", "d"]], [.remove(parent: nil, index: 4)])
        expectOps(old, [nil: ["b", "d"]],
                  [.remove(parent: nil, index: 4), .remove(parent: nil, index: 2), .remove(parent: nil, index: 0)])
        expectOps(old, [:], (0..<5).reversed().map { .remove(parent: nil, index: $0) })
    }

    @MainActor @Test func removesAcrossParents() {
        let old: Tree = [nil: ["a", "F", "b"], "F": ["x", "y", "z"]]
        let new: Tree = [nil: ["F", "b"], "F": ["y"]]
        expectOps(old, new, [
            .remove(parent: nil, index: 0), .remove(parent: "F", index: 2), .remove(parent: "F", index: 0),
        ])
        // The folder empties and loses its entry.
        expectOps(old, [nil: ["a", "F", "b"]], [
            .remove(parent: "F", index: 2), .remove(parent: "F", index: 1), .remove(parent: "F", index: 0),
        ])
    }

    @MainActor @Test func disappearingParentIsOneRemove() {
        let old: Tree = [nil: ["a", "F", "closedHeader"], "F": ["x", "G"], "G": ["g"], "closedHeader": ["c1"]]
        expectOps(old, [nil: ["a", "closedHeader"], "closedHeader": ["c1"]], [.remove(parent: nil, index: 1)])
        // A stale entry for the removed folder is ignored.
        expectOps(old, [nil: ["a", "F"], "F": ["x", "G"], "G": ["g"], "closedHeader": ["c2"]],
                  [.remove(parent: nil, index: 2)])
    }

    // MARK: Removes and inserts together

    @MainActor @Test func removesAndInsertsInDifferentParents() {
        let old: Tree = [nil: ["a", "b", "c", "F"], "F": ["x"]]
        // Every remove comes first, then every insert.
        expectOps(old, [nil: ["b", "c", "F"], "F": ["x", "a2"]], [.remove(parent: nil, index: 0), .insert(parent: "F", index: 1)])
        expectOps(old, [nil: ["a", "b", "c", "d", "F"], "F": []], [.remove(parent: "F", index: 0), .insert(parent: nil, index: 3)])
        expectOps(old, [nil: ["a", "b", "c", "F", "d"]], [.remove(parent: "F", index: 0), .insert(parent: nil, index: 4)])
        expectOps(old, [nil: ["F", "d"], "F": ["x", "y", "z"]], [
            .remove(parent: nil, index: 2), .remove(parent: nil, index: 1), .remove(parent: nil, index: 0),
            .insert(parent: nil, index: 1), .insert(parent: "F", index: 1), .insert(parent: "F", index: 2),
        ])
    }

    @MainActor @Test func removesAndInsertsInOneParentKeepingOrder() {
        let old: Tree = [nil: ["a", "b", "c", "F"], "F": ["x"]]
        expectOps(old, [nil: ["a", "c", "d", "F"], "F": ["x"]], [.remove(parent: nil, index: 1), .insert(parent: nil, index: 2)])
        expectOps(old, [nil: ["a", "d", "c", "F"], "F": ["x"]], [.remove(parent: nil, index: 1), .insert(parent: nil, index: 1)])
        expectOps(old, [nil: ["a", "c", "d", "e", "F"], "F": ["x"]],
                  [.remove(parent: nil, index: 1), .insert(parent: nil, index: 2), .insert(parent: nil, index: 3)])
        expectOps(old, [nil: ["n", "F"], "F": ["x"]], [
            .remove(parent: nil, index: 2), .remove(parent: nil, index: 1), .remove(parent: nil, index: 0),
            .insert(parent: nil, index: 0),
        ])
        expectOps([nil: ["a", "b"]], [nil: ["c", "d"]], [
            .remove(parent: nil, index: 1), .remove(parent: nil, index: 0),
            .insert(parent: nil, index: 0), .insert(parent: nil, index: 1),
        ])
        // A closed session replaces its open row and the Closed header appears.
        expectOps([nil: ["s1", "s2"]], [nil: ["s2", "closedHeader"], "closedHeader": ["c1"]],
                  [.remove(parent: nil, index: 0), .insert(parent: nil, index: 1)])
    }

    // MARK: Moves

    @MainActor @Test func singleMoveWithinParent() {
        let old: Tree = [nil: ["a", "b", "c", "d", "e"]]
        // Down: adjacent and far.
        expectOps(old, [nil: ["b", "a", "c", "d", "e"]], [.move(fromParent: nil, from: 0, toParent: nil, to: 1)])
        expectOps(old, [nil: ["b", "c", "d", "e", "a"]], [.move(fromParent: nil, from: 0, toParent: nil, to: 4)])
        expectOps(old, [nil: ["a", "c", "d", "b", "e"]], [.move(fromParent: nil, from: 1, toParent: nil, to: 3)])
        // Up: adjacent and far.
        expectOps(old, [nil: ["a", "b", "c", "e", "d"]], [.move(fromParent: nil, from: 3, toParent: nil, to: 4)])
        expectOps(old, [nil: ["e", "a", "b", "c", "d"]], [.move(fromParent: nil, from: 4, toParent: nil, to: 0)])
        expectOps(old, [nil: ["a", "d", "b", "c", "e"]], [.move(fromParent: nil, from: 3, toParent: nil, to: 1)])
    }

    @MainActor @Test func singleMoveWithinFolder() {
        let old: Tree = [nil: ["a", "F"], "F": ["x", "y", "z"]]
        expectOps(old, [nil: ["a", "F"], "F": ["z", "x", "y"]], [.move(fromParent: "F", from: 2, toParent: "F", to: 0)])
        expectOps(old, [nil: ["a", "F"], "F": ["y", "z", "x"]], [.move(fromParent: "F", from: 0, toParent: "F", to: 2)])
    }

    @MainActor @Test func singleMoveAcrossParents() {
        let old: Tree = [nil: ["a", "F", "b"], "F": ["x", "y"], "G": []]
        // Root into folder, at the start, middle and end.
        expectOps(old, [nil: ["a", "F"], "F": ["b", "x", "y"]], [.move(fromParent: nil, from: 2, toParent: "F", to: 0)])
        expectOps(old, [nil: ["F", "b"], "F": ["x", "a", "y"]], [.move(fromParent: nil, from: 0, toParent: "F", to: 1)])
        expectOps(old, [nil: ["a", "F"], "F": ["x", "y", "b"]], [.move(fromParent: nil, from: 2, toParent: "F", to: 2)])
        // Folder out to the root.
        expectOps(old, [nil: ["y", "a", "F", "b"], "F": ["x"]], [.move(fromParent: "F", from: 1, toParent: nil, to: 0)])
        expectOps(old, [nil: ["a", "F", "b", "x"], "F": ["y"]], [.move(fromParent: "F", from: 0, toParent: nil, to: 3)])
        // Last child out: the folder's entry may go away.
        let two: Tree = [nil: ["F", "G"], "F": ["x"]]
        expectOps(two, [nil: ["F", "G"], "G": ["x"]], [.move(fromParent: "F", from: 0, toParent: "G", to: 0)])
        // A folder with children moves into another folder.
        expectOps(two, [nil: ["G"], "G": ["F"], "F": ["x"]], [.move(fromParent: nil, from: 0, toParent: "G", to: 0)])
    }

    // MARK: Reloads

    @Test func swapsAndMultipleMovesReload() {
        let root = ["a", "b", "c", "d", "F", "G"]
        func tree(_ r: [String], _ f: [String] = ["x", "y"], _ g: [String] = ["z"]) -> Tree { [nil: r, "F": f, "G": g] }
        let old = tree(root)
        // Swaps of non-adjacent items, and two adjacent swaps.
        expectReload(old, tree(["d", "b", "c", "a", "F", "G"]))
        expectReload(old, tree(["c", "b", "a", "d", "F", "G"]))
        expectReload(old, tree(["b", "a", "d", "c", "F", "G"]))
        #expect(plan(old, tree(root, ["x", "y"], ["z"])) == .ops([]))
        // Moves in two parents; two cross-parent moves; a move plus an insert or remove.
        expectReload(old, tree(["b", "a", "c", "d", "F", "G"], ["y", "x"]))
        expectReload(old, tree(root, [], ["x", "y", "z"]))
        expectReload(old, tree(root, ["y", "z"], ["x"]))
        expectReload(old, tree(["b", "a", "c", "d", "F", "G"], ["x", "y", "w"]))
        expectReload(old, tree(["b", "a", "c", "d", "F", "G"], ["x"]))
        expectReload(old, tree(root + ["e"], ["y", "x"]))
        expectReload(old, tree(["a", "b", "c", "F", "G"], ["y", "x"]))
        expectReload(old, tree(["a", "b", "c", "F", "G"], ["x", "y"], ["z", "d", "e"]))
        // A cross-parent move next to an unrelated insert.
        expectReload(old, tree(["a", "b", "c", "F", "G"], ["x", "y", "d"], ["z", "w"]))
    }

    @Test func reordersAndHiddenMovesReload() {
        let old: Tree = [nil: ["a", "b", "c", "F"], "F": ["x"]]
        // Kept items out of order, next to an insert or a remove.
        expectReload(old, [nil: ["c", "a", "b", "d", "F"], "F": ["x"]])
        expectReload(old, [nil: ["b", "a", "d", "F"], "F": ["x"]])
        expectReload(old, [nil: ["F", "a", "b"], "F": ["x"]])
        // Moving into a folder that appears in the same update, or out of one that goes.
        expectReload(old, [nil: ["b", "c", "F", "N"], "F": ["x"], "N": ["a"]])
        expectReload(old, [nil: ["b", "c", "F"], "F": ["x", "N"], "N": ["M"], "M": ["a"]])
        expectReload(old, [nil: ["a", "b", "c", "x"]])
        // Deleting a folder hands its children to the parent.
        expectReload([nil: ["a", "F", "b"], "F": ["x", "y"]], [nil: ["a", "x", "y", "b"]])
        // Over the op limit before or after the hashed diff.
        expectReload([nil: ["a", "b"]], [nil: ["b", "a"] + (0..<25).map { "n\($0)" }])
        expectReload([nil: (0..<21).map { "r\($0)" } + ["k"]], [nil: ["k", "n"]])
        // A key listed twice in one list.
        expectReload([nil: ["a", "b"]], [nil: ["a", "a", "c"]])
        expectReload([nil: ["a", "b"]], [nil: ["a", "b", "a"], "a": ["q"]])
    }

    @Test func moreThanTwentyOpsReloads() {
        let base = (0..<5).map { "k\($0)" }
        let twenty = (0..<20).map { "n\($0)" }
        let r20 = plan([nil: base], [nil: base + twenty])
        #expect(r20 == .ops((5..<25).map { .insert(parent: nil, index: $0) }))
        expectReload([nil: base], [nil: base + twenty + ["n20"]])
        // Counted across parents.
        #expect(plan([nil: ["F"]], [nil: ["F"] + twenty.prefix(10), "F": Array(twenty.suffix(10))])
                == .ops((1...10).map { .insert(parent: nil, index: $0) } + (0..<10).map { .insert(parent: "F", index: $0) }))
        expectReload([nil: ["F"]], [nil: ["F"] + twenty.prefix(10), "F": Array(twenty.suffix(10)) + ["n20"]])
        let extra = (0..<11).map { "r\($0)" }, inF = (0..<10).map { "f\($0)" }
        let full: Tree = [nil: ["F"] + extra, "F": inF]
        #expect(plan(full, [nil: ["F"], "F": inF]) == .ops((1...11).reversed().map { .remove(parent: nil, index: $0) }))
        expectReload(full, [nil: ["F"]])
        // 10 root removes + F emptied (10) = exactly 20.
        let mixedParents = plan(full, [nil: ["F"] + extra.prefix(1)])
        #expect(mixedParents == .ops((2...11).reversed().map { .remove(parent: nil, index: $0) }
                + (0..<10).reversed().map { .remove(parent: "F", index: $0) }))
        #expect(plan(full, [nil: extra]) == .ops([.remove(parent: nil, index: 0)]))
        // Removes and inserts share the limit, in one parent or across parents.
        let ten = Array(twenty.prefix(10)), eleven = Array(twenty.prefix(11))
        #expect(plan([nil: inF], [nil: ten]) == .ops((0..<10).reversed().map { .remove(parent: nil, index: $0) }
                + (0..<10).map { .insert(parent: nil, index: $0) }))
        expectReload([nil: inF], [nil: eleven])
        let root: [String] = ["F"] + extra.prefix(6) + twenty[0..<5]
        let inF20: [String] = Array(inF.prefix(5)) + twenty[5..<10], inF21: [String] = inF20 + ["n10"]
        var expected: [Op] = (7...11).reversed().map { .remove(parent: nil, index: $0) }
        expected += (5...9).reversed().map { .remove(parent: "F", index: $0) }
        expected += (7...11).map { .insert(parent: nil, index: $0) }
        expected += (5...9).map { .insert(parent: "F", index: $0) }
        #expect(plan(full, [nil: root, "F": inF20]) == .ops(expected))
        expectReload(full, [nil: root, "F": inF21])
    }

    @MainActor @Test func ambiguousOrCyclicParentsReload() {
        // A changed parent listed under two parents, or reached through a cycle.
        expectReload([nil: ["F", "G"], "F": ["P"], "P": ["x"]], [nil: ["F", "G"], "F": ["P"], "G": ["P"], "P": ["x", "y"]])
        expectReload([nil: ["F"], "F": ["G"]], [nil: ["F"], "F": ["G"], "G": ["F"]])
        // A changed parent listed twice in one list.
        expectReload([nil: ["F"], "F": ["x"]], [nil: ["F", "F"], "F": ["x", "y"]])
        // Detached entries, cyclic or not, are ignored.
        expectOps([nil: ["a"]], [nil: ["a"], "X": ["Y"], "Y": ["X"]], [])
    }

    @MainActor @Test func staleEntriesOnlyMatterWhenTheyListALiveFolder() {
        // The snapshot contract: a stale entry that lists a live session does no harm…
        expectOps([nil: ["F", "s"], "F": ["x"]], [nil: ["F", "s"], "F": ["x", "y"], "gone": ["s"]],
                  [.insert(parent: "F", index: 1)])
        // …but one that lists a live folder makes changes below that folder ambiguous.
        expectReload([nil: ["F"], "F": ["x"]], [nil: ["F"], "F": ["x", "y"], "gone": ["F"]])
        expectReload([nil: ["F"], "F": ["G"], "G": ["x"]], [nil: ["F"], "F": ["G"], "G": [], "gone": ["F"]])
    }

    // MARK: Many changed parents

    @MainActor @Test func manyChangedParentsStillPlan() {
        // A new folder arriving with its subfolders is one insert, however many there are.
        func folder(with count: Int) -> Tree {
            let subfolders = (0..<count).map { "S\($0)" }
            var t: Tree = [nil: ["a", "N"], "N": subfolders]
            for s in subfolders { t[s] = ["c" + s] }
            return t
        }
        expectOps([nil: ["a"]], folder(with: 10), [.insert(parent: nil, index: 1)])
        expectOps([nil: ["a"]], folder(with: 64), [.insert(parent: nil, index: 1)])
        #expect(plan([nil: ["a"]], folder(with: 300)) == .ops([.insert(parent: nil, index: 1)]))
        // One insert in each of 20 folders fits; one in each of 21 does not.
        let names = (0..<25).map { "F\($0)" }
        var old: Tree = [nil: names]
        for f in names { old[f] = ["x" + f] }
        func grown(_ n: Int) -> Tree {
            var t = old
            for f in names.prefix(n) { t[f]?.append("y" + f) }
            return t
        }
        expectOps(old, grown(20), (0..<20).map { .insert(parent: "F\($0)", index: 1) })
        expectReload(old, grown(21))
    }

    // MARK: Sidebar kinds

    @MainActor @Test func worksWithSidebarKinds() {
        let folder = UUID(), s1 = UUID(), s2 = UUID()
        let old: Kinds = [nil: [.folder(folder), .session(s1)], .folder(folder): [.session(s2)]]
        let new: Kinds = [nil: [.folder(folder)], .folder(folder): [.session(s2), .session(s1)]]
        expectPlan(old, new, [.move(fromParent: nil, from: 1, toParent: .folder(folder), to: 1)])
        let header: Kinds = [nil: [.folder(folder), .session(s1), .backgroundHeader],
                             .folder(folder): [.session(s2)], .backgroundHeader: [.background("j1")]]
        expectPlan(old, header, [.insert(parent: nil, index: 2)])
    }

    @MainActor @Test func closingReopeningAndAttachingAnimate() {
        let folder = Kind.folder(UUID()), s1 = UUID(), s2 = UUID(), s3 = UUID()
        let earlier = (0..<40).map { _ in Kind.closed(UUID()) }
        // Closing a session: its row leaves the root, its Closed row arrives on top.
        let open: Kinds = [nil: [folder, .session(s1), .closedHeader], folder: [.session(s2)],
                           .closedHeader: Array(earlier.prefix(3))]
        let closed: Kinds = [nil: [folder, .closedHeader], folder: [.session(s2)],
                             .closedHeader: [.closed(s1)] + earlier.prefix(3)]
        expectPlan(open, closed, [.remove(parent: nil, index: 1), .insert(parent: .closedHeader, index: 0)])
        // Reopening is the reverse.
        expectPlan(closed, open, [.remove(parent: .closedHeader, index: 0), .insert(parent: nil, index: 1)])
        // Closing from a folder.
        expectPlan(open, [nil: [folder, .session(s1), .closedHeader], .closedHeader: [.closed(s2)] + earlier.prefix(3)],
                  [.remove(parent: folder, index: 0), .insert(parent: .closedHeader, index: 0)])
        // At the 40-row limit the oldest Closed row drops off the end as well.
        let full: Kinds = [nil: [folder, .session(s1), .closedHeader], folder: [.session(s2)], .closedHeader: earlier]
        let fullClosed: Kinds = [nil: [folder, .closedHeader], folder: [.session(s2)],
                                 .closedHeader: [.closed(s1)] + earlier.prefix(39)]
        expectPlan(full, fullClosed, [
            .remove(parent: nil, index: 1), .remove(parent: .closedHeader, index: 39), .insert(parent: .closedHeader, index: 0),
        ])
        expectPlan(fullClosed, full, [
            .remove(parent: .closedHeader, index: 0), .insert(parent: nil, index: 1), .insert(parent: .closedHeader, index: 39),
        ])
        // The first close brings the Closed header along.
        expectPlan([nil: [folder, .session(s1)], folder: [.session(s2)]] as Kinds,
                  [nil: [folder, .closedHeader], folder: [.session(s2)], .closedHeader: [.closed(s1)]],
                  [.remove(parent: nil, index: 1), .insert(parent: nil, index: 1)])
        // Attaching a background agent: its row leaves the header, a session row arrives.
        let jobs: Kinds = [nil: [folder, .backgroundHeader], folder: [.session(s2)],
                           .backgroundHeader: [.background("j1"), .background("j2")]]
        expectPlan(jobs, [nil: [folder, .session(s3), .backgroundHeader], folder: [.session(s2)],
                         .backgroundHeader: [.background("j2")]],
                  [.remove(parent: .backgroundHeader, index: 0), .insert(parent: nil, index: 1)])
        // Attaching the last one takes the header with it.
        expectPlan([nil: [folder, .backgroundHeader], folder: [.session(s2)], .backgroundHeader: [.background("j1")]] as Kinds,
                  [nil: [folder, .session(s3)], folder: [.session(s2)]],
                  [.remove(parent: nil, index: 1), .insert(parent: nil, index: 1)])
    }

    // MARK: Randomized

    @Test func randomizedSingleChangesApplyToTheNewTree() async {
        var seen: [DiffCase.Change: Int] = [:]
        var outcomes: [String: Int] = [:]
        func isRemove(_ op: SidebarDiff.Op<Int>) -> Bool { if case .remove = op { true } else { false } }
        func isInsert(_ op: SidebarDiff.Op<Int>) -> Bool { if case .insert = op { true } else { false } }
        for seed in 1...600 {
            let c = DiffCase(seed: UInt64(seed) &* 0x2545_F491_4F6C_DD1D)
            seen[c.change, default: 0] += 1
            let p = SidebarDiff.plan(old: c.old, new: c.new)
            let label = "seed \(seed) \(c.change): \(c.old) -> \(c.new)"
            #expect(SidebarDiff.plan(old: c.old, new: c.new, scanLimit: 0) == p, "index lookup: \(label)")
            #expect(SidebarDiff.plan(old: c.old, new: c.new, scanLimit: .max) == p, "scan lookup: \(label)")
            switch (c.expect, p) {
            case (.reload, .reload):
                outcomes["reload", default: 0] += 1
                continue
            case (.unchanged, .ops(let ops)):
                #expect(ops.isEmpty, "\(label)")
            case (.inserts(let n), .ops(let ops)):
                #expect(ops.count == n && ops.allSatisfy(isInsert), "\(label)")
            case (.removes(let n), .ops(let ops)):
                #expect(ops.count == n && ops.allSatisfy(isRemove), "\(label)")
            case let (.mixed(r, i), .ops(ops)):
                #expect(ops.count == r + i && ops.prefix(r).allSatisfy(isRemove) && ops.suffix(i).allSatisfy(isInsert),
                        "\(label) \(ops)")
            case (.move, .ops(let ops)):
                #expect(ops.count == 1 && { if case .move = ops[0] { true } else { false } }(), "\(label)")
            default:
                Issue.record("expected \(c.expect), got \(p) for \(label)")
                continue
            }
            guard case .ops(let ops) = p else { continue }
            outcomes["ops", default: 0] += 1
            #expect(DiffHarness.inApplyOrder(ops), "\(label)")
            #expect(DiffHarness.apply(ops, old: c.old, new: c.new) == DiffHarness.normalized(c.new), "\(label) \(ops)")
            // Every other seed leaves a random half of the folders collapsed (never loaded).
            let collapsed = seed % 2 == 0 ? [] : c.collapsed
            let rows = await DiffHarness.outlineRows(ops, old: c.old, new: c.new, collapsed: collapsed)
            #expect(rows == DiffHarness.rows(c.new), "\(label) \(ops) collapsed \(collapsed)")
        }
        for change in DiffCase.Change.allCases { #expect(seen[change, default: 0] >= 40, "\(change) under-sampled") }
        #expect(outcomes["ops", default: 0] >= 250 && outcomes["reload", default: 0] >= 150, "\(outcomes)")
    }

    // MARK: Harness

    @Test func harnessRejectsWrongOps() {
        // Guards the checks above: a wrong index must not pass as a correct plan.
        let old: Tree = [nil: ["a", "b", "c"]]
        let new: Tree = [nil: ["b", "c", "a"]]
        #expect(DiffHarness.apply([.move(fromParent: nil, from: 0, toParent: nil, to: 1)], old: old, new: new) == nil)
        #expect(DiffHarness.apply([.remove(parent: nil, index: 3)], old: old, new: new) == nil)
        #expect(DiffHarness.apply([.insert(parent: nil, index: 5)], old: old, new: new) == nil)
        #expect(DiffHarness.apply([.move(fromParent: "F", from: 0, toParent: nil, to: 0)], old: old, new: new) == nil)
        #expect(!DiffHarness.inApplyOrder([Op.remove(parent: nil, index: 0), .remove(parent: nil, index: 1)]))
        #expect(!DiffHarness.inApplyOrder([Op.insert(parent: nil, index: 1), .insert(parent: nil, index: 0)]))
        #expect(!DiffHarness.inApplyOrder([Op.insert(parent: nil, index: 0), .remove(parent: "F", index: 0)]))
    }

    @MainActor @Test func outlineMoveTargetsTheFinalIndex() {
        // Pins NSOutlineView's convention: `to` is the index after the move, not before the removal.
        let old: Tree = [nil: ["a", "b", "c", "d"]]
        let new: Tree = [nil: ["b", "c", "a", "d"]]
        #expect(DiffHarness.outlineRows([Op.move(fromParent: nil, from: 0, toParent: nil, to: 2)], old: old, new: new)
                == DiffHarness.rows(new))
        #expect(DiffHarness.outlineRows([Op.move(fromParent: nil, from: 0, toParent: nil, to: 3)], old: old, new: new)
                != DiffHarness.rows(new))
        // The outline keeps its own child lists: a wrong insert index shows up as the wrong order.
        let grown: Tree = [nil: ["a", "x", "b", "c", "d"]]
        #expect(DiffHarness.outlineRows([Op.insert(parent: nil, index: 1)], old: old, new: grown) == DiffHarness.rows(grown))
        #expect(DiffHarness.outlineRows([Op.remove(parent: nil, index: 3)], old: old, new: [nil: ["a", "b", "c"]])
                == DiffHarness.rows([nil: ["a", "b", "c"]] as Tree))
        #expect(DiffHarness.outlineRows([Op.remove(parent: nil, index: 0)], old: old, new: [nil: ["a", "b", "c"]])
                != DiffHarness.rows([nil: ["a", "b", "c"]] as Tree))
    }

    @MainActor @Test func outlineHandlesCollapsedAndNeverLoadedParents() {
        // F was never expanded, G was expanded and collapsed again, H is expanded.
        let old: Tree = [nil: ["a", "F", "G", "H"], "F": ["f1", "f2"], "G": ["g1"], "H": ["h1"]]
        func rows(_ ops: [Op], _ new: Tree) -> [String] {
            DiffHarness.outlineRows(ops, old: old, new: new, collapsed: ["F"], collapseAfterLoad: ["G"])
        }
        func check(_ new: Tree, _ ops: [Op], sourceLocation: SourceLocation = #_sourceLocation) {
            #expect(plan(old, new) == .ops(ops), sourceLocation: sourceLocation)
            #expect(rows(ops, new) == DiffHarness.rows(new), sourceLocation: sourceLocation)
        }
        check([nil: ["F", "G", "H"], "F": ["f1", "a", "f2"], "G": ["g1"], "H": ["h1"]],
              [.move(fromParent: nil, from: 0, toParent: "F", to: 1)])
        check([nil: ["a", "g1", "F", "G", "H"], "F": ["f1", "f2"], "H": ["h1"]],
              [.move(fromParent: "G", from: 0, toParent: nil, to: 1)])
        check([nil: ["a", "F", "G", "H"], "F": ["f2", "f3"], "G": ["g0", "g1"], "H": []], [
            .remove(parent: "F", index: 0), .remove(parent: "H", index: 0),
            .insert(parent: "F", index: 1), .insert(parent: "G", index: 0),
        ])
        check([nil: ["F", "G", "H"], "F": ["f1", "f2"], "G": ["g1", "a"], "H": ["h1"]],
              [.move(fromParent: nil, from: 0, toParent: "G", to: 1)])
        // F really is never loaded: it ignores ops and reads the data source when it expands, so
        // only the expanded runs (every other randomized seed, every expectOps) check its indexes.
        let grown: Tree = [nil: ["a", "F", "G", "H"], "F": ["f1", "f2", "f3"], "G": ["g1"], "H": ["h1"]]
        #expect(rows([.insert(parent: "F", index: 0)], grown) == DiffHarness.rows(grown))
        #expect(DiffHarness.outlineRows([Op.insert(parent: "F", index: 0)], old: old, new: grown) != DiffHarness.rows(grown))
    }

    // MARK: Cost

    /// Prints the plan cost on a sidebar-sized tree; budgets only enforce with CORRAL_PERF=1
    /// (release, serial), like PerformanceTests.
    @Test func planCostStaysFlat() {
        let enforce = ProcessInfo.processInfo.environment["CORRAL_PERF"] != nil
        // 60 folders of 9 sessions, 12 root sessions and 40 closed rows: 613 keys.
        let folders = (0..<60).map { _ in Kind.folder(UUID()) }
        var base: Kinds = [nil: folders + (0..<12).map { _ in .session(UUID()) } + [.closedHeader]]
        for f in folders { base[f] = (0..<9).map { _ in .session(UUID()) } }
        base[.closedHeader] = (0..<40).map { _ in .closed(UUID()) }
        /// Fresh buffers, so `==` compares elements instead of matching identical storage.
        func copy(_ t: Kinds) -> Kinds { t.mapValues { $0.map { $0 } } }

        var scenarios: [(name: String, new: Kinds, ops: Bool)] = [("unchanged", copy(base), true)]
        var t = copy(base)
        t[nil]?.insert(.session(UUID()), at: 0)
        scenarios.append(("insert", t, true))
        t = copy(base)
        t[folders[3]]?.remove(at: 4)
        t[.closedHeader] = [.closed(UUID())] + t[.closedHeader]!.dropLast()
        scenarios.append(("close", t, true))
        t = copy(base)
        for f in folders.prefix(20) { t[f]?.append(.session(UUID())) }
        scenarios.append(("20 folders insert", t, true))
        t = copy(base)
        for f in folders { t[f]?.reverse() }
        scenarios.append(("60 folders reorder", t, false))

        for (name, new, wantsOps) in scenarios {
            var times: [Double] = []
            var result = SidebarDiff.Plan<Kind>.reload
            for _ in 0..<(enforce ? 300 : 10) {
                let old = copy(base), fresh = copy(new)
                let t0 = DispatchTime.now().uptimeNanoseconds
                result = SidebarDiff.plan(old: old, new: fresh)
                times.append(Double(DispatchTime.now().uptimeNanoseconds - t0) / 1_000_000)
            }
            #expect((result != .reload) == wantsOps, "\(name): \(result)")
            let p95 = times.sorted()[Int(Double(times.count - 1) * 0.95)]
            print("PERF sidebarDiff \(name): \(String(format: "%.3f", p95)) ms (budget 1.5)")
            if enforce { #expect(p95 < 1.5, "sidebarDiff \(name) over budget") }
        }
    }
}

// MARK: - Helpers (nested so they cannot clash with other test files)

extension SidebarDiffTests {
    /// Applies a plan the way the sidebar does, both to plain lists and to a real NSOutlineView.
    enum DiffHarness {
        /// Parents reachable from the root, with their non-empty child lists.
        static func normalized<K: Hashable>(_ tree: [K?: [K]]) -> [K?: [K]] {
            var out: [K?: [K]] = [:]
            var stack: [K?] = [nil]
            while let p = stack.popLast() {
                guard let children = tree[p], !children.isEmpty, out[p] == nil else { continue }
                out[p] = children
                stack += children.map { Optional($0) }
            }
            return out
        }

        /// Keys of the fully expanded tree in pre-order, with their outline level.
        static func preorder<K: Hashable>(_ tree: [K?: [K]]) -> [(key: K, level: Int)] {
            var out: [(key: K, level: Int)] = []
            func visit(_ p: K?, _ level: Int) {
                for k in tree[p] ?? [] {
                    out.append((k, level))
                    visit(k, level + 1)
                }
            }
            visit(nil, 0)
            return out
        }

        /// Pre-order "level:key" rows of the fully expanded tree.
        static func rows<K: Hashable>(_ tree: [K?: [K]]) -> [String] { preorder(tree).map { "\($0.level):\($0.key)" } }

        /// Plays `ops` against the old lists: removes by old index, inserts take `new[parent][index]`,
        /// a move lands at `to` in the destination. An inserted item brings its subtree from `new`,
        /// as the outline loads it from the data source. nil when an index is out of range.
        static func apply<K: Hashable>(_ ops: [SidebarDiff.Op<K>], old: [K?: [K]], new: [K?: [K]]) -> [K?: [K]]? {
            var t = normalized(old)
            func graft(_ k: K) {
                t[k] = new[k]
                for c in new[k] ?? [] { graft(c) }
            }
            for op in ops {
                switch op {
                case let .remove(p, i):
                    guard var list = t[p], list.indices.contains(i) else { return nil }
                    list.remove(at: i)
                    t[p] = list
                case let .insert(p, i):
                    var list = t[p] ?? []
                    guard let source = new[p], source.indices.contains(i), i <= list.count else { return nil }
                    list.insert(source[i], at: i)
                    t[p] = list
                    graft(source[i])
                case let .move(fp, from, tp, to):
                    guard var src = t[fp], src.indices.contains(from) else { return nil }
                    let k = src.remove(at: from)
                    t[fp] = src
                    var dst = t[tp] ?? []
                    guard to <= dst.count, let target = new[tp], target.indices.contains(to), target[to] == k else {
                        return nil
                    }
                    dst.insert(k, at: to)
                    t[tp] = dst
                }
            }
            return normalized(t)
        }

        /// Every remove before every insert; removes strictly descending and inserts strictly
        /// ascending within each parent.
        static func inApplyOrder<K: Hashable>(_ ops: [SidebarDiff.Op<K>]) -> Bool {
            var lastRemove: [K?: Int] = [:], lastInsert: [K?: Int] = [:]
            for op in ops {
                switch op {
                case let .remove(p, i):
                    if !lastInsert.isEmpty { return false }
                    if let last = lastRemove[p], last <= i { return false }
                    lastRemove[p] = i
                case let .insert(p, i):
                    if let last = lastInsert[p], last >= i { return false }
                    lastInsert[p] = i
                case .move: break
                }
            }
            return true
        }

        /// Runs `ops` through a real NSOutlineView and returns the rows it ends up with once
        /// everything is expanded. The old tree is shown with every folder expanded except
        /// `collapsed` (never loaded) and `collapseAfterLoad` (expanded once, then collapsed);
        /// the data source switches to `new` before the ops, as the sidebar does.
        @MainActor
        static func outlineRows<K: Hashable>(_ ops: [SidebarDiff.Op<K>], old: [K?: [K]], new: [K?: [K]],
                                             collapsed: Set<K> = [], collapseAfterLoad: Set<K> = []) -> [String] {
            func erase(_ t: [K?: [K]]) -> [AnyHashable?: [AnyHashable]] {
                var out: [AnyHashable?: [AnyHashable]] = [:]
                for (p, c) in t { out[p.map { AnyHashable($0) }] = c.map { AnyHashable($0) } }
                return out
            }
            let probe = OutlineProbe(old: erase(old), new: erase(new), collapsed: Set(collapsed.map { AnyHashable($0) }),
                                     collapseAfterLoad: Set(collapseAfterLoad.map { AnyHashable($0) }))
            let o = probe.outline
            o.beginUpdates()
            for op in ops {
                switch op {
                case let .remove(p, i):
                    o.removeItems(at: [i], inParent: probe.item(p.map { AnyHashable($0) }), withAnimation: [])
                case let .insert(p, i):
                    o.insertItems(at: [i], inParent: probe.item(p.map { AnyHashable($0) }), withAnimation: [])
                case let .move(fp, from, tp, to):
                    o.moveItem(at: from, inParent: probe.item(fp.map { AnyHashable($0) }),
                               to: to, inParent: probe.item(tp.map { AnyHashable($0) }))
                }
            }
            o.endUpdates()
            probe.expandAll()
            return probe.rows()
        }
    }

    /// Minimal view-based outline over a key tree with stable item identity. The delegate makes
    /// it fetch rows eagerly, like the real sidebar.
    @MainActor
    final class OutlineProbe: NSObject, NSOutlineViewDataSource, NSOutlineViewDelegate {
        final class Item: NSObject {
            let key: AnyHashable
            init(_ key: AnyHashable) { self.key = key }
        }

        let outline = NSOutlineView(frame: NSRect(x: 0, y: 0, width: 200, height: 2000))
        private var tree: [AnyHashable?: [AnyHashable]]
        private let expandable: Set<AnyHashable>
        private var items: [AnyHashable: Item] = [:]

        init(old: [AnyHashable?: [AnyHashable]], new: [AnyHashable?: [AnyHashable]],
             collapsed: Set<AnyHashable> = [], collapseAfterLoad: Set<AnyHashable> = []) {
            tree = old
            expandable = Set(old.keys.compactMap { $0 } + new.keys.compactMap { $0 })
            super.init()
            let column = NSTableColumn(identifier: .init("main"))
            outline.addTableColumn(column)
            outline.outlineTableColumn = column
            outline.dataSource = self
            outline.delegate = self
            outline.reloadData()
            expandAll(except: collapsed)
            for key in collapseAfterLoad { outline.collapseItem(item(key)) }
            tree = new
        }

        func item(_ key: AnyHashable?) -> Item? {
            guard let key else { return nil }
            if let i = items[key] { return i }
            let i = Item(key)
            items[key] = i
            return i
        }

        func expandAll(except collapsed: Set<AnyHashable> = []) {
            var row = 0
            while row < outline.numberOfRows {
                if let it = outline.item(atRow: row) as? Item, outline.isExpandable(it), !outline.isItemExpanded(it),
                   !collapsed.contains(it.key) {
                    outline.expandItem(it)
                }
                row += 1
            }
        }

        func rows() -> [String] {
            (0..<outline.numberOfRows).map { r in
                "\(outline.level(forRow: r)):\((outline.item(atRow: r) as! Item).key.base)"
            }
        }

        private func children(_ item: Any?) -> [AnyHashable] { tree[(item as? Item)?.key] ?? [] }

        func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int { children(item).count }

        func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
            self.item(children(item)[index])!
        }

        func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool {
            (item as? Item).map { expandable.contains($0.key) } ?? false
        }

        func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
            NSTextField(labelWithString: "\((item as? Item)?.key.base ?? "")")
        }
    }

    /// Deterministic RNG for the randomized cases.
    struct SplitMix64: RandomNumberGenerator {
        var state: UInt64
        mutating func next() -> UInt64 {
            state &+= 0x9E37_79B9_7F4A_7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
            z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
            return z ^ (z >> 31)
        }
    }

    /// One random sidebar-shaped tree and a single random change to it.
    struct DiffCase {
        enum Expect: Equatable {
            case unchanged, inserts(Int), removes(Int), mixed(removes: Int, inserts: Int), move, reload
        }

        enum Change: CaseIterable { case inserts, removes, mixed, move, moveAndInsert, hiddenMove, swap, noop }

        var old: [Int?: [Int]] = [:]
        var new: [Int?: [Int]] = [:]
        var expect = Expect.unchanged
        var change = Change.noop
        /// About half of the folders, for an outline that leaves them collapsed.
        var collapsed: Set<Int> = []

        private var rng: SplitMix64
        private var nextKey = 1
        private var folders: [Int] = []
        private var keys: [Int] = []
        private var parentOf: [Int: Int?] = [:]

        init(seed: UInt64) {
            rng = SplitMix64(state: seed)
            fill(nil, depth: 0)
            new = old
            keys = DiffHarness.preorder(old).map(\.key)
            for (p, c) in old { for k in c { parentOf[k] = p } }
            change = Change.allCases.randomElement(using: &rng)!
            switch change {
            case .inserts: inserts()
            case .removes: removes()
            case .mixed: mixed()
            case .move: move()
            case .moveAndInsert: moveAndInsert()
            case .hiddenMove: hiddenMove()
            case .swap: swap()
            case .noop: noop()
            }
            for f in folders where chance(0.5) { collapsed.insert(f) }
        }

        private mutating func int(_ r: ClosedRange<Int>) -> Int { Int.random(in: r, using: &rng) }
        private mutating func chance(_ p: Double) -> Bool { Double.random(in: 0..<1, using: &rng) < p }
        private mutating func fresh() -> Int {
            defer { nextKey += 1 }
            return nextKey
        }

        /// Root items, folders nested up to two levels; empty folders sometimes have no entry.
        private mutating func fill(_ parent: Int?, depth: Int) {
            var list: [Int] = []
            for _ in 0..<int(0...(depth == 0 ? 8 : 4)) {
                let k = fresh()
                list.append(k)
                if depth < 2 && chance(depth == 0 ? 0.35 : 0.2) {
                    folders.append(k)
                    fill(k, depth: depth + 1)
                }
            }
            if !list.isEmpty || chance(0.5) { old[parent] = list }
        }

        /// `k` is `ancestor` or below it (nil = root is inside nothing).
        private func isInside(_ k: Int?, _ ancestor: Int) -> Bool {
            var p = k
            while let c = p {
                if c == ancestor { return true }
                p = parentOf[c] ?? nil
            }
            return false
        }

        private mutating func pick(_ targets: [Int?]) -> Int? { targets.randomElement(using: &rng)! }

        /// The root and every folder not inside one of `avoiding`.
        private func targets(avoiding: [Int]) -> [Int?] {
            ([nil] + folders.map { Optional($0) }).filter { t in !avoiding.contains { isInside(t, $0) } }
        }

        private mutating func insert(_ k: Int, into p: Int?) {
            var list = new[p] ?? []
            list.insert(k, at: int(0...list.count))
            new[p] = list
        }

        private mutating func take(_ k: Int) {
            let p = parentOf[k] ?? nil
            new[p]?.removeAll { $0 == k }
            if new[p]?.isEmpty == true && chance(0.5) { new[p] = nil }
        }

        /// Inserts `count` fresh keys (some with children) into parents that stay.
        private mutating func insertFresh(_ count: Int, avoiding removed: [Int] = []) {
            let targets = targets(avoiding: removed)
            for _ in 0..<count {
                let k = fresh(), target = pick(targets)
                insert(k, into: target)
                if chance(0.2) {
                    var children: [Int] = []
                    for _ in 0..<int(0...3) { children.append(fresh()) }
                    new[k] = children
                }
            }
        }

        /// Removes `count` random keys; returns them with the number of rows the outline removes
        /// (keys inside another removed folder go with it).
        private mutating func removeRandom(_ count: Int) -> (chosen: [Int], visible: Int) {
            let chosen = Array(keys.shuffled(using: &rng).prefix(count))
            for k in chosen {
                take(k)
                if folders.contains(k) && chance(0.5) { new[k] = nil }
            }
            let visible = chosen.filter { k in !chosen.contains { $0 != k && isInside(parentOf[k] ?? nil, $0) } }
            return (chosen, visible.count)
        }

        private mutating func inserts() {
            let count = chance(0.25) ? int(15...25) : int(1...6)
            insertFresh(count)
            expect = count <= SidebarDiff.maxOps ? .inserts(count) : .reload
        }

        private mutating func removes() {
            guard !keys.isEmpty else { return noop() }
            let (_, visible) = removeRandom(chance(0.25) ? int(15...25) : int(1...4))
            expect = visible <= SidebarDiff.maxOps ? .removes(visible) : .reload
        }

        /// Removes some keys and inserts fresh ones, in the same or other parents.
        private mutating func mixed() {
            guard !keys.isEmpty else { return noop() }
            let big = chance(0.25)
            let (chosen, visible) = removeRandom(big ? int(8...14) : int(1...3))
            let count = big ? int(6...12) : int(1...3)
            insertFresh(count, avoiding: chosen)
            expect = visible + count <= SidebarDiff.maxOps ? .mixed(removes: visible, inserts: count) : .reload
        }

        /// Moves one key; true when it ended up somewhere else.
        private mutating func moveOne() -> Bool {
            let k = keys.randomElement(using: &rng)!
            let target = pick(targets(avoiding: [k]))
            take(k)
            insert(k, into: target)
            return DiffHarness.normalized(new) != DiffHarness.normalized(old)
        }

        private mutating func move() {
            guard !keys.isEmpty else { return noop() }
            expect = moveOne() ? .move : .unchanged
        }

        private mutating func moveAndInsert() {
            guard !keys.isEmpty else { return noop() }
            let moved = moveOne()
            insertFresh(1)
            expect = moved ? .reload : .inserts(1)
        }

        /// A key moves into a folder that appears, or a folder goes and hands its children up.
        private mutating func hiddenMove() {
            guard let k = keys.randomElement(using: &rng) else { return noop() }
            let full = folders.filter { !(old[$0] ?? []).isEmpty }
            if chance(0.5), let f = full.randomElement(using: &rng) {
                let p = parentOf[f] ?? nil
                var list = new[p] ?? []
                let i = list.firstIndex(of: f)!
                list.replaceSubrange(i...i, with: old[f]!)
                new[p] = list
                if chance(0.5) { new[f] = nil }
            } else {
                let target = pick(targets(avoiding: [k])), folder = fresh()
                take(k)
                insert(folder, into: target)
                new[folder] = chance(0.5) ? [k] : [fresh(), k]
            }
            expect = .reload
        }

        private mutating func swap() {
            let parents = old.filter { $0.value.count >= 3 }.keys.sorted { ($0 ?? 0) < ($1 ?? 0) }
            guard let p = parents.randomElement(using: &rng), var list = new[p] else { return noop() }
            let i = int(0...(list.count - 3))
            list.swapAt(i, int((i + 2)...(list.count - 1)))
            new[p] = list
            expect = .reload
        }

        /// Representation-only noise: empty entries for leaves, dropped empty entries, stale entries.
        private mutating func noop() {
            change = .noop
            for k in keys where !folders.contains(k) && chance(0.2) { new[k] = [] }
            for p in new.keys.sorted(by: { ($0 ?? 0) < ($1 ?? 0) }) where new[p]?.isEmpty == true && chance(0.5) {
                new[p] = nil
            }
            if chance(0.5) {
                let stale = fresh(), child = fresh()
                new[stale] = [child]
            }
            expect = .unchanged
        }
    }
}
