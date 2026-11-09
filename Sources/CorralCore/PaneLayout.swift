import Foundation

/// Where a new split goes, relative to the pane it splits (⌘D right, ⇧⌘D down).
public enum SplitDirection: Equatable, Sendable {
    case right, down, left, up
}

/// Moving keyboard focus across a card: along the reading order (⌘] / ⌘[) or to a side (⌥⌘ arrows).
public enum SplitFocus: Equatable, Sendable {
    case previous, next
    case toward(SplitDirection)
}

/// A leaf's place in the unit square (x to the right, y down), every split halved.
public struct PaneBox: Equatable, Sendable {
    public var x, y, width, height: Double
    public init(x: Double, y: Double, width: Double, height: Double) {
        (self.x, self.y, self.width, self.height) = (x, y, width, height)
    }
    public var maxX: Double { x + width }
    public var maxY: Double { y + height }
}

/// How a session's card is divided: a binary tree whose leaves are terminal ids (the session's own
/// id for its main terminal, other sessions shown side by side, pane ids for split shells).
/// Panes are throwaway shells next to an agent and are not persisted; side-by-side sessions are.
public indirect enum PaneLayout: Codable, Equatable, Sendable {
    case leaf(UUID)
    /// `sideBySide`: the two halves are left and right (a vertical divider), else top and bottom.
    case split(sideBySide: Bool, first: PaneLayout, second: PaneLayout)

    /// Leaves in reading order (left to right, top to bottom).
    public var leaves: [UUID] {
        switch self {
        case .leaf(let id): return [id]
        case .split(_, let a, let b): return a.leaves + b.leaves
        }
    }

    public func contains(_ id: UUID) -> Bool { leaves.contains(id) }

    /// Replaces the leaf `target` with a split holding it and `new` on the `direction` side.
    public func splitting(_ target: UUID, with new: UUID, direction: SplitDirection) -> PaneLayout {
        inserting(.leaf(new), at: target, direction: direction)
    }

    /// Replaces the leaf `target` with a split holding it and a whole `layout` on the `direction` side.
    public func inserting(_ layout: PaneLayout, at target: UUID, direction: SplitDirection) -> PaneLayout {
        switch self {
        case .leaf(let id) where id == target:
            return adding(layout, direction: direction)
        case .leaf:
            return self
        case .split(let side, let a, let b):
            return .split(sideBySide: side, first: a.inserting(layout, at: target, direction: direction),
                          second: b.inserting(layout, at: target, direction: direction))
        }
    }

    /// This layout and `layout` side by side (or stacked), `layout` on the `direction` side.
    public func adding(_ layout: PaneLayout, direction: SplitDirection) -> PaneLayout {
        let sideBySide = direction == .right || direction == .left
        let newFirst = direction == .left || direction == .up
        return .split(sideBySide: sideBySide, first: newFirst ? layout : self, second: newFirst ? self : layout)
    }

    /// The layout with only the leaves `keep` accepts; siblings take the freed space. Nil when none is left.
    public func filtered(_ keep: (UUID) -> Bool) -> PaneLayout? {
        switch self {
        case .leaf(let id):
            return keep(id) ? self : nil
        case .split(let side, let a, let b):
            switch (a.filtered(keep), b.filtered(keep)) {
            case (nil, nil): return nil
            case (let x?, nil): return x
            case (nil, let y?): return y
            case (let x?, let y?): return .split(sideBySide: side, first: x, second: y)
            }
        }
    }

    /// More than one terminal (a single leaf is no split).
    public var isSplit: Bool {
        if case .split = self { return true }
        return false
    }

    /// The layout without `target`: its sibling takes the freed space. Nil when nothing is left.
    public func removing(_ target: UUID) -> PaneLayout? {
        switch self {
        case .leaf(let id):
            return id == target ? nil : self
        case .split(let side, let a, let b):
            switch (a.removing(target), b.removing(target)) {
            case (nil, nil): return nil
            case (let x?, nil): return x
            case (nil, let y?): return y
            case (let x?, let y?): return .split(sideBySide: side, first: x, second: y)
            }
        }
    }

    /// Every leaf's box in the unit square (split views start at half and half; dragging a divider
    /// moves edges, not who is next to whom).
    public func boxes(in box: PaneBox = PaneBox(x: 0, y: 0, width: 1, height: 1)) -> [UUID: PaneBox] {
        switch self {
        case .leaf(let id):
            return [id: box]
        case .split(let sideBySide, let a, let b):
            var first = box, second = box
            if sideBySide {
                first.width = box.width / 2
                second.width = box.width / 2
                second.x = box.x + box.width / 2
            } else {
                first.height = box.height / 2
                second.height = box.height / 2
                second.y = box.y + box.height / 2
            }
            return a.boxes(in: first).merging(b.boxes(in: second)) { x, _ in x }
        }
    }

    /// The leaf on the `direction` side of `id` (⌥⌘ arrows): the nearest one that shares some of its
    /// edge, then the one sharing the most, then `prefer` (where focus came from), then the first in
    /// reading order. Nil at the card's edge. `boxes`: where the leaves really are (dragged dividers,
    /// leaves not on screen left out), else `boxes()`.
    public func neighbor(of id: UUID, toward direction: SplitDirection, boxes known: [UUID: PaneBox]? = nil,
                         prefer: UUID? = nil) -> UUID? {
        let boxes = known ?? boxes()
        guard let r = boxes[id] else { return nil }
        // Real frames are whole points apart (a 1 pt divider, rounding): about half a percent of a card.
        let eps = 0.005
        var best: (UUID, gap: Double, overlap: Double)?
        for leaf in leaves where leaf != id {
            guard let c = boxes[leaf] else { continue }
            let gap: Double, overlap: Double
            switch direction {
            case .left: (gap, overlap) = (r.x - c.maxX, min(r.maxY, c.maxY) - max(r.y, c.y))
            case .right: (gap, overlap) = (c.x - r.maxX, min(r.maxY, c.maxY) - max(r.y, c.y))
            case .up: (gap, overlap) = (r.y - c.maxY, min(r.maxX, c.maxX) - max(r.x, c.x))
            case .down: (gap, overlap) = (c.y - r.maxY, min(r.maxX, c.maxX) - max(r.x, c.x))
            }
            guard gap > -eps, overlap > eps else { continue }
            if let b = best {
                let tie = abs(b.gap - gap) <= eps && abs(b.overlap - overlap) <= eps
                let better = gap < b.gap - eps || (abs(b.gap - gap) <= eps && overlap > b.overlap + eps)
                guard better || (tie && leaf == prefer) else { continue }
            }
            best = (leaf, gap, overlap)
        }
        return best?.0
    }

    /// The leaf `offset` steps from `id` in reading order, wrapping around (⌘] / ⌘[).
    public func neighbor(of id: UUID, offset: Int) -> UUID? {
        let all = leaves
        guard let i = all.firstIndex(of: id), all.count > 1 else { return nil }
        let n = all.count
        return all[((i + offset) % n + n) % n]
    }
}
