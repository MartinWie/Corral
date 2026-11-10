import Foundation

/// Everything the sidebar shows and restores: session records, folders and their order.
/// Pure value type so every tree operation is unit-testable.
public struct Workspace: Codable, Equatable, Sendable {
    public var version = 1
    public var sessions: [UUID: SessionRecord] = [:]
    public var folders: [UUID: Folder] = [:]
    /// Open sessions and folders in sidebar order. Closed sessions are not in the tree.
    public var tree: [TreeItem] = []
    public var selected: UUID?
    /// Per agent kind (rawValue): where new sessions of that kind start and which folder they join.
    public var agentDefaults: [String: AgentDefaults] = [:]
    /// App-wide preferences (Settings › General).
    public var settings = AppSettings()
    /// Sessions shown side by side, keyed by the session whose card holds them (session leaves only).
    public private(set) var splits: [UUID: PaneLayout] = [:]
    /// Closed session ids, most recently closed first. Derived (not persisted), kept in step by
    /// close/reopen/forget so the sidebar never sorts every record on a refresh.
    public private(set) var closedOrder: [UUID] = []

    public init() {}

    // Every field optional on decode so older state files keep loading after new fields appear.
    enum CodingKeys: String, CodingKey { case version, sessions, folders, tree, selected, agentDefaults, settings, splits }

    public static func == (a: Workspace, b: Workspace) -> Bool {
        a.version == b.version && a.sessions == b.sessions && a.folders == b.folders && a.tree == b.tree
            && a.selected == b.selected && a.agentDefaults == b.agentDefaults && a.settings == b.settings
            && a.splits == b.splits
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        version = try c.decodeIfPresent(Int.self, forKey: .version) ?? 1
        sessions = try c.decodeIfPresent([UUID: SessionRecord].self, forKey: .sessions) ?? [:]
        folders = try c.decodeIfPresent([UUID: Folder].self, forKey: .folders) ?? [:]
        tree = try c.decodeIfPresent([TreeItem].self, forKey: .tree) ?? []
        selected = try c.decodeIfPresent(UUID.self, forKey: .selected)
        agentDefaults = try c.decodeIfPresent([String: AgentDefaults].self, forKey: .agentDefaults) ?? [:]
        settings = try c.decodeIfPresent(AppSettings.self, forKey: .settings) ?? AppSettings()
        splits = (try? c.decodeIfPresent([UUID: PaneLayout].self, forKey: .splits)) ?? [:]
        rebuildClosedOrder()
    }

    /// Replaces the side-by-side layouts (single sessions dropped).
    public mutating func setSplits(_ all: [UUID: PaneLayout]) {
        splits = all.filter { $0.value.isSplit }
    }

    /// Side-by-side layouts reduced to open sessions, keyed by a session still in them (state from an
    /// older run: some may have been closed or forgotten since).
    public var openSplits: [UUID: PaneLayout] {
        var out: [UUID: PaneLayout] = [:]
        for (owner, layout) in splits {
            guard let kept = layout.filtered({ sessions[$0] != nil && sessions[$0]?.closedAt == nil }), kept.isSplit,
                  let key = kept.contains(owner) ? owner : kept.leaves.first else { continue }
            out[key] = kept
        }
        return out
    }

    /// Takes a session out of any side-by-side layout (it closes or is forgotten).
    mutating func leaveSplits(_ id: UUID) {
        for (owner, layout) in splits where layout.contains(id) {
            splits[owner] = nil
            let rest = layout.removing(id)
            if let rest, rest.isSplit, let key = owner == id ? rest.leaves.first : owner { splits[key] = rest }
        }
    }

    mutating func rebuildClosedOrder() {
        closedOrder = sessions.values.filter { $0.closedAt != nil }
            .sorted { ($0.closedAt ?? .distantPast) > ($1.closedAt ?? .distantPast) }
            .map(\.id)
    }

    public func defaults(for agent: AgentKind) -> AgentDefaults {
        agentDefaults[agent.rawValue] ?? AgentDefaults()
    }

    public mutating func setDefaults(_ d: AgentDefaults, for agent: AgentKind) {
        agentDefaults[agent.rawValue] = d.isEmpty ? nil : d
    }

    /// Where a new session goes and where it starts.
    /// Folder: explicit choice > the agent's default folder > next to the selected session.
    /// Directory: explicit > folder's directory > the agent's default directory > current session's > home.
    public func placement(for agent: AgentKind, folder explicit: UUID??, cwd: String?,
                          currentDirectory: String?, home: String) -> (folder: UUID?, index: Int?, directory: String) {
        var folder: UUID?
        var index: Int?
        if let explicit {
            folder = explicit
        } else if let f = defaults(for: agent).folder, folders[f] != nil, contains(f) {
            folder = f
        } else if let sel = selected, let parent = parent(of: sel) {
            folder = parent
            index = children(of: parent).firstIndex { $0.id == sel }.map { $0 + 1 }
        }
        let dir = cwd ?? directory(forFolder: folder) ?? defaults(for: agent).directory ?? currentDirectory ?? home
        return (folder, index, dir)
    }

    // MARK: Queries

    /// Open sessions in sidebar order (depth first), used for Cmd+1..9 and next/previous.
    public var openSessionsInOrder: [UUID] {
        var out: [UUID] = []
        func walk(_ items: [TreeItem]) {
            for item in items {
                switch item {
                case .session(let id): out.append(id)
                case .folder(_, let children): walk(children)
                }
            }
        }
        walk(tree)
        return out
    }

    /// Open sessions as the sidebar shows them: sessions inside collapsed folders are skipped.
    /// Cmd+1…9 count these, so the number always matches a visible row.
    public var visibleSessionsInOrder: [UUID] {
        var out: [UUID] = []
        func walk(_ items: [TreeItem]) {
            for item in items {
                switch item {
                case .session(let id): out.append(id)
                case .folder(let id, let children): if folders[id]?.expanded ?? true { walk(children) }
                }
            }
        }
        walk(tree)
        return out
    }

    public var closedSessions: [SessionRecord] { closedOrder.compactMap { sessions[$0] } }

    /// The `limit` most recently closed sessions (O(limit)).
    public func recentlyClosed(limit: Int) -> [SessionRecord] {
        closedOrder.prefix(limit).compactMap { sessions[$0] }
    }

    public var closedCount: Int { closedOrder.count }

    public func children(of folder: UUID?) -> [TreeItem] {
        guard let folder else { return tree }
        return Self.find(folder, in: tree).flatMap { item -> [TreeItem]? in
            if case .folder(_, let c) = item { return c }
            return nil
        } ?? []
    }

    /// Folder that directly contains `id`, nil for the root. Returns `.none` when `id` is not in the tree.
    public func parent(of id: UUID) -> UUID?? {
        func walk(_ items: [TreeItem], parent: UUID?) -> UUID?? {
            for item in items {
                if item.id == id { return .some(parent) }
                if case .folder(let fid, let c) = item, let hit = walk(c, parent: fid) { return hit }
            }
            return nil
        }
        return walk(tree, parent: nil)
    }

    public func contains(_ id: UUID) -> Bool { parent(of: id) != nil }

    /// Default directory for a new session created in `folder` (walks up to the nearest folder that has one).
    public func directory(forFolder folder: UUID?) -> String? {
        var current = folder
        while let fid = current {
            if let dir = folders[fid]?.directory { return dir }
            current = parent(of: fid) ?? nil
        }
        return nil
    }

    // MARK: Mutations

    public mutating func addSession(_ record: SessionRecord, in folder: UUID? = nil, at index: Int? = nil) {
        sessions[record.id] = record
        insert(.session(record.id), into: folder, at: index)
    }

    public mutating func addFolder(_ folder: Folder, in parent: UUID? = nil, at index: Int? = nil) {
        folders[folder.id] = folder
        insert(.folder(folder.id, []), into: parent, at: index)
    }

    /// Moves an item to `parent` at `index` (index counted in the destination before the move,
    /// as NSOutlineView reports it). Returns false for invalid moves such as a folder into itself.
    @discardableResult
    public mutating func move(_ id: UUID, to parent: UUID?, at index: Int?) -> Bool {
        guard let item = Self.find(id, in: tree) else { return false }
        if let parent {
            if parent == id { return false }
            if item.isFolder, Self.find(parent, in: [item]) != nil { return false }
            guard folders[parent] != nil else { return false }
        }
        var adjusted = index
        if let index, let current = self.parent(of: id), current == parent,
           let from = children(of: parent).firstIndex(where: { $0.id == id }), from < index {
            adjusted = index - 1
        }
        tree = Self.remove(id, from: tree).items
        insert(item, into: parent, at: adjusted)
        return true
    }

    /// Takes a session out of the tree and remembers its folder; the record stays for search and reopen.
    public mutating func close(_ id: UUID, at date: Date = Date()) {
        guard var record = sessions[id], record.closedAt == nil else { return }
        record.lastFolder = parent(of: id) ?? nil
        record.closedAt = date
        sessions[id] = record
        closedOrder.removeAll { $0 == id }
        closedOrder.insert(id, at: 0)
        tree = Self.remove(id, from: tree).items
        if selected == id { selected = nil }
        leaveSplits(id)
    }

    public mutating func reopen(_ id: UUID, in folder: UUID?? = nil, at index: Int? = nil) {
        guard var record = sessions[id], record.closedAt != nil else { return }
        record.closedAt = nil
        record.lastActiveAt = Date()
        sessions[id] = record
        closedOrder.removeAll { $0 == id }
        var target: UUID? = record.lastFolder
        if let folder { target = folder }
        if let t = target, folders[t] == nil || !contains(t) { target = nil }
        insert(.session(id), into: target, at: index)
    }

    /// Plain terminals don't stay in Closed (only sessions that ran an agent do); drops the ones
    /// state from before that rule still holds.
    /// Returns the forgotten ids (their scrollback leaves the search index too).
    @discardableResult
    public mutating func forgetClosedShells() -> [UUID] {
        let ids = sessions.values.filter { $0.closedAt != nil && $0.agent == .shell }.map(\.id)
        for id in ids { forget(id) }
        return ids
    }

    /// Takes the name the agent has for a session's conversation ("" for none). The first one only
    /// records it (a name the user gave stays); a new name after that is a rename inside the agent
    /// and replaces the user's own: the latest rename wins. Returns whether the record changed.
    @discardableResult
    public mutating func setAgentName(_ name: String, for id: UUID) -> Bool {
        guard var r = sessions[id], r.agentName != name else { return false }
        if r.agentName != nil, !name.isEmpty { r.customName = nil }
        r.agentName = name
        sessions[id] = r
        return true
    }

    /// Forgets a closed session entirely (transcripts on disk are untouched).
    public mutating func forget(_ id: UUID) {
        tree = Self.remove(id, from: tree).items
        leaveSplits(id)
        sessions[id] = nil
        closedOrder.removeAll { $0 == id }
        if selected == id { selected = nil }
    }

    /// Deletes a folder; its children move up to the folder's position.
    public mutating func deleteFolder(_ id: UUID) {
        guard let item = Self.find(id, in: tree), case .folder(_, let children) = item,
              let parentId = parent(of: id) else { return }
        let index = self.children(of: parentId).firstIndex(where: { $0.id == id }) ?? 0
        tree = Self.remove(id, from: tree).items
        for (offset, child) in children.enumerated() {
            insert(child, into: parentId, at: index + offset)
        }
        folders[id] = nil
        for (key, d) in agentDefaults where d.folder == id {
            agentDefaults[key]?.folder = nil
            if agentDefaults[key]?.isEmpty == true { agentDefaults[key] = nil }
        }
        for key in sessions.keys where sessions[key]?.lastFolder == id {
            sessions[key]?.lastFolder = parentId
        }
    }

    /// Drops records whose sessions are neither open nor closed-and-remembered (defensive cleanup).
    public mutating func repair() {
        let open = Set(openSessionsInOrder)
        for (id, record) in sessions {
            if record.closedAt == nil && !open.contains(id) {
                sessions[id]?.closedAt = record.lastActiveAt
            } else if record.closedAt != nil && open.contains(id) {
                // In the tree wins: it would be spawned at launch and again on reopen otherwise.
                sessions[id]?.closedAt = nil
            }
        }
        func prune(_ items: [TreeItem]) -> [TreeItem] {
            items.compactMap { item in
                switch item {
                case .session(let id): return sessions[id] == nil ? nil : item
                case .folder(let id, let c): return folders[id] == nil ? nil : .folder(id, prune(c))
                }
            }
        }
        tree = prune(tree)
        if let s = selected, !open.contains(s) { selected = nil }
        rebuildClosedOrder()
    }

    // MARK: Tree helpers

    private mutating func insert(_ item: TreeItem, into parent: UUID?, at index: Int?) {
        if let parent, Self.find(parent, in: tree) != nil {
            tree = Self.insert(item, into: parent, at: index, in: tree)
        } else {
            let i = min(max(index ?? tree.count, 0), tree.count)
            tree.insert(item, at: i)
        }
    }

    static func find(_ id: UUID, in items: [TreeItem]) -> TreeItem? {
        for item in items {
            if item.id == id { return item }
            if case .folder(_, let c) = item, let hit = find(id, in: c) { return hit }
        }
        return nil
    }

    static func remove(_ id: UUID, from items: [TreeItem]) -> (items: [TreeItem], removed: TreeItem?) {
        var removed: TreeItem?
        var out: [TreeItem] = []
        for item in items {
            if item.id == id { removed = item; continue }
            if case .folder(let fid, let c) = item {
                let r = remove(id, from: c)
                removed = removed ?? r.removed
                out.append(.folder(fid, r.items))
            } else {
                out.append(item)
            }
        }
        return (out, removed)
    }

    static func insert(_ new: TreeItem, into parent: UUID, at index: Int?, in items: [TreeItem]) -> [TreeItem] {
        items.map { item in
            guard case .folder(let fid, var c) = item else { return item }
            if fid == parent {
                let i = min(max(index ?? c.count, 0), c.count)
                c.insert(new, at: i)
                return .folder(fid, c)
            }
            return .folder(fid, insert(new, into: parent, at: index, in: c))
        }
    }
}

/// Atomic JSON persistence for the workspace.
public struct WorkspaceStore: Sendable {
    public let url: URL

    public init(url: URL = CorralPaths.support.appendingPathComponent("state.json")) {
        self.url = url
    }

    public func load() -> Workspace {
        guard let data = try? Data(contentsOf: url) else { return Workspace() }
        do {
            var ws = try Self.decoder.decode(Workspace.self, from: data)
            ws.repair()
            return ws
        } catch {
            // Keep the unreadable file for inspection instead of silently losing sessions.
            let backup = url.deletingPathExtension().appendingPathExtension("corrupt-\(Int(Date().timeIntervalSince1970)).json")
            try? FileManager.default.moveItem(at: url, to: backup)
            return Workspace()
        }
    }

    public func save(_ ws: Workspace) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let data = try Self.encoder.encode(ws)
        try data.write(to: url, options: .atomic)
    }

    static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        e.dateEncodingStrategy = .iso8601
        return e
    }()

    static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()
}

public enum CorralPaths {
    public static var support: URL {
        if let override = ProcessInfo.processInfo.environment["CORRAL_SUPPORT_DIR"], !override.isEmpty {
            return URL(fileURLWithPath: override, isDirectory: true)
        }
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Corral", isDirectory: true)
    }

    public static var socket: URL { support.appendingPathComponent("corral.sock") }
    public static var index: URL { support.appendingPathComponent("index.sqlite") }
    public static var scrollback: URL { support.appendingPathComponent("scrollback", isDirectory: true) }
}

/// App-wide preferences, stored with the workspace. Every field decodes optionally.
public struct AppSettings: Codable, Equatable, Sendable {
    /// Hold off idle sleep while an agent is working (not while it waits for the user).
    public var keepAwake = false
    /// With `keepAwake`: the display stays on too (no display sleep, screen saver or lock).
    public var keepDisplayOn = false
    public var notifications = NotificationSettings()
    /// Agents whose status hooks the user removed in Settings: the sidebar stops offering them.
    public var hooksRemoved: Set<AgentKind> = []

    public init(keepAwake: Bool = false, notifications: NotificationSettings = NotificationSettings()) {
        self.keepAwake = keepAwake
        self.notifications = notifications
    }

    enum CodingKeys: String, CodingKey { case keepAwake, keepDisplayOn, notifications, hooksRemoved }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        keepAwake = try c.decodeIfPresent(Bool.self, forKey: .keepAwake) ?? false
        keepDisplayOn = try c.decodeIfPresent(Bool.self, forKey: .keepDisplayOn) ?? false
        notifications = (try? c.decodeIfPresent(NotificationSettings.self, forKey: .notifications)) ?? NotificationSettings()
        hooksRemoved = (try? c.decodeIfPresent(Set<AgentKind>.self, forKey: .hooksRemoved)) ?? []
    }
}
