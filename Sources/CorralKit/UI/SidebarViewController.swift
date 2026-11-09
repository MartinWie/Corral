import AppKit
import CorralCore

final class SidebarNode: NSObject {
    enum Kind: Hashable {
        case folder(UUID)
        case session(UUID)
        case backgroundHeader
        case background(String)
        case closedHeader
        case closed(UUID)
    }

    let kind: Kind
    var children: [SidebarNode] = []

    init(_ kind: Kind) { self.kind = kind }

    var isHeader: Bool { kind == .backgroundHeader || kind == .closedHeader }
}

extension SidebarNode.Kind {
    var isPreview: Bool {
        switch self {
        case .closed, .background: return true
        default: return false
        }
    }

    /// Folders and section headers: nodes with a child list.
    var isContainer: Bool {
        switch self {
        case .folder, .backgroundHeader, .closedHeader: return true
        default: return false
        }
    }
}

protocol SidebarDelegate: AnyObject {
    func sidebarShowClosed(_ id: UUID)
    func sidebarShowBackground(_ agent: BackgroundAgent)
    func sidebarFocusTerminal()
}

/// Session list: folders and sessions (drag and drop), background agents, recently closed.
final class SidebarViewController: NSViewController, NSOutlineViewDataSource, NSOutlineViewDelegate, NSMenuDelegate {
    typealias Kind = SidebarNode.Kind
    /// Children per parent (nil = root), as last handed to the outline.
    typealias Snapshot = [Kind?: [Kind]]

    let manager: SessionManager
    weak var delegate: SidebarDelegate?

    let outline = SidebarOutlineView()
    let scroll = NSScrollView()
    let banner = IntegrationsCard()
    let bottomBar = SidebarStatusBar()
    let topChip = AttentionEdgeChip(direction: .up)
    let bottomChip = AttentionEdgeChip(direction: .down)
    let topFade = EdgeFadeView(top: true)
    let bottomFade = EdgeFadeView(top: false)

    private var nodes: [Kind: SidebarNode] = [:]
    private(set) var roots: [SidebarNode] = []
    private var shown: Snapshot = [:]
    private var parentOf: [Kind: SidebarNode] = [:]
    private var loaded = false
    private var syncingSelection = false
    /// Programmatic expansion (restore after reload): never animated.
    private var restoring = false
    /// A reveal scrolls itself; selection sync must not jump there first.
    private var revealing = false
    static let dragType = NSPasteboard.PasteboardType("dev.corral.sidebar-node")
    private static let closedLimit = 40
    private var clockTimer: Timer?

    /// Structural diff planner (§4.4); tests substitute fake plans.
    var planner: (Snapshot, Snapshot) -> SidebarDiff.Plan<Kind> = { SidebarDiff.plan(old: $0, new: $1) }
    /// Rows that need input (sessions and background agents), for the edge chips.
    private(set) var waiting: Set<Kind> = []
    private(set) var loopsPaused = false
    /// ⌘N hints while Command is held, keyed by session.
    private(set) var commandHints: [UUID: String] = [:]
    /// Hold time before hints appear, so quick ⌘C / ⌘V never flash them.
    static var commandHintDelay: TimeInterval = 0.2
    private var hintWork: DispatchWorkItem?
    private var flagsMonitor: Any?
    private var bannerShown: NSLayoutConstraint!
    private var bannerHidden: NSLayoutConstraint!
    private var bannerWanted: Bool?
    private var bannerGeneration = 0
    private(set) var chipTargets: (above: Int?, below: Int?) = (nil, nil)
    private var backgroundIds: [String: UUID] = [:]
    /// From the main menu, refreshed when shortcuts change (not per configure).
    private lazy var closeTip = Self.closeTooltip()

    static func closeTooltip() -> String {
        KeyHint.string(for: #selector(MainWindowController.closeSession(_:))).map { "Close Session (\($0))" } ?? "Close Session"
    }

    init(manager: SessionManager) {
        self.manager = manager
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError() }

    deinit {
        clockTimer?.invalidate()
        if let flagsMonitor { NSEvent.removeMonitor(flagsMonitor) }
    }

    override func loadView() {
        let root = NSView()
        root.wantsLayer = true
        let column = NSTableColumn(identifier: .init("main"))
        column.resizingMask = .autoresizingMask
        outline.addTableColumn(column)
        outline.outlineTableColumn = column
        outline.applyStyle()
        outline.autoresizesOutlineColumn = false
        outline.columnAutoresizingStyle = .uniformColumnAutoresizingStyle
        outline.dataSource = self
        outline.delegate = self
        outline.target = self
        outline.action = #selector(rowClicked)
        outline.doubleAction = #selector(doubleClicked)
        outline.registerForDraggedTypes([Self.dragType])
        outline.setDraggingSourceOperationMask(.move, forLocal: true)
        outline.onKeyChange = { [weak self] key in if !key { self?.setCommandHeld(false) } }
        outline.onOcclusionChange = { [weak self] visible in self?.occlusionChanged(visible: visible) }
        let menu = NSMenu()
        menu.delegate = self
        outline.menu = menu

        scroll.documentView = outline
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = false
        scroll.autohidesScrollers = true
        scroll.scrollerStyle = .overlay
        scroll.drawsBackground = false
        scroll.automaticallyAdjustsContentInsets = false
        scroll.contentInsets = NSEdgeInsets(top: 4, left: 0, bottom: 8, right: 0)
        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.contentView.postsBoundsChangedNotifications = true

        bottomBar.translatesAutoresizingMaskIntoConstraints = false
        bottomBar.onSegment = { [weak self] in self?.statusSegmentClicked($0) }
        topChip.onClick = { [weak self] in self?.revealWaiting(above: true) }
        bottomChip.onClick = { [weak self] in self?.revealWaiting(above: false) }
        // The chips float over the list: wheel events over them still scroll it.
        topChip.scrollTarget = scroll
        bottomChip.scrollTarget = scroll
        banner.isHidden = true

        for v in [scroll, topFade, bottomFade, topChip, bottomChip, banner, bottomBar] as [NSView] { root.addSubview(v) }
        bannerShown = scroll.bottomAnchor.constraint(equalTo: banner.topAnchor, constant: -6)
        bannerHidden = scroll.bottomAnchor.constraint(equalTo: bottomBar.topAnchor)
        NSLayoutConstraint.activate([
            scroll.topAnchor.constraint(equalTo: root.safeAreaLayoutGuide.topAnchor),
            scroll.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            bannerHidden,
            banner.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 8),
            banner.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -8),
            banner.bottomAnchor.constraint(equalTo: bottomBar.topAnchor, constant: -6),
            bottomBar.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            bottomBar.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            bottomBar.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            bottomBar.heightAnchor.constraint(equalToConstant: 32),
            topFade.topAnchor.constraint(equalTo: scroll.topAnchor),
            topFade.leadingAnchor.constraint(equalTo: scroll.leadingAnchor),
            topFade.trailingAnchor.constraint(equalTo: scroll.trailingAnchor),
            topFade.heightAnchor.constraint(equalToConstant: 14),
            bottomFade.bottomAnchor.constraint(equalTo: scroll.bottomAnchor),
            bottomFade.leadingAnchor.constraint(equalTo: scroll.leadingAnchor),
            bottomFade.trailingAnchor.constraint(equalTo: scroll.trailingAnchor),
            bottomFade.heightAnchor.constraint(equalToConstant: 14),
            topChip.topAnchor.constraint(equalTo: scroll.topAnchor, constant: 8),
            topChip.centerXAnchor.constraint(equalTo: scroll.centerXAnchor),
            bottomChip.bottomAnchor.constraint(equalTo: scroll.bottomAnchor, constant: -8),
            bottomChip.centerXAnchor.constraint(equalTo: scroll.centerXAnchor),
        ])
        topFade.isHidden = true
        bottomFade.isHidden = true
        view = root
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        manager.observe { [weak self] change in
            guard let self else { return }
            switch change {
            case .structure, .background: self.reload()
            case .status(let id): self.reloadStatus(id)
            case .selection: self.syncSelection()
            case .integrations: self.updateBanner(animated: true)
            case .reveal(let id): self.reveal(id)
            case .panes: self.refreshCompanions()
            case .appearance, .settings: break
            }
        }
        reload()
        updateBanner(animated: false)
        // Re-renders relative times only; no data polling.
        clockTimer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.clockTick() }
        }
        clockTimer?.tolerance = 5
        let nc = NotificationCenter.default
        nc.addObserver(self, selector: #selector(themeChanged), name: .corralThemeDidChange, object: nil)
        nc.addObserver(self, selector: #selector(motionChanged), name: .corralMotionChanged, object: nil)
        nc.addObserver(self, selector: #selector(clipBoundsChanged), name: NSView.boundsDidChangeNotification,
                       object: scroll.contentView)
        flagsMonitor = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { [weak self] event in
            MainActor.assumeIsolated { self?.handleFlagsChanged(event) }
            return event
        }
    }

    override func viewDidLayout() {
        super.viewDidLayout()
        updateFades()
        refreshEdgeChips(animated: false)
    }

    // MARK: Integrations banner

    private func updateBanner(animated: Bool) {
        // Only agents set up on this Mac: no nagging about tools the user doesn't have.
        let missing = manager.missingIntegrations.map { $0 == .claude ? "Claude" : $0.displayName }
        if !missing.isEmpty { banner.update(missing: missing) }
        setBannerVisible(!missing.isEmpty, animated: animated && SidebarFX.canAnimate(view))
    }

    /// M30: fade, then one layout jump (no constraint animation).
    private func setBannerVisible(_ show: Bool, animated: Bool) {
        guard show != bannerWanted else { return }
        bannerWanted = show
        bannerGeneration += 1
        let generation = bannerGeneration
        if show {
            banner.layer?.removeAnimation(forKey: "sidebar.banner")
            banner.isHidden = false
            bannerHidden.isActive = false
            bannerShown.isActive = true
            if animated {
                banner.layer?.add(Motion.basic("opacity", from: 0, to: 1, duration: 0.20, timing: Motion.out), forKey: "sidebar.banner")
            }
        } else if animated, let layer = banner.layer {
            let fade = Motion.basic("opacity", from: layer.presentation()?.opacity ?? 1, to: 0, duration: 0.16, timing: Motion.exit)
            fade.fillMode = .forwards
            fade.isRemovedOnCompletion = false
            CATransaction.begin()
            CATransaction.setCompletionBlock { [weak self] in
                MainActor.assumeIsolated {
                    guard let self, self.bannerGeneration == generation else { return }
                    self.hideBannerNow()
                }
            }
            layer.add(fade, forKey: "sidebar.banner")
            CATransaction.commit()
        } else {
            hideBannerNow()
        }
    }

    private func hideBannerNow() {
        banner.isHidden = true
        bannerShown.isActive = false
        bannerHidden.isActive = true
        banner.layer?.removeAnimation(forKey: "sidebar.banner")
    }

    // MARK: Model

    func node(_ kind: Kind) -> SidebarNode {
        if let n = nodes[kind] { return n }
        let n = SidebarNode(kind)
        nodes[kind] = n
        return n
    }

    private func build(_ item: TreeItem) -> SidebarNode {
        switch item {
        case .session(let id): return node(.session(id))
        case .folder(let id, let children):
            let n = node(.folder(id))
            n.children = children.map(build)
            return n
        }
    }

    /// Structure path (§4.4): rebuild nodes, then animate a planned diff or fall back to `reloadData`.
    func reload() {
        let ws = manager.workspace
        var top = ws.tree.map(build)
        let bg = manager.unattachedBackground
        if !bg.isEmpty {
            let h = node(.backgroundHeader)
            h.children = bg.map { node(.background($0.id)) }
            top.append(h)
        }
        let closed = ws.recentlyClosed(limit: Self.closedLimit)
        if !closed.isEmpty {
            let h = node(.closedHeader)
            h.children = closed.map { node(.closed($0.id)) }
            top.append(h)
        }
        roots = top
        let old = shown
        shown = snapshot()
        rebuildWaiting()

        let previous = outline.selectedRow >= 0 ? outline.item(atRow: outline.selectedRow) as? SidebarNode : nil
        syncingSelection = true
        var applied = false
        if loaded, old == shown {
            // Same tree (background refreshes, renames, folder directories): cells update in place, so
            // loops keep their phase and hover and in-flight animations survive.
            reconfigureVisibleRows(animated: true)
            applied = true
        } else if loaded, case .ops(let ops) = planner(old, shown) {
            applied = apply(ops, old: old, new: shown)
        }
        if !applied { fullReload() }
        syncingSelection = false
        loaded = true

        // Keep a closed-session / background-agent preview selected across list refreshes;
        // explicit selection changes arrive as .selection and resync.
        if let previous, previous.kind.isPreview, case let row = outline.row(forItem: previous), row >= 0 {
            if outline.selectedRow != row {
                syncingSelection = true
                outline.selectRowIndexes([row], byExtendingSelection: false)
                syncingSelection = false
            }
        } else {
            syncSelection()
        }
        if !commandHints.isEmpty { setCommandHeld(true) }
        refreshChrome(animated: true)
    }

    private func fullReload() {
        let offset = scroll.contentView.bounds.origin
        outline.reloadData()
        outline.resetHover()
        restoring = true
        restoreExpansion(roots)
        restoring = false
        scroll.contentView.scroll(to: offset)
        scroll.reflectScrolledClipView(scroll.contentView)
        outline.refreshHoverFromMouse()
    }

    private func snapshot() -> Snapshot {
        var out: Snapshot = [nil: roots.map(\.kind)]
        var parents: [Kind: SidebarNode] = [:]
        func walk(_ list: [SidebarNode]) {
            for n in list where n.kind.isContainer {
                out[n.kind] = n.children.map(\.kind)
                for c in n.children { parents[c.kind] = n }
                walk(n.children)
            }
        }
        walk(roots)
        parentOf = parents
        return out
    }

    /// Applies planned ops in sequential-index semantics: removes (old indexes, descending), inserts
    /// (new indexes, ascending), one move. Returns false when the outline disagrees with the model.
    private func apply(_ ops: [SidebarDiff.Op<Kind>], old: Snapshot, new: Snapshot) -> Bool {
        func item(_ k: Kind?) -> SidebarNode? { k.flatMap { nodes[$0] } }
        // Children of a parent that was itself inserted or removed travel with it.
        func persists(_ k: Kind?) -> Bool { k == nil || (old[k] != nil && new[k] != nil) }
        // Collapsed or hidden parents are not tracked row by row: reload them instead.
        func live(_ k: Kind?) -> Bool {
            guard let k else { return true }
            guard let n = nodes[k] else { return false }
            return outline.row(forItem: n) >= 0 && outline.isItemExpanded(n)
        }
        var removes: [(SidebarNode?, Int)] = []
        var inserts: [(SidebarNode?, Int)] = []
        var moves: [(SidebarNode?, Int, SidebarNode?, Int)] = []
        var deferred: [SidebarNode] = []
        var arrived: [SidebarNode] = []
        func later(_ k: Kind?) { if let n = item(k), !deferred.contains(n) { deferred.append(n) } }
        func arriving(_ k: Kind?, _ i: Int) {
            if let list = new[k], i < list.count, let n = nodes[list[i]] { arrived.append(n) }
        }
        // Out-of-range indexes would raise inside AppKit: reload instead.
        func valid(_ snap: Snapshot, _ k: Kind?, _ i: Int) -> Bool { i >= 0 && i < (snap[k]?.count ?? 0) }
        for op in ops {
            switch op {
            case .remove(let p, let i): if persists(p), !valid(old, p, i) { return false }
            case .insert(let p, let i): if persists(p), !valid(new, p, i) { return false }
            case .move(let fp, let f, let tp, let t): if !valid(old, fp, f) || !valid(new, tp, t) { return false }
            }
        }
        for op in ops {
            switch op {
            case .remove(let p, let i):
                guard persists(p) else { continue }
                if live(p) { removes.append((item(p), i)) } else { later(p) }
            case .insert(let p, let i):
                guard persists(p) else { continue }
                if live(p) { inserts.append((item(p), i)); arriving(p, i) } else { later(p) }
            case .move(let fp, let f, let tp, let t):
                guard persists(fp), persists(tp) else { return false }
                switch (live(fp), live(tp)) {
                case (true, true): moves.append((item(fp), f, item(tp), t))
                case (true, false): removes.append((item(fp), f)); later(tp)
                case (false, true): inserts.append((item(tp), t)); arriving(tp, t); later(fp)
                case (false, false): later(fp); later(tp)
                }
            }
        }

        let animate = SidebarFX.canAnimate(outline)
        let full = animate && Motion.full
        let insertAnimation: NSTableView.AnimationOptions = full ? [.effectFade, .slideDown] : (animate ? .effectFade : [])
        let removeAnimation: NSTableView.AnimationOptions = full ? [.effectFade, .slideUp] : (animate ? .effectFade : [])
        NSAnimationContext.beginGrouping()
        let ctx = NSAnimationContext.current
        ctx.duration = !animate ? 0 : (!moves.isEmpty ? (full ? 0.20 : 0) : (inserts.isEmpty ? 0.16 : Motion.base))
        ctx.timingFunction = Motion.std
        // Inserts and removes shift row indexes: drop the hover now, re-derive it from the pointer after.
        outline.resetHover()
        outline.beginUpdates()
        for (p, i) in removes.sorted(by: { $0.1 > $1.1 }) {
            outline.removeItems(at: [i], inParent: p, withAnimation: removeAnimation)
        }
        for (p, i) in inserts.sorted(by: { $0.1 < $1.1 }) {
            outline.insertItems(at: [i], inParent: p, withAnimation: insertAnimation)
        }
        for (fp, f, tp, t) in moves { outline.moveItem(at: f, inParent: fp, to: t, inParent: tp) }
        outline.endUpdates()
        NSAnimationContext.endGrouping()
        for n in deferred { outline.reloadItem(n, reloadChildren: true) }
        restoring = true
        // New folders arrive expanded; a visible parent the model has open (e.g. an empty folder that
        // just got its first child) is reopened after its reload.
        restoreExpansion(arrived + deferred.filter { outline.row(forItem: $0) >= 0 })
        restoring = false

        guard outline.numberOfRows == visibleRowCount() else { return false }
        reconfigureVisibleRows(animated: true)
        if animate {
            for n in arrived {
                guard case .session = n.kind, case let row = outline.row(forItem: n), row >= 0 else { continue }
                (outline.rowView(atRow: row, makeIfNecessary: false) as? SidebarRowView)?.flashArrival()
            }
        }
        outline.refreshHoverFromMouse()
        return true
    }

    /// Rows the outline should show for the current model and expansion state.
    private func visibleRowCount() -> Int {
        func count(_ list: [SidebarNode]) -> Int {
            list.reduce(0) { $0 + 1 + (outline.isItemExpanded($1) ? count($1.children) : 0) }
        }
        return count(roots)
    }

    private func restoreExpansion(_ list: [SidebarNode]) {
        for n in list {
            switch n.kind {
            case .folder(let id):
                if manager.workspace.folders[id]?.expanded ?? true { outline.expandItem(n) }
                restoreExpansion(n.children)
            case .backgroundHeader:
                if !UserDefaults.standard.bool(forKey: "sidebar.background.collapsed") { outline.expandItem(n) }
            case .closedHeader:
                if UserDefaults.standard.bool(forKey: "sidebar.closed.expanded") { outline.expandItem(n) }
            default: break
            }
        }
    }

    private func rebuildWaiting() {
        var w: Set<Kind> = []
        for (id, ls) in manager.live where ls.status.activity == .needsInput { w.insert(.session(id)) }
        for a in manager.unattachedBackground where a.activity == .needsInput { w.insert(.background(a.id)) }
        waiting = w
    }

    /// Status path (§4.4): reconfigure the visible cell, its row view and folder ancestors in place.
    private func reloadStatus(_ id: UUID) {
        guard let n = nodes[.session(id)] else { return }
        if manager.status(id)?.activity == .needsInput { waiting.insert(.session(id)) } else { waiting.remove(.session(id)) }
        let row = outline.row(forItem: n)
        if row >= 0 {
            if let cell = outline.view(atColumn: 0, row: row, makeIfNecessary: false) as? SessionRowView,
               let m = sessionModel(id) {
                cell.configure(m, session: id, animated: true)
            }
            (outline.rowView(atRow: row, makeIfNecessary: false) as? SidebarRowView)?.tone = tone(n)
        }
        // Model ancestors: a collapsed folder's badge must follow hidden children too.
        var parent = parentOf[n.kind]
        while let f = parent {
            let r = outline.row(forItem: f)
            if r >= 0, let cell = outline.view(atColumn: 0, row: r, makeIfNecessary: false) as? FolderRowView {
                cell.configure(folderModel(f), animated: true)
            }
            parent = parentOf[f.kind]
        }
        refreshChrome(animated: true)
    }

    /// Opens the folders (or section) around session `id`, selects its row and scrolls it into the middle.
    func reveal(_ id: UUID) {
        guard isViewLoaded, let n = nodes[.session(id)] else { return }
        var closed: [SidebarNode] = []
        var parent = parentOf[n.kind]
        while let p = parent {
            if !outline.isItemExpanded(p) { closed.append(p) }
            parent = parentOf[p.kind]
        }
        for p in closed.reversed() { outline.expandItem(p) }
        revealing = true
        syncSelection()
        revealing = false
        let row = outline.row(forItem: n)
        if row >= 0 { scrollToCenter(row) }
    }

    /// Rows of sessions on screen next to the selected one get the companion fill.
    private func isCompanion(_ n: SidebarNode) -> Bool {
        guard case .session(let id) = n.kind, let sel = manager.workspace.selected, id != sel else { return false }
        return manager.sideBySide(sel).contains(id)
    }

    func refreshCompanions() {
        guard isViewLoaded else { return }
        outline.enumerateAvailableRowViews { [self] rv, row in
            guard let srv = rv as? SidebarRowView, let n = outline.item(atRow: row) as? SidebarNode else { return }
            srv.companion = isCompanion(n)
        }
    }

    private func syncSelection() {
        refreshCompanions()
        guard let sel = manager.workspace.selected, let n = nodes[.session(sel)] else { return }
        let row = outline.row(forItem: n)
        guard row >= 0, outline.selectedRow != row else { return }
        syncingSelection = true
        outline.selectRowIndexes([row], byExtendingSelection: false)
        if !revealing { outline.scrollRowToVisible(row) }
        syncingSelection = false
    }

    // MARK: Row models

    func sessionModel(_ id: UUID) -> SessionRowModel? {
        guard let record = manager.workspace.sessions[id] else { return nil }
        let s = manager.status(id) ?? LiveStatus()
        let agent = s.agent == .shell && record.agentRunning ? record.agent : s.agent
        return .make(title: displayTitle(record, s), status: s, agent: agent, cwd: s.cwd ?? record.cwd,
                     launching: manager.launchKind(id) ?? (manager.isPendingRestore(id) ? .resuming : nil))
    }

    private func folderModel(_ n: SidebarNode) -> FolderRowModel {
        guard case .folder(let id) = n.kind else { return FolderRowModel(name: "", hasDirectory: false) }
        let f = manager.workspace.folders[id]
        var m = FolderRowModel(name: f?.name ?? "Folder", hasDirectory: f?.directory != nil)
        m.expanded = outline.isItemExpanded(n)
        func walk(_ list: [SidebarNode]) {
            for c in list {
                switch c.kind {
                case .session(let sid):
                    m.sessions += 1
                    guard let s = manager.status(sid) else { continue }
                    switch s.activity {
                    case .needsInput: m.needsInput += 1
                    case .working: m.working += 1
                    case .done where s.unread: m.doneUnread += 1
                    case .error: m.errors += 1
                    default: break
                    }
                case .folder: walk(c.children)
                default: break
                }
            }
        }
        walk(n.children)
        return m
    }

    private func tone(_ n: SidebarNode) -> SidebarRowView.Tone {
        switch n.kind {
        case .session(let id): return manager.status(id)?.activity == .needsInput ? .attention : .plain
        case .background(let job):
            return manager.background.first { $0.id == job }?.activity == .needsInput ? .attention : .plain
        default: return .plain
        }
    }

    private func rowKind(_ n: SidebarNode) -> SidebarRowView.Kind {
        switch n.kind {
        case .session: return .session
        case .folder: return .folder
        case .backgroundHeader, .closedHeader: return .header
        case .background, .closed: return .compact
        }
    }

    /// Background jobs have string ids; icons key their animations by UUID.
    private func backgroundId(_ job: String) -> UUID {
        if let id = backgroundIds[job] { return id }
        let id = UUID()
        backgroundIds[job] = id
        return id
    }

    func displayTitle(_ r: SessionRecord, _ s: LiveStatus) -> String {
        if let n = r.customName, !n.isEmpty { return n }
        if let t = s.title, !t.isEmpty, r.takesTerminalTitle(fromAgent: s.titleFromAgent) { return t }
        return r.displayTitle
    }

    // MARK: Data source

    func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
        (item as? SidebarNode)?.children.count ?? roots.count
    }

    func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
        (item as? SidebarNode)?.children[index] ?? roots[index]
    }

    func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool {
        (item as? SidebarNode)?.kind.isContainer ?? false
    }

    func outlineView(_ outlineView: NSOutlineView, isGroupItem item: Any) -> Bool {
        (item as? SidebarNode)?.isHeader ?? false
    }

    func outlineView(_ outlineView: NSOutlineView, heightOfRowByItem item: Any) -> CGFloat {
        guard let n = item as? SidebarNode else { return 26 }
        switch n.kind {
        case .session: return 38
        case .folder: return 28
        case .backgroundHeader, .closedHeader: return 30
        case .background, .closed: return 26
        }
    }

    func outlineView(_ outlineView: NSOutlineView, shouldSelectItem item: Any) -> Bool {
        !((item as? SidebarNode)?.isHeader ?? true)
    }

    func outlineView(_ outlineView: NSOutlineView, rowViewForItem item: Any) -> NSTableRowView? {
        let rv = outlineView.makeView(withIdentifier: SidebarRowView.reuseID, owner: self) as? SidebarRowView ?? {
            let v = SidebarRowView(frame: .zero)
            v.identifier = SidebarRowView.reuseID
            return v
        }()
        if let n = item as? SidebarNode {
            rv.node = n
            rv.kind = rowKind(n)
            rv.tone = tone(n)
            rv.companion = isCompanion(n)
        }
        return rv
    }

    func outlineView(_ outlineView: NSOutlineView, didAdd rowView: NSTableRowView, forRow row: Int) {
        guard let rv = rowView as? SidebarRowView else { return }
        let hovered = row == outline.hoveredRow
        rv.hovered = hovered
        (rv.cellView as? SidebarCell)?.setHovered(hovered, animated: false)
        rv.syncCell()
    }

    func outlineView(_ outlineView: NSOutlineView, didRemove rowView: NSTableRowView, forRow row: Int) {
        (rowView as? SidebarRowView)?.hovered = false
    }

    func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
        guard let n = item as? SidebarNode else { return nil }
        let cell: NSTableCellView
        switch n.kind {
        case .session: cell = reuse(SessionRowView.self, outlineView)
        case .folder: cell = reuse(FolderRowView.self, outlineView)
        case .backgroundHeader, .closedHeader: cell = reuse(SectionHeaderView.self, outlineView)
        case .background, .closed: cell = reuse(CompactRowView.self, outlineView)
        }
        // Rows scrolling in configure without animation.
        configure(cell, for: n, animated: false)
        return cell
    }

    private func configure(_ view: NSView?, for n: SidebarNode, animated: Bool) {
        let ws = manager.workspace
        switch n.kind {
        case .session(let id):
            guard let cell = view as? SessionRowView, let m = sessionModel(id) else { return }
            cell.configure(m, session: id, animated: animated)
            cell.setHint(commandHints[id], animated: false)
            if cell.closeButton.action != #selector(closeRowClicked(_:)) {
                cell.closeButton.target = self
                cell.closeButton.action = #selector(closeRowClicked(_:))
            }
            if cell.closeButton.toolTip != closeTip { cell.closeButton.toolTip = closeTip }
        case .folder:
            guard let cell = view as? FolderRowView else { return }
            cell.configure(folderModel(n), animated: animated)
            if cell.disclosure.action != #selector(disclosureClicked(_:)) {
                cell.disclosure.target = self
                cell.disclosure.action = #selector(disclosureClicked(_:))
            }
        case .backgroundHeader:
            (view as? SectionHeaderView)?.configure(title: "Background", count: n.children.count, noun: "agent",
                                                    expanded: outline.isItemExpanded(n), animated: animated)
        case .closedHeader:
            (view as? SectionHeaderView)?.configure(title: "Closed", count: ws.closedCount, noun: "session",
                                                    expanded: outline.isItemExpanded(n), animated: animated)
        case .background(let job):
            guard let cell = view as? CompactRowView, let a = manager.background.first(where: { $0.id == job }) else { return }
            cell.configure(CompactRowModel(title: a.name, trailing: a.state, activity: a.activity,
                                           unread: a.activity == .needsInput, agent: .claude, style: .background),
                           session: backgroundId(job), animated: animated)
            let tip = [a.needs, a.detail].compactMap { $0 }.joined(separator: "\n")
            cell.toolTip = tip.isEmpty ? nil : tip
        case .closed(let id):
            guard let cell = view as? CompactRowView, let r = ws.sessions[id] else { return }
            cell.configure(CompactRowModel(title: r.displayTitle, trailing: r.closedAt.map { RelativeTime.short(since: $0) } ?? "",
                                           activity: .idle, unread: false, agent: r.agent, style: .closed, closedAt: r.closedAt),
                           session: id, animated: false)
            cell.toolTip = RelativeTime.abbreviatePath(r.cwd)
            if cell.reopenButton.action != #selector(reopenRowClicked(_:)) {
                cell.reopenButton.target = self
                cell.reopenButton.action = #selector(reopenRowClicked(_:))
            }
        }
        // Both ways: a reused cell may still carry the pause from before it went to the pool.
        if let c = view as? SidebarCell { c.setLoopsPaused(loopsPaused) }
    }

    private func reuse<T: NSTableCellView>(_ type: T.Type, _ ov: NSOutlineView, id: String? = nil) -> T {
        let ident = NSUserInterfaceItemIdentifier(id ?? String(describing: type))
        if let v = ov.makeView(withIdentifier: ident, owner: self) as? T { return v }
        let v = T(frame: .zero)
        v.identifier = ident
        return v
    }

    /// Visible rows only, in place (renames, counts, badges, theme).
    private func reconfigureVisibleRows(animated: Bool) {
        outline.enumerateAvailableRowViews { [self] rv, row in
            guard let n = outline.item(atRow: row) as? SidebarNode else { return }
            if let srv = rv as? SidebarRowView {
                srv.node = n
                srv.kind = rowKind(n)
                srv.tone = tone(n)
                srv.companion = isCompanion(n)
            }
            configure((rv as? SidebarRowView)?.cellView, for: n, animated: animated)
        }
    }

    // MARK: Chrome: statusline, edge chips, fades

    private func refreshChrome(animated: Bool) {
        let c = manager.activityCounts
        bottomBar.update(.init(needsInput: c.needsInput, working: c.working, doneUnread: c.doneUnread, error: c.error,
                               total: c.total), animated: animated)
        refreshEdgeChips(animated: animated)
        updateFades()
    }

    /// The row of `n`, or of its nearest shown ancestor (a collapsed folder or section header).
    private func shownRow(_ n: SidebarNode) -> Int? {
        var current: SidebarNode? = n
        while let c = current {
            let r = outline.row(forItem: c)
            if r >= 0 { return r }
            current = parentOf[c.kind]
        }
        return nil
    }

    /// O(waiting · depth): waiting rows more than half outside the visible rect count as above / below.
    /// Rows hidden in a collapsed folder or section count once, through that row.
    func refreshEdgeChips(animated: Bool) {
        guard isViewLoaded else { return }
        let visible = outline.visibleRect
        var above = 0, below = 0
        var nearestAbove: Int?, nearestBelow: Int?
        if !visible.isEmpty {
            var seen = Set<Int>()
            for k in waiting {
                guard let n = nodes[k], let r = shownRow(n), seen.insert(r).inserted else { continue }
                let mid = outline.rect(ofRow: r).midY
                if mid < visible.minY {
                    above += 1
                    nearestAbove = max(nearestAbove ?? r, r)
                } else if mid > visible.maxY {
                    below += 1
                    nearestBelow = min(nearestBelow ?? r, r)
                }
            }
        }
        chipTargets = (nearestAbove, nearestBelow)
        topChip.update(count: above, animated: animated)
        bottomChip.update(count: below, animated: animated)
    }

    private func updateFades() {
        guard isViewLoaded else { return }
        let clip = scroll.contentView
        let insets = scroll.contentInsets
        let contentHeight = outline.numberOfRows > 0 ? outline.rect(ofRow: outline.numberOfRows - 1).maxY : 0
        let showTop = clip.bounds.height > 0 && clip.bounds.minY > -insets.top + 0.5
        let showBottom = clip.bounds.height > 0 && clip.bounds.maxY < contentHeight + insets.bottom - 0.5
        if topFade.isHidden == showTop { topFade.isHidden = !showTop }
        if bottomFade.isHidden == showBottom { bottomFade.isHidden = !showBottom }
    }

    @objc private func clipBoundsChanged() {
        updateFades()
        refreshEdgeChips(animated: true)
        outline.refreshHoverFromMouse()
    }

    /// Edge chip click: scroll the nearest waiting row into the middle, then select it like the keyboard
    /// would (focus stays where it is). A collapsed folder is selected; a collapsed section opens first.
    func revealWaiting(above: Bool) {
        refreshEdgeChips(animated: false)
        guard var row = above ? chipTargets.above : chipTargets.below,
              var n = outline.item(atRow: row) as? SidebarNode else { return }
        if n.isHeader {
            toggle(n, animated: false)
            guard let child = n.children.first(where: { waiting.contains($0.kind) }),
                  case let r = outline.row(forItem: child), r >= 0 else { return }
            (row, n) = (r, child)
        }
        scrollToCenter(row)
        revealing = true
        defer { revealing = false }
        switch n.kind {
        case .session(let id): manager.select(id, focus: false)
        case .background, .folder: outline.selectRowIndexes([row], byExtendingSelection: false)
        default: break
        }
        refreshEdgeChips(animated: true)
    }

    private func scrollToCenter(_ row: Int) {
        let clip = scroll.contentView
        let rect = outline.rect(ofRow: row)
        let insets = scroll.contentInsets
        let minY = -insets.top
        let maxY = max(minY, outline.frame.height + insets.bottom - clip.bounds.height)
        let target = NSPoint(x: clip.bounds.minX, y: min(max(rect.midY - clip.bounds.height / 2, minY), maxY))
        if Motion.full, SidebarFX.canAnimate(clip) {
            NSAnimationContext.runAnimationGroup({ ctx in
                ctx.duration = 0.25
                ctx.timingFunction = Motion.std
                clip.animator().setBoundsOrigin(target)
            }, completionHandler: { [weak self] in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.scroll.reflectScrolledClipView(self.scroll.contentView)
                }
            })
        } else {
            clip.setBoundsOrigin(target)
        }
        scroll.reflectScrolledClipView(clip)
    }

    func statusSegmentClicked(_ segment: SidebarStatusBar.Segment) {
        switch segment {
        case .needsInput: manager.selectNextAttention()
        case .working: manager.selectNext(activity: .working)
        case .done: manager.selectNext(activity: .done, unreadOnly: true)
        case .error: manager.selectNext(activity: .error)
        }
    }

    // MARK: Clock, theme, motion, loops

    private func clockTick() {
        guard let w = view.window, w.isVisible, w.occlusionState.contains(.visible) else { return }
        refreshClock(now: Date())
    }

    /// Ticks are skipped while occluded: catch up as soon as the window shows again.
    func occlusionChanged(visible: Bool) {
        if visible { refreshClock(now: Date()) }
    }

    /// Re-renders relative times in place (no reload).
    func refreshClock(now: Date) {
        outline.enumerateAvailableRowViews { rv, _ in ((rv as? SidebarRowView)?.cellView as? SidebarCell)?.refreshTime(now: now) }
    }

    @objc private func themeChanged() {
        topFade.refresh()
        bottomFade.refresh()
        reconfigureVisibleRows(animated: false)
        outline.refreshRowStates()
        bottomBar.applyTheme()
    }

    /// Reduce Motion toggled: folder badges switch between the L2 ping and the static halo.
    @objc private func motionChanged() { reconfigureVisibleRows(animated: false) }

    /// Window occluded / app hidden: remove loop animations on visible rows (icons and folder badges);
    /// resume re-adds them (phase sync keeps them aligned).
    func setLoopsPaused(_ paused: Bool) {
        let resumed = loopsPaused && !paused
        loopsPaused = paused
        outline.enumerateAvailableRowViews { rv, _ in ((rv as? SidebarRowView)?.cellView as? SidebarCell)?.setLoopsPaused(paused) }
        if resumed { refreshClock(now: Date()) }
    }

    // MARK: Command-key hints

    /// Local flagsChanged monitor: Session by Number's modifiers (⌘ unless customized), held in the key
    /// window, show its shortcuts on the rows after a short hold.
    func handleFlagsChanged(_ event: NSEvent) {
        let mods = event.modifierFlags.intersection([.command, .shift, .option, .control])
        let held = mods == Self.numberModifiers && (view.window?.isKeyWindow ?? false)
        hintWork?.cancel()
        hintWork = nil
        guard held, commandHints.isEmpty, Self.commandHintDelay > 0 else {
            setCommandHeld(held)
            return
        }
        let work = DispatchWorkItem { [weak self] in MainActor.assumeIsolated { self?.setCommandHeld(true) } }
        hintWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.commandHintDelay, execute: work)
    }

    /// What to hold for the number hints: Session by Number's modifiers (⌘ without a menu); nil when it
    /// has no shortcut.
    static var numberModifiers: NSEvent.ModifierFlags? {
        guard let item = KeyHint.item(for: ShortcutStore.numbered, tag: 1) else { return .command }
        return item.keyEquivalent.isEmpty ? nil : item.keyEquivalentModifierMask.intersection(KeyCombo.modifierMask)
    }

    /// Session by Number's shortcut for `n`, from the menu (it can be customized, or removed: nil).
    /// Without a menu (early start, tests) the built-in ⌘n.
    static func numberHint(_ n: Int) -> String? {
        guard let item = KeyHint.item(for: ShortcutStore.numbered, tag: n) else { return "⌘\(n)" }
        return item.keyEquivalent.isEmpty ? nil : KeyHint.format(item.keyEquivalent, item.keyEquivalentModifierMask)
    }

    /// Shortcuts were customized: tooltips and ⌘-hold hints read the menu again.
    func shortcutsChanged() {
        closeTip = Self.closeTooltip()
        outline.enumerateAvailableRowViews { [self] _, row in
            guard let cell = outline.view(atColumn: 0, row: row, makeIfNecessary: false) as? SessionRowView else { return }
            cell.closeButton.toolTip = closeTip
        }
        bottomBar.refreshTooltips()
    }

    /// Hints match `selectIndex`: the first 8 visible sessions get ⌘1…⌘8, the last one ⌘9.
    func setCommandHeld(_ held: Bool) {
        if !held {
            hintWork?.cancel()
            hintWork = nil
        }
        var map: [UUID: String] = [:]
        if held {
            let order = manager.workspace.visibleSessionsInOrder
            for (i, id) in order.prefix(8).enumerated() { map[id] = Self.numberHint(i + 1) }
            if order.count > 8, let last = order.last { map[last] = Self.numberHint(9) }
        }
        guard map != commandHints else { return }
        commandHints = map
        outline.enumerateAvailableRowViews { [self] _, row in
            guard let n = outline.item(atRow: row) as? SidebarNode, case .session(let id) = n.kind,
                  let cell = outline.view(atColumn: 0, row: row, makeIfNecessary: false) as? SessionRowView else { return }
            cell.setHint(commandHints[id], animated: true)
        }
    }

    // MARK: Selection & clicks

    func outlineViewSelectionDidChange(_ notification: Notification) {
        guard !syncingSelection, outline.selectedRow >= 0,
              let n = outline.item(atRow: outline.selectedRow) as? SidebarNode else { return }
        let byMouse = [.leftMouseDown, .leftMouseUp].contains(NSApp.currentEvent?.type)
        switch n.kind {
        case .session(let id):
            // Keyboard navigation keeps focus in the list; a click moves it to the terminal.
            manager.select(id, focus: byMouse && !revealing)
        case .closed(let id):
            delegate?.sidebarShowClosed(id)
        case .background(let job):
            if let a = manager.background.first(where: { $0.id == job }) { delegate?.sidebarShowBackground(a) }
        default:
            break
        }
    }

    /// Single click: section headers toggle anywhere on the row (§3.8).
    @objc func rowClicked() { handleClick(row: outline.clickedRow) }

    func handleClick(row: Int) {
        guard row >= 0, let n = outline.item(atRow: row) as? SidebarNode, n.isHeader else { return }
        toggle(n, animated: true)
    }

    /// User toggle (M9): animated expand/collapse; `restoreExpansion` never animates.
    func toggle(_ n: SidebarNode, animated: Bool) {
        let expand = !outline.isItemExpanded(n)
        if animated, Motion.full, SidebarFX.canAnimate(outline) {
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = Motion.base
                ctx.timingFunction = Motion.std
                if expand { outline.animator().expandItem(n) } else { outline.animator().collapseItem(n) }
            }
        } else if expand {
            outline.expandItem(n)
        } else {
            outline.collapseItem(n)
        }
    }

    @objc func disclosureClicked(_ sender: NSView) {
        let row = outline.row(for: sender)
        guard row >= 0, let n = outline.item(atRow: row) as? SidebarNode else { return }
        toggle(n, animated: true)
    }

    @objc func closeRowClicked(_ sender: NSView) {
        let row = outline.row(for: sender)
        guard row >= 0, let n = outline.item(atRow: row) as? SidebarNode, case .session(let id) = n.kind else { return }
        manager.requestClose(id)
    }

    @objc func reopenRowClicked(_ sender: NSView) {
        let row = outline.row(for: sender)
        guard row >= 0, let n = outline.item(atRow: row) as? SidebarNode, case .closed(let id) = n.kind else { return }
        manager.reopen(id)
    }

    @objc func doubleClicked() {
        guard outline.clickedRow >= 0, let n = outline.item(atRow: outline.clickedRow) as? SidebarNode else { return }
        switch n.kind {
        case .closed(let id): manager.reopen(id)
        case .background(let job):
            if let a = manager.background.first(where: { $0.id == job }) { manager.attach(a) }
        case .folder: toggle(n, animated: true)
        case .session(let id): promptRename(id)
        default: break
        }
    }

    func outlineViewItemDidExpand(_ notification: Notification) { expansionChanged(notification, expanded: true) }
    func outlineViewItemDidCollapse(_ notification: Notification) { expansionChanged(notification, expanded: false) }

    private func expansionChanged(_ notification: Notification, expanded: Bool) {
        guard let n = notification.userInfo?["NSObject"] as? SidebarNode else { return }
        switch n.kind {
        case .folder(let id): manager.setExpanded(id, expanded)
        case .closedHeader: UserDefaults.standard.set(expanded, forKey: "sidebar.closed.expanded")
        case .backgroundHeader: UserDefaults.standard.set(!expanded, forKey: "sidebar.background.collapsed")
        default: break
        }
        let row = outline.row(forItem: n)
        if row >= 0 { configure(outline.view(atColumn: 0, row: row, makeIfNecessary: false), for: n, animated: !restoring) }
        guard !restoring else { return }
        if !commandHints.isEmpty { setCommandHeld(true) }
        refreshEdgeChips(animated: true)
        updateFades()
    }

    // MARK: Drag and drop

    func outlineView(_ outlineView: NSOutlineView, pasteboardWriterForItem item: Any) -> NSPasteboardWriting? {
        guard let n = item as? SidebarNode else { return nil }
        let token: String
        switch n.kind {
        case .session(let id): token = "s:\(id.uuidString)"
        case .folder(let id): token = "f:\(id.uuidString)"
        case .closed(let id): token = "c:\(id.uuidString)"
        default: return nil
        }
        let pb = NSPasteboardItem()
        pb.setString(token, forType: Self.dragType)
        return pb
    }

    private func dragged(_ info: NSDraggingInfo) -> (kind: Character, id: UUID)? {
        guard let s = info.draggingPasteboard.pasteboardItems?.first?.string(forType: Self.dragType),
              let kind = s.first, let id = UUID(uuidString: String(s.dropFirst(2))) else { return nil }
        return (kind, id)
    }

    /// Resolves a proposed drop to (folder, index); nil when it's not a valid place.
    private func destination(item: Any?, index: Int) -> (folder: UUID?, index: Int?)? {
        let treeCount = manager.workspace.tree.count
        guard let n = item as? SidebarNode else {
            return (nil, index == NSOutlineViewDropOnItemIndex ? treeCount : min(index, treeCount))
        }
        switch n.kind {
        case .folder(let id):
            return (id, index == NSOutlineViewDropOnItemIndex ? nil : index)
        case .session(let id):
            guard let parent = manager.workspace.parent(of: id) else { return nil }
            let siblings = manager.workspace.children(of: parent)
            let i = siblings.firstIndex { $0.id == id }.map { $0 + 1 }
            return (parent, i)
        default:
            return nil
        }
    }

    func outlineView(_ outlineView: NSOutlineView, validateDrop info: NSDraggingInfo,
                     proposedItem item: Any?, proposedChildIndex index: Int) -> NSDragOperation {
        guard let drag = dragged(info), let dest = destination(item: item, index: index) else { return [] }
        if drag.kind == "f", let target = dest.folder {
            // No folder into itself or its descendants.
            var current: UUID? = target
            while let c = current {
                if c == drag.id { return [] }
                current = manager.workspace.parent(of: c) ?? nil
            }
        }
        // Retarget so the insertion line shows where the item really lands.
        let targetNode: SidebarNode? = dest.folder.flatMap { nodes[.folder($0)] }
        outlineView.setDropItem(targetNode, dropChildIndex: dest.index ?? NSOutlineViewDropOnItemIndex)
        return .move
    }

    func outlineView(_ outlineView: NSOutlineView, acceptDrop info: NSDraggingInfo, item: Any?, childIndex index: Int) -> Bool {
        guard let drag = dragged(info) else { return false }
        let dest: (folder: UUID?, index: Int?)
        if let n = item as? SidebarNode, case .folder(let id) = n.kind {
            dest = (id, index == NSOutlineViewDropOnItemIndex ? nil : index)
        } else if item == nil {
            dest = (nil, index == NSOutlineViewDropOnItemIndex ? nil : index)
        } else {
            return false
        }
        if drag.kind == "c" {
            manager.reopen(drag.id, folder: .some(dest.folder), at: dest.index)
            return true
        }
        return manager.move(drag.id, to: dest.folder, at: dest.index)
    }

    // MARK: Context menu

    func menuNeedsUpdate(_ menu: NSMenu) {
        let row = outline.clickedRow
        populate(menu, for: row >= 0 ? outline.item(atRow: row) as? SidebarNode : nil)
    }

    /// Context menu for a row (nil = empty area).
    func populate(_ menu: NSMenu, for node: SidebarNode?) {
        menu.removeAllItems()
        guard let n = node else {
            menu.addItem(chainItem("New Shell", #selector(MainWindowController.newShell(_:))))
            menu.addItem(item("New Folder", #selector(newFolderAtRoot), represented: nil))
            return
        }
        switch n.kind {
        case .session(let id):
            menu.addItem(item("Rename…", #selector(renameClicked(_:)), represented: id))
            menu.addItem(moveToFolderItem(id))
            menu.addItem(item("Reveal Directory in Finder", #selector(revealClicked(_:)), represented: id))
            if let cmd = manager.workspace.sessions[id]?.reopenInput {
                menu.addItem(item("Copy Resume Command", #selector(copyCommand(_:)), represented: cmd))
            }
            if let sel = manager.workspace.selected, sel != id, manager.live[sel] != nil, manager.live[id] != nil,
               !manager.sideBySide(sel).contains(id) {
                menu.addItem(item("Show Side by Side", #selector(sideBySideClicked(_:)), represented: id))
            }
            if manager.sideBySide(id).count > 1 {
                menu.addItem(item("Show Separately", #selector(separatelyClicked(_:)), represented: id))
            }
            menu.addItem(.separator())
            menu.addItem(item("Close Session", #selector(closeClicked(_:)), represented: id))
        case .folder(let id):
            menu.addItem(item("New Shell Here", #selector(newShellInFolder(_:)), represented: id))
            menu.addItem(item("New Claude Session Here", #selector(newClaudeInFolder(_:)), represented: id))
            menu.addItem(item("New Subfolder", #selector(newSubfolder(_:)), represented: id))
            menu.addItem(.separator())
            menu.addItem(item("Rename…", #selector(renameClicked(_:)), represented: id))
            menu.addItem(item("Set Default Directory…", #selector(setFolderDirectory(_:)), represented: id))
            menu.addItem(defaultFolderItem(id))
            if manager.workspace.folders[id]?.directory != nil {
                menu.addItem(item("Clear Default Directory", #selector(clearFolderDirectory(_:)), represented: id))
            }
            menu.addItem(.separator())
            menu.addItem(item("Delete Folder (keep sessions)", #selector(deleteFolderClicked(_:)), represented: id))
        case .closed(let id):
            menu.addItem(item("Reopen", #selector(reopenClicked(_:)), represented: id))
            if let cmd = manager.workspace.sessions[id]?.reopenInput {
                menu.addItem(item("Copy Resume Command", #selector(copyCommand(_:)), represented: cmd))
            }
            menu.addItem(item("Remove from List", #selector(forgetClicked(_:)), represented: id))
        case .closedHeader:
            menu.addItem(item("Remove All Closed from List…", #selector(forgetAllClosed), represented: nil))
        case .background(let job):
            menu.addItem(item("Attach in New Session", #selector(attachClicked(_:)), represented: job))
        case .backgroundHeader:
            menu.addItem(item("Refresh", #selector(refreshBackground), represented: nil))
        }
    }

    private func item(_ title: String, _ action: Selector, represented: Any? = nil) -> NSMenuItem {
        let mi = NSMenuItem(title: title, action: action, keyEquivalent: "")
        mi.target = self
        mi.representedObject = represented
        return mi
    }

    /// Menu item dispatched through the responder chain (window controller actions).
    private func chainItem(_ title: String, _ action: Selector) -> NSMenuItem {
        NSMenuItem(title: title, action: action, keyEquivalent: "")
    }

    /// "New Claude sessions go here" toggles per agent kind.
    private func defaultFolderItem(_ id: UUID) -> NSMenuItem {
        let mi = NSMenuItem(title: "Default Folder for New", action: nil, keyEquivalent: "")
        let sub = NSMenu()
        for agent in AgentKind.allCases {
            let entry = item(agent == .shell ? "Shells" : "\(agent.displayName) Sessions", #selector(toggleDefaultFolder(_:)),
                             represented: [id, agent.rawValue] as [Any])
            entry.state = manager.workspace.defaults(for: agent).folder == id ? .on : .off
            sub.addItem(entry)
        }
        mi.submenu = sub
        return mi
    }

    @objc func toggleDefaultFolder(_ sender: NSMenuItem) {
        guard let pair = sender.representedObject as? [Any], let id = pair[0] as? UUID,
              let raw = pair[1] as? String, let agent = AgentKind(rawValue: raw) else { return }
        var d = manager.workspace.defaults(for: agent)
        d.folder = d.folder == id ? nil : id
        manager.setAgentDefaults(d, for: agent)
    }

    private func moveToFolderItem(_ id: UUID) -> NSMenuItem {
        let mi = NSMenuItem(title: "Move to Folder", action: nil, keyEquivalent: "")
        let sub = NSMenu()
        let top = item("Top Level", #selector(moveToFolder(_:)), represented: [id, Optional<UUID>.none] as [Any?])
        sub.addItem(top)
        sub.addItem(.separator())
        for f in manager.workspace.folders.values.sorted(by: { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }) {
            sub.addItem(item(f.name, #selector(moveToFolder(_:)), represented: [id, f.id] as [Any?]))
        }
        sub.addItem(.separator())
        sub.addItem(item("New Folder…", #selector(moveToNewFolder(_:)), represented: id))
        mi.submenu = sub
        return mi
    }

    @objc func renameClicked(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? UUID else { return }
        promptRename(id)
    }

    func promptRename(_ id: UUID) {
        let ws = manager.workspace
        let current = ws.folders[id]?.name ?? ws.sessions[id].map { r in displayTitle(r, manager.status(id) ?? LiveStatus()) } ?? ""
        prompt(title: ws.folders[id] != nil ? "Rename Folder" : "Rename Session", value: current) { [weak self] name in
            self?.manager.rename(id, to: name)
        }
    }

    private func prompt(title: String, value: String, completion: @escaping (String) -> Void) {
        let alert = NSAlert()
        alert.messageText = title
        let field = NSTextField(string: value)
        field.frame = NSRect(x: 0, y: 0, width: 280, height: 24)
        alert.accessoryView = field
        alert.addButton(withTitle: "OK")
        alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = field
        Presenter.alert(alert, view.window) { response in
            if response == .alertFirstButtonReturn { completion(field.stringValue) }
        }
    }

    @objc func moveToFolder(_ sender: NSMenuItem) {
        guard let pair = sender.representedObject as? [Any?], let id = pair[0] as? UUID else { return }
        manager.move(id, to: pair[1] as? UUID, at: nil)
    }

    @objc func moveToNewFolder(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? UUID else { return }
        prompt(title: "New Folder", value: "New Folder") { [weak self] name in
            guard let self else { return }
            let folder = self.manager.newFolder(name: name)
            self.manager.move(id, to: folder, at: nil)
        }
    }

    @objc func revealClicked(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? UUID else { return }
        let dir = manager.status(id)?.cwd ?? manager.workspace.sessions[id]?.cwd ?? NSHomeDirectory()
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: dir)])
    }

    @objc func copyCommand(_ sender: NSMenuItem) {
        guard let cmd = sender.representedObject as? String else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(cmd, forType: .string)
    }

    /// Next to the selected session, on the right of what has focus there.
    @objc func sideBySideClicked(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? UUID, let sel = manager.workspace.selected else { return }
        manager.showBeside(id, of: sel)
    }

    @objc func separatelyClicked(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? UUID else { return }
        manager.showSeparately(id)
    }

    @objc func closeClicked(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? UUID else { return }
        manager.requestClose(id)
    }

    @objc func reopenClicked(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? UUID else { return }
        manager.reopen(id)
    }

    @objc func forgetClicked(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? UUID else { return }
        manager.forget(id)
    }

    @objc func forgetAllClosed() {
        let alert = NSAlert()
        alert.messageText = "Remove all closed sessions from the list?"
        alert.informativeText = "Agent transcripts stay on disk and in search."
        alert.addButton(withTitle: "Remove")
        alert.addButton(withTitle: "Cancel")
        Presenter.alert(alert, view.window) { [weak self] r in
            if r == .alertFirstButtonReturn { self?.manager.forgetAllClosed() }
        }
    }

    @objc func attachClicked(_ sender: NSMenuItem) {
        guard let job = sender.representedObject as? String,
              let a = manager.background.first(where: { $0.id == job }) else { return }
        manager.attach(a)
    }

    @objc func refreshBackground() { manager.reloadBackground() }

    @objc func newFolderAtRoot() {
        prompt(title: "New Folder", value: "New Folder") { [weak self] name in self?.manager.newFolder(name: name) }
    }

    @objc func newSubfolder(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? UUID else { return }
        prompt(title: "New Folder", value: "New Folder") { [weak self] name in self?.manager.newFolder(name: name, in: id) }
    }

    @objc func newShellInFolder(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? UUID else { return }
        manager.newSession(agent: .shell, folder: .some(id))
    }

    @objc func newClaudeInFolder(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? UUID else { return }
        manager.newSession(agent: .claude, folder: .some(id))
    }

    @objc func setFolderDirectory(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? UUID else { return }
        Presenter.chooseDirectory(start: manager.workspace.folders[id]?.directory, prompt: "Use for Folder",
                                  window: view.window) { [weak self] url in
            if let url { self?.manager.setFolderDirectory(id, url.path) }
        }
    }

    @objc func clearFolderDirectory(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? UUID else { return }
        manager.setFolderDirectory(id, nil)
    }

    @objc func deleteFolderClicked(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? UUID else { return }
        manager.deleteFolder(id)
    }

    /// Folder of the current selection, used by "New Folder" and new sessions.
    var selectedFolder: UUID? {
        guard outline.selectedRow >= 0, let n = outline.item(atRow: outline.selectedRow) as? SidebarNode else { return nil }
        if case .folder(let id) = n.kind { return id }
        return nil
    }

    func focus() { view.window?.makeFirstResponder(outline) }
}
