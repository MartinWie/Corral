import Foundation

/// Plans animated outline updates from the old and new child lists (spec §4.4).
///
/// Returns ops for removes and inserts of distinct keys (any parents, the items a parent keeps
/// stay in order) or for a single move. Everything else reloads: reorders, a move together with
/// any other change, a key that leaves one place and shows up in another (also inside a folder
/// that appears or goes), and more than `maxOps` ops.
///
/// Only parents reachable from the root in both trees are diffed. A folder that appears or
/// disappears is one insert or remove in its own parent; its children ride along. A missing entry
/// means no children, so an existing folder that gains its first child may have no entry in `old`.
///
/// Snapshot contract: list only parents reachable from the roots (walk `roots` recursively, every
/// folder and header, expanded or not). Do not iterate the `nodes` cache: it keeps deleted folders
/// with their last children, and a detached entry that lists a live folder or header makes that
/// one ambiguous, so any change at or below it plans `.reload`. Stale entries that list only
/// detached keys or sessions are ignored.
enum SidebarDiff {
    enum Op<Key: Hashable>: Equatable {
        /// Index in the OLD child list of `parent` (apply removes in descending order).
        case remove(parent: Key?, index: Int)
        /// Index in the NEW child list of `parent` (apply inserts in ascending order).
        case insert(parent: Key?, index: Int)
        case move(fromParent: Key?, from: Int, toParent: Key?, to: Int)
    }

    enum Plan<Key: Hashable>: Equatable {
        case reload
        case ops([Op<Key>])
    }

    /// Above this many ops a reload is cheaper and reads better than a wall of moving rows.
    static let maxOps = 20
    /// Up to this many changed parents are found by scanning the lists (no hashing per key); past
    /// it one reverse index per tree is cheaper than a scan per parent.
    static let scanLimit = 3

    /// `old`/`new`: children per parent (nil = root); keys form a tree.
    ///
    /// Ops come in apply order: every remove, then every insert (or the lone move). Parents follow
    /// the pre-order of the new tree; removes descend and inserts ascend within a parent. A move's
    /// `to` is the item's index in the new list.
    ///
    /// Cost: one `==` pass over the lists. Up to `scanLimit` changed parents are found by scanning
    /// (O(depth × n) each, no hashing); more build one reverse index per tree (one hash per listed
    /// key) and then cost O(depth) each. A list that both loses and gains items, and a plan that
    /// mixes removes with inserts, also hash the keys involved.
    static func plan<Key: Hashable>(old: [Key?: [Key]], new: [Key?: [Key]]) -> Plan<Key> {
        plan(old: old, new: new, scanLimit: scanLimit)
    }

    /// The sidebar's key type, specialized here: generic calls from another module (tests) run
    /// unspecialized and several times slower.
    static func plan(old: [SidebarNode.Kind?: [SidebarNode.Kind]],
                     new: [SidebarNode.Kind?: [SidebarNode.Kind]]) -> Plan<SidebarNode.Kind> {
        plan(old: old, new: new, scanLimit: scanLimit)
    }

    /// `plan(old:new:)` with the lookup switch exposed so tests can pin both lookups to one result.
    static func plan<Key: Hashable>(old: [Key?: [Key]], new: [Key?: [Key]], scanLimit: Int) -> Plan<Key> {
        var changed: [Key?] = []
        for (parent, children) in new where children != (old[parent] ?? []) { changed.append(parent) }
        for (parent, children) in old where !children.isEmpty && new[parent] == nil { changed.append(parent) }
        if changed.isEmpty { return .ops([]) }
        // A walk up only passes parents, so the index only needs keys that have an entry somewhere.
        var parents: Set<Key>?
        if changed.count > scanLimit {
            var keys = Set<Key>(minimumCapacity: old.count + new.count)
            for case let p? in old.keys { keys.insert(p) }
            for case let p? in new.keys { keys.insert(p) }
            parents = keys
        }
        let newTree = Locator(new, indexing: parents), oldTree = Locator(old, indexing: parents)
        var common: [(path: [Int], parent: Key?)] = []
        for parent in changed {
            guard let key = parent else {
                common.append(([], nil))
                continue
            }
            switch (newTree.locate(key), oldTree.locate(key)) {
            case (.ambiguous, _), (_, .ambiguous): return .reload
            case let (.path(path), .path): common.append((path, key))
            default: continue  // it comes or goes with its own insert or remove
            }
        }
        common.sort { $0.path.lexicographicallyPrecedes($1.path) }
        var acc = Accumulator<Key>()
        for (_, parent) in common {
            guard acc.add(parent, old[parent] ?? [], new[parent] ?? []) else { return .reload }
        }
        return acc.plan(old: old, new: new)
    }

    private enum Location {
        /// Child indexes from the root down to the key.
        case path([Int])
        /// Not reachable from the root (absent, under a detached entry, or in a cycle).
        case detached
        /// Listed twice (under two parents, or twice in one list).
        case ambiguous
    }

    /// Finds keys in one tree, by scanning every list or through a reverse index built in one pass.
    /// Both report a key listed twice as ambiguous, even when one of the lists is detached.
    private struct Locator<Key: Hashable> {
        private enum Slot {
            case at(parent: Key?, index: Int)
            case duplicate
        }

        private let tree: [Key?: [Key]]
        private let index: [Key: Slot]?

        /// `parents`: the keys to index (nil scans instead); every key a lookup can reach.
        init(_ tree: [Key?: [Key]], indexing parents: Set<Key>?) {
            self.tree = tree
            guard let parents else {
                index = nil
                return
            }
            var index = [Key: Slot](minimumCapacity: parents.count)
            for (parent, children) in tree {
                for (i, child) in children.enumerated() where parents.contains(child)
                    && index.updateValue(.at(parent: parent, index: i), forKey: child) != nil {
                    index[child] = .duplicate
                }
            }
            self.index = index
        }

        func locate(_ key: Key) -> Location {
            var path: [Int] = []
            var current = key
            // Every parent on the way up has an entry: a longer chain is a cycle.
            for _ in 0...tree.count {
                switch slot(current) {
                case nil: return .detached
                case .duplicate: return .ambiguous
                case let .at(parent, i):
                    path.append(i)
                    guard let parent else { return .path(path.reversed()) }
                    current = parent
                }
            }
            return .detached
        }

        private func slot(_ key: Key) -> Slot? {
            if let index { return index[key] }
            var found: Slot?
            for (parent, children) in tree {
                guard let i = children.firstIndex(of: key) else { continue }
                if found != nil || children[(i + 1)...].contains(key) { return .duplicate }
                found = .at(parent: parent, index: i)
            }
            return found
        }
    }

    /// Indexes in `long` of the items missing from `short`, when `short` is `long` with only
    /// those items taken out (order kept); nil otherwise.
    private static func extras<Key: Equatable>(_ short: [Key], in long: [Key]) -> [Int]? {
        let missing = long.count - short.count
        var out: [Int] = []
        out.reserveCapacity(missing)
        var i = 0
        for (j, key) in long.enumerated() {
            if i < short.count && short[i] == key {
                i += 1
            } else {
                out.append(j)
                if out.count > missing { return nil }
            }
        }
        return i == short.count ? out : nil
    }

    /// `(from, to)` when `new` is `old` with exactly one item relocated. Two adjacent items
    /// trading places are reported as the earlier one moving down.
    private static func singleMove<Key: Equatable>(_ old: [Key], _ new: [Key]) -> (from: Int, to: Int)? {
        var lo = 0
        while lo < old.count && old[lo] == new[lo] { lo += 1 }
        var hi = old.count - 1
        while hi > lo && old[hi] == new[hi] { hi -= 1 }
        guard lo < hi else { return nil }
        if old[lo] == new[hi] && old[(lo + 1)...hi].elementsEqual(new[lo..<hi]) { return (lo, hi) }
        if old[hi] == new[lo] && old[lo..<hi].elementsEqual(new[(lo + 1)...hi]) { return (hi, lo) }
        return nil
    }

    /// Old indexes of the items `new` drops and new indexes of the items it adds (both ascending),
    /// when the items both lists share keep their order and there are at most `budget` of them;
    /// nil otherwise. Pure inserts and pure removes are found without hashing.
    private static func edit<Key: Hashable>(_ old: [Key], _ new: [Key], budget: Int) -> (removed: [Int], inserted: [Int])? {
        if new.count > old.count, let added = extras(old, in: new) { return added.count <= budget ? ([], added) : nil }
        if new.count < old.count, let dropped = extras(new, in: old) { return dropped.count <= budget ? (dropped, []) : nil }
        guard abs(new.count - old.count) <= budget else { return nil }
        let inOld = Set(old), inNew = Set(new)
        var removed: [Int] = [], inserted: [Int] = []
        var j = 0
        for (i, key) in old.enumerated() {
            guard inNew.contains(key) else {
                removed.append(i)
                continue
            }
            while j < new.count && !inOld.contains(new[j]) {
                inserted.append(j)
                j += 1
            }
            // A kept item out of order (or listed twice) is a reorder.
            guard j < new.count, new[j] == key, removed.count + inserted.count <= budget else { return nil }
            j += 1
        }
        while j < new.count {
            guard !inOld.contains(new[j]) else { return nil }
            inserted.append(j)
            j += 1
        }
        return removed.count + inserted.count <= budget ? (removed, inserted) : nil
    }

    /// Whether a key leaves in a removed subtree and comes back in an inserted one: a move hidden
    /// among other changes (into a folder that appears, out of one that goes, or next to an insert).
    private static func overlap<Key: Hashable>(removed: [Key], in old: [Key?: [Key]],
                                               inserted: [Key], in new: [Key?: [Key]]) -> Bool {
        var gone = Set<Key>()
        var stack = removed
        while let k = stack.popLast() {
            if gone.insert(k).inserted { stack += old[k] ?? [] }
        }
        var seen = Set<Key>()
        stack = inserted
        while let k = stack.popLast() {
            if gone.contains(k) { return true }
            if seen.insert(k).inserted { stack += new[k] ?? [] }
        }
        return false
    }

    /// Collects per-parent changes and gives up as soon as they cannot form one allowed plan.
    private struct Accumulator<Key: Hashable> {
        private var removes: [Op<Key>] = []
        private var inserts: [Op<Key>] = []
        /// The keys behind `removes` / `inserts`, in the same order.
        private var removed: [Key] = []
        private var inserted: [Key] = []
        private var move: Op<Key>?

        /// `old != new` (only changed parents get here).
        mutating func add(_ parent: Key?, _ old: [Key], _ new: [Key]) -> Bool {
            if move != nil { return false }
            if old.count == new.count, let m = SidebarDiff.singleMove(old, new) {
                guard removes.isEmpty, inserts.isEmpty else { return false }
                move = .move(fromParent: parent, from: m.from, toParent: parent, to: m.to)
                return true
            }
            let budget = SidebarDiff.maxOps - removes.count - inserts.count
            guard let e = SidebarDiff.edit(old, new, budget: budget) else { return false }
            for i in e.removed.reversed() {
                removes.append(.remove(parent: parent, index: i))
                removed.append(old[i])
            }
            for i in e.inserted {
                inserts.append(.insert(parent: parent, index: i))
                inserted.append(new[i])
            }
            return true
        }

        func plan(old: [Key?: [Key]], new: [Key?: [Key]]) -> Plan<Key> {
            if let move { return .ops([move]) }
            if removed.isEmpty || inserted.isEmpty { return .ops(removes + inserts) }
            // One item leaving one parent and entering another is a move.
            if removed.count == 1, inserted.count == 1, removed[0] == inserted[0],
               case let .remove(from, fromIndex) = removes[0], case let .insert(to, toIndex) = inserts[0] {
                return .ops([.move(fromParent: from, from: fromIndex, toParent: to, to: toIndex)])
            }
            if SidebarDiff.overlap(removed: removed, in: old, inserted: inserted, in: new) { return .reload }
            return .ops(removes + inserts)
        }
    }
}
