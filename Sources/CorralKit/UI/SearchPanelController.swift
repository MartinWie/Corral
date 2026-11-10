import AppKit
import CorralCore

/// Where a search hit lives relative to Corral: decides the tag, the scope and what Enter does.
enum SearchPlace: Equatable {
    case open, closed, outside

    /// Footer label for Enter on this hit.
    var action: String {
        switch self {
        case .open: return "Focus session"
        case .closed: return "Reopen session"
        case .outside: return "Resume in new session"
        }
    }
}

extension NSAttributedString.Key {
    /// Marks matched terms in search snippets; `SnippetView` draws the accent wash behind them.
    static let searchMatch = NSAttributedString.Key("CorralSearchMatch")
}

/// ⌘K: full-text search over every Claude/OpenCode/PI transcript and closed shell scrollback.
/// Enter focuses an open session, reopens a closed one, or resumes the transcript in a new session.
/// Only present/dismiss (M25/M26) and the scope glide (M27) animate; typing, results and ↑↓ never do (M28).
final class SearchPanelController: NSWindowController, NSTextFieldDelegate, NSTableViewDataSource, NSTableViewDelegate,
    NSWindowDelegate {
    static let size = NSSize(width: 680, height: 460)
    static let headerHeight: CGFloat = 52
    static let scopeHeight: CGFloat = 36
    static let footerHeight: CGFloat = 30
    /// "Searching…" shows only when a query takes longer than this, so fast keystrokes never flicker.
    static var searchingDelay = 0.12

    let manager: SessionManager
    let surface = PanelSurfaceView()
    let field = NSTextField()
    let filter = ScopeChips(labels: ["All", "Open", "Closed", "Not in Corral"])
    let table = SearchResultsTable()
    let status = NSTextField(labelWithString: "")
    let clearButton = ClearButton()
    let escKey = KeyCap(KeyHint.format("\u{1b}", []), surface: .elevated)
    let footerKey = KeyCap(KeyHint.format("\r", []), surface: .elevated)
    let footerAction = NSTextField(labelWithString: "")
    let emptyView = NSStackView()
    let emptyTitle = NSTextField(labelWithString: "")
    let emptyHint = NSTextField(labelWithString: "")
    private let searchGlyph = GlyphView(frame: NSRect(x: 0, y: 0, width: 20, height: 20))
    private let emptyGlyph = GlyphView(frame: NSRect(x: 0, y: 0, width: 40, height: 36))
    private let scroll = NSScrollView()
    /// → on a result: its details and matching messages, in place of the list (← / esc back).
    let preview = SearchPreviewView()
    private(set) var previewShown = false
    private var previewGeneration = 0
    private let headerRule = HairlineView()
    private let footerRule = HairlineView()
    private(set) var footerKeys: [KeyCap] = []
    private(set) var footerLabels: [NSTextField] = []

    var hits: [SearchHit] = []
    private(set) var shown: [SearchHit] = []
    private(set) var shownPlaces: [SearchPlace] = []
    private var generation = 0
    private var pending: DispatchWorkItem?
    private var searching: DispatchWorkItem?
    /// Bumped by every present, dismiss and open, so a stale fade-out never orders out a re-presented panel.
    private(set) var presentation = 0
    private(set) var staggerPending = false
    private var presentedAt: CFTimeInterval = 0
    /// True once a result set has been applied (the empty state never shows before the first answer).
    private(set) var searched = false

    init(manager: SessionManager) {
        self.manager = manager
        let panel = SearchPanel(contentRect: NSRect(origin: .zero, size: Self.size),
                                styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        panel.title = "Search Sessions"
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = true
        panel.isMovableByWindowBackground = true
        panel.becomesKeyOnlyIfNeeded = false
        panel.animationBehavior = .none
        panel.collectionBehavior = [.fullScreenAuxiliary, .moveToActiveSpace]
        super.init(window: panel)
        panel.delegate = self
        panel.onCancel = { [weak self] in self?.cancel() }
        panel.queryField = field
        buildUI()
        applyTheme()
        NotificationCenter.default.addObserver(self, selector: #selector(themeChanged), name: .corralThemeDidChange, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(scrolled), name: NSView.boundsDidChangeNotification,
                                               object: scroll.contentView)
    }

    required init?(coder: NSCoder) { fatalError() }

    deinit { NotificationCenter.default.removeObserver(self) }

    // MARK: Building

    private func buildUI() {
        guard let panel = window else { return }
        panel.contentView = surface
        panel.initialFirstResponder = field

        searchGlyph.symbol = "magnifyingglass"
        searchGlyph.size = 15
        searchGlyph.weight = .regular
        searchGlyph.layerContentsPlacement = .center

        field.isBordered = false
        field.isBezeled = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.isEditable = true
        field.isSelectable = true
        field.font = Fonts.query
        field.cell?.usesSingleLineMode = true
        field.cell?.wraps = false
        field.cell?.isScrollable = true
        field.delegate = self
        field.setAccessibilityLabel("Search sessions")
        field.setContentHuggingPriority(.defaultLow, for: .horizontal)
        field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        clearButton.target = self
        clearButton.action = #selector(clearQuery)
        clearButton.isHidden = true

        filter.target = self
        filter.action = #selector(filterChanged)
        filter.setAccessibilityLabel("Scope")
        status.font = Fonts.statusline
        status.alignment = .right
        status.setContentCompressionResistancePriority(.required, for: .horizontal)

        let column = NSTableColumn(identifier: .init("hit"))
        column.resizingMask = .autoresizingMask
        column.width = Self.size.width - 16
        table.addTableColumn(column)
        table.headerView = nil
        table.style = .plain
        table.backgroundColor = .clear
        table.gridStyleMask = []
        table.intercellSpacing = NSSize(width: 0, height: 2)
        table.usesAutomaticRowHeights = false
        table.rowSizeStyle = .custom
        table.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle
        table.selectionHighlightStyle = .none   // SearchRowView draws the pill; AppKit's own highlight stays off
        table.focusRingType = .none
        table.refusesFirstResponder = true
        table.allowsEmptySelection = true
        table.dataSource = self
        table.delegate = self
        table.target = self
        table.doubleAction = #selector(openSelected)
        table.setAccessibilityLabel("Results")
        scroll.documentView = table
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.scrollerStyle = .overlay
        scroll.automaticallyAdjustsContentInsets = false
        scroll.contentInsets = NSEdgeInsets(top: 4, left: 0, bottom: 8, right: 0)
        scroll.contentView.postsBoundsChangedNotifications = true

        emptyGlyph.symbol = "text.magnifyingglass"
        emptyGlyph.size = 28
        emptyGlyph.weight = .regular
        emptyGlyph.layerContentsPlacement = .center
        emptyTitle.font = Fonts.pageBody
        emptyTitle.lineBreakMode = .byTruncatingMiddle
        emptyTitle.alignment = .center
        emptyHint.font = Fonts.caption
        emptyHint.alignment = .center
        emptyView.orientation = .vertical
        emptyView.alignment = .centerX
        emptyView.spacing = 4
        for v in [emptyGlyph, emptyTitle, emptyHint] { emptyView.addArrangedSubview(v) }
        emptyView.setCustomSpacing(10, after: emptyGlyph)
        emptyView.isHidden = true

        footerAction.font = Fonts.captionMedium
        footerKey.isHidden = true
        let hints = NSStackView()
        hints.orientation = .horizontal
        hints.spacing = 5
        // "tab" is spelled out like "esc": the ⇥ glyph is ~5 pt wide in mono 10.5 and barely legible.
        for (key, text) in [("→", "Details"), ("↑↓", "Navigate"), ("tab", "Scope"), (KeyHint.format("\u{1b}", []), "Close")] {
            let cap = KeyCap(key, surface: .elevated)
            let label = NSTextField(labelWithString: text)
            label.font = Fonts.caption
            footerKeys.append(cap)
            footerLabels.append(label)
            hints.addArrangedSubview(cap)
            hints.addArrangedSubview(label)
            if text != "Close" { hints.setCustomSpacing(14, after: label) }
        }

        preview.isHidden = true
        for v: NSView in [searchGlyph, field, clearButton, escKey, headerRule, filter, status, scroll, preview, emptyView,
                          footerRule, footerKey, footerAction, hints] {
            v.translatesAutoresizingMaskIntoConstraints = false
            surface.addSubview(v)
        }
        let header = Self.headerHeight / 2
        let scopeMid = Self.headerHeight + 1 + Self.scopeHeight / 2
        let footerMid = Self.footerHeight / 2
        NSLayoutConstraint.activate([
            searchGlyph.leadingAnchor.constraint(equalTo: surface.leadingAnchor, constant: 16),
            searchGlyph.centerYAnchor.constraint(equalTo: surface.topAnchor, constant: header),
            searchGlyph.widthAnchor.constraint(equalToConstant: 20),
            searchGlyph.heightAnchor.constraint(equalToConstant: 20),
            // 6 + the glyph frame's 2.5 pt padding + the field's text inset ≈ the 10 pt gap of §3.15.
            field.leadingAnchor.constraint(equalTo: searchGlyph.trailingAnchor, constant: 6),
            field.centerYAnchor.constraint(equalTo: surface.topAnchor, constant: header),
            field.trailingAnchor.constraint(equalTo: clearButton.leadingAnchor, constant: -8),
            clearButton.centerYAnchor.constraint(equalTo: surface.topAnchor, constant: header),
            clearButton.trailingAnchor.constraint(equalTo: escKey.leadingAnchor, constant: -10),
            escKey.centerYAnchor.constraint(equalTo: surface.topAnchor, constant: header),
            escKey.trailingAnchor.constraint(equalTo: surface.trailingAnchor, constant: -16),

            headerRule.topAnchor.constraint(equalTo: surface.topAnchor, constant: Self.headerHeight),
            headerRule.leadingAnchor.constraint(equalTo: surface.leadingAnchor),
            headerRule.trailingAnchor.constraint(equalTo: surface.trailingAnchor),
            headerRule.heightAnchor.constraint(equalToConstant: 1),

            filter.leadingAnchor.constraint(equalTo: surface.leadingAnchor, constant: 14),
            filter.centerYAnchor.constraint(equalTo: surface.topAnchor, constant: scopeMid),
            status.trailingAnchor.constraint(equalTo: surface.trailingAnchor, constant: -16),
            status.centerYAnchor.constraint(equalTo: surface.topAnchor, constant: scopeMid),
            status.leadingAnchor.constraint(greaterThanOrEqualTo: filter.trailingAnchor, constant: 12),

            scroll.topAnchor.constraint(equalTo: surface.topAnchor, constant: Self.headerHeight + 1 + Self.scopeHeight),
            scroll.leadingAnchor.constraint(equalTo: surface.leadingAnchor, constant: 8),
            scroll.trailingAnchor.constraint(equalTo: surface.trailingAnchor, constant: -8),
            scroll.bottomAnchor.constraint(equalTo: footerRule.topAnchor),
            preview.topAnchor.constraint(equalTo: scroll.topAnchor),
            preview.leadingAnchor.constraint(equalTo: scroll.leadingAnchor),
            preview.trailingAnchor.constraint(equalTo: scroll.trailingAnchor),
            preview.bottomAnchor.constraint(equalTo: scroll.bottomAnchor),

            emptyView.centerXAnchor.constraint(equalTo: scroll.centerXAnchor),
            emptyView.centerYAnchor.constraint(equalTo: scroll.centerYAnchor, constant: -8),
            emptyView.widthAnchor.constraint(lessThanOrEqualToConstant: 440),
            emptyTitle.widthAnchor.constraint(lessThanOrEqualToConstant: 440),
            emptyGlyph.widthAnchor.constraint(equalToConstant: 40),
            emptyGlyph.heightAnchor.constraint(equalToConstant: 36),

            footerRule.bottomAnchor.constraint(equalTo: surface.bottomAnchor, constant: -Self.footerHeight),
            footerRule.leadingAnchor.constraint(equalTo: surface.leadingAnchor),
            footerRule.trailingAnchor.constraint(equalTo: surface.trailingAnchor),
            footerRule.heightAnchor.constraint(equalToConstant: 1),
            footerKey.leadingAnchor.constraint(equalTo: surface.leadingAnchor, constant: 16),
            footerKey.centerYAnchor.constraint(equalTo: surface.bottomAnchor, constant: -footerMid),
            footerAction.leadingAnchor.constraint(equalTo: footerKey.trailingAnchor, constant: 6),
            footerAction.centerYAnchor.constraint(equalTo: surface.bottomAnchor, constant: -footerMid),
            hints.trailingAnchor.constraint(equalTo: surface.trailingAnchor, constant: -16),
            hints.centerYAnchor.constraint(equalTo: surface.bottomAnchor, constant: -footerMid),
            hints.leadingAnchor.constraint(greaterThanOrEqualTo: footerAction.trailingAnchor, constant: 16),
        ])
    }

    // MARK: Theme

    @objc private func themeChanged() { MainActor.assumeIsolated { applyTheme() } }

    func applyTheme() {
        let t = Theme.tokens
        let r = t.ramp(.elevated)
        window?.appearance = t.chromeAppearance
        surface.needsDisplay = true
        headerRule.needsDisplay = true
        footerRule.needsDisplay = true
        searchGlyph.color = r.secondary
        emptyGlyph.color = r.tertiary
        field.textColor = r.primary
        field.placeholderAttributedString = NSAttributedString(
            string: "Search sessions, prompts, commands…", attributes: [.font: Fonts.query, .foregroundColor: r.tertiary])
        status.textColor = r.tertiary
        emptyTitle.textColor = r.secondary
        emptyHint.textColor = r.tertiary
        footerAction.textColor = r.secondary
        for label in footerLabels { label.textColor = r.tertiary }
        filter.refreshColors()
        clearButton.refresh()
        styleFieldEditor()
        if searched {
            let selected = table.selectedRow
            table.reloadData()
            if selected >= 0, selected < shown.count { table.selectRowIndexes([selected], byExtendingSelection: false) }
            table.enumerateAvailableRowViews { rowView, _ in rowView.needsDisplay = true }
        }
        refreshShadow()
    }

    /// Caret and selection in the hue-guarded accent: the raw system accent may be amber (principle 2).
    func styleFieldEditor() {
        guard let editor = window?.fieldEditor(false, for: field) as? NSTextView else { return }
        let t = Theme.tokens
        editor.insertionPointColor = t.accent
        editor.selectedTextAttributes = [.backgroundColor: t.accent.withAlphaComponent(t.isChromeDark ? 0.30 : 0.22),
                                         .foregroundColor: t.ramp(.elevated).primary]
    }

    /// The window server derives the shadow from what the surface drew: lay out, draw and commit the
    /// layers first (a window-level displayIfNeeded leaves layer-backed views to the next commit), then recompute.
    func refreshShadow() {
        guard let panel = window, panel.isVisible else { return }
        surface.layoutSubtreeIfNeeded()
        surface.displayIfNeeded()
        CATransaction.flush()
        panel.invalidateShadow()
    }

    // MARK: Present / dismiss

    func present(over parent: NSWindow?) {
        guard let panel = window else { return }
        let fresh = !panel.isVisible
        invalidatePendingDismiss()
        panel.appearance = Theme.tokens.chromeAppearance
        if fresh {
            if previewShown { hidePreview() }
            panel.setFrameOrigin(Self.origin(size: panel.frame.size, parent: parent?.frame,
                                             screen: (parent?.screen ?? NSScreen.main)?.visibleFrame))
            if Motion.enabled { panel.alphaValue = 0 }
            prepareFreshPresent()
        }
        panel.makeKeyAndOrderFront(nil)
        panel.makeFirstResponder(field)
        styleFieldEditor()
        field.selectText(nil)
        updateClearButton()
        if fresh { refreshShadow() }
        animateIn(fresh: fresh)
        runQuery()
    }

    /// Before the first frame of a fresh present: live place tags and relative times (sessions may have
    /// opened or closed while the panel was down), selection back on the first row.
    func prepareFreshPresent() {
        guard searched else { return }
        applyFilter()
        guard !shown.isEmpty else { return }
        table.selectRowIndexes([0], byExtendingSelection: false)
        table.scrollRowToVisible(0)
    }

    /// M25: window alpha (0.14 out) plus a presentation-only scale/drop of the surface; the first rows
    /// stagger in when the first results land. Reduce Motion: alpha only, 0.10.
    func animateIn(fresh: Bool) {
        guard let panel = window else { return }
        guard Motion.enabled else {
            panel.alphaValue = 1
            return
        }
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = Motion.full ? 0.14 : 0.10
            ctx.timingFunction = Motion.out
            panel.animator().alphaValue = 1
        }
        guard fresh, Motion.full, let layer = surface.layer else { return }
        // The shadow was computed for the settled shape; recompute once the spring has landed.
        CATransaction.begin()
        CATransaction.setCompletionBlock { [weak self] in
            MainActor.assumeIsolated { self?.refreshShadow() }
        }
        layer.add(Self.presentTransform(for: layer), forKey: "present.transform")
        CATransaction.commit()
        staggerPending = true
        presentedAt = CACurrentMediaTime()
    }

    /// Scale 0.98 → 1 about the visual center and y +6 → 0 (it settles downward), snappy spring.
    static func presentTransform(for layer: CALayer) -> CAAnimation {
        let b = layer.bounds
        let cx = b.midX - layer.anchorPoint.x * b.width
        let cy = b.midY - layer.anchorPoint.y * b.height
        var m = CATransform3DMakeTranslation(cx, cy + 6, 0)
        m = CATransform3DScale(m, 0.98, 0.98, 1)
        m = CATransform3DTranslate(m, -cx, -cy, 0)
        return Motion.spring("transform", from: NSValue(caTransform3D: m), to: NSValue(caTransform3D: CATransform3DIdentity))
    }

    /// First ≤ 6 rows: opacity + y −4 → 0 (drop-in), 18 ms apart. Presentation only.
    func staggerRows() {
        let visible = table.rows(in: table.visibleRect)
        for i in 0..<min(6, shown.count) where NSLocationInRange(i, visible) {
            guard let layer = table.rowView(atRow: i, makeIfNecessary: true)?.layer else { continue }
            let delay = Double(i) * 0.018
            layer.add(Motion.basic("opacity", from: 0, to: 1, duration: 0.2, timing: Motion.out, delay: delay), forKey: "present.fade")
            layer.add(Motion.basic("transform.translation.y", from: -4, to: 0, duration: 0.22, timing: Motion.out, delay: delay),
                      forKey: "present.rise")
        }
    }

    func runStaggerIfPending() {
        guard staggerPending else { return }
        staggerPending = false
        guard Motion.full, CACurrentMediaTime() - presentedAt < 0.35 else { return }
        staggerRows()
    }

    /// M26: alpha → 0 (0.10 exit), then orderOut, unless the panel was presented again meanwhile.
    func dismiss(animated: Bool) {
        guard let panel = window else { return }
        // Already hidden by app deactivation (hidesOnDeactivate): order out so reactivation keeps it down.
        guard panel.isVisible else { return panel.orderOut(nil) }
        invalidatePendingDismiss()
        let gen = presentation
        pending?.cancel()
        staggerPending = false
        guard animated, Motion.enabled else {
            panel.orderOut(nil)
            panel.alphaValue = 1
            return
        }
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.10
            ctx.timingFunction = Motion.exit
            panel.animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            MainActor.assumeIsolated { self?.finishDismiss(gen) }
        })
        // Core Animation stalls while the display sleeps, and the completion never comes: finish anyway.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in
            MainActor.assumeIsolated { self?.finishDismiss(gen) }
        }
    }

    /// Ends a fade-out unless the panel was presented again since (or it already ended).
    private func finishDismiss(_ gen: Int) {
        guard let panel = window, gen == presentation, panel.isVisible else { return }
        panel.orderOut(nil)
        panel.alphaValue = 1
    }

    /// Cancels a fade-out in flight: its completion sees a newer presentation and leaves the panel up.
    func invalidatePendingDismiss() { presentation += 1 }

    /// Centered on the parent, top edge 112 pt below the parent's top, kept on screen.
    static func origin(size: NSSize, parent: NSRect?, screen: NSRect?) -> NSPoint {
        var x: CGFloat, y: CGFloat
        if let parent {
            x = parent.midX - size.width / 2
            y = parent.maxY - 112 - size.height
        } else {
            let s = screen ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
            x = s.midX - size.width / 2
            y = s.maxY - s.height * 0.18 - size.height
        }
        if let s = screen {
            x = min(max(x, s.minX + 8), s.maxX - size.width - 8)
            y = min(max(y, s.minY + 8), s.maxY - size.height - 8)
        }
        return NSPoint(x: x.rounded(), y: y.rounded())
    }

    func windowDidResignKey(_ notification: Notification) { dismiss(animated: true) }

    // MARK: Query

    func controlTextDidChange(_ obj: Notification) {
        updateClearButton()
        queryChanged()
    }

    @objc func queryChanged() {
        pending?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.runQuery() }
        pending = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12, execute: work)
    }

    @objc func clearQuery() {
        field.stringValue = ""
        updateClearButton()
        window?.makeFirstResponder(field)
        pending?.cancel()
        runQuery()
    }

    @objc func filterChanged() { applyFilter() }

    func runQuery() {
        generation += 1
        let gen = generation
        let q = field.stringValue
        searching?.cancel()
        let slow = DispatchWorkItem { [weak self] in
            guard let self, gen == self.generation else { return }
            self.status.stringValue = "Searching…"
        }
        searching = slow
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.searchingDelay, execute: slow)
        manager.index.search(q, limit: 80) { [weak self] hits in
            guard let self, gen == self.generation else { return }
            self.searching?.cancel()
            self.hits = hits
            self.applyFilter()
            self.runStaggerIfPending()
        }
    }

    private struct AgentKey: Hashable {
        let agent: AgentKind
        let id: String
    }

    /// Agent transcript → its place in Corral (open wins over closed), one pass over the sessions per filter.
    private func agentPlaces() -> [AgentKey: SearchPlace] {
        var out: [AgentKey: SearchPlace] = [:]
        for r in manager.workspace.sessions.values {
            guard let id = r.agentSessionId else { continue }
            let key = AgentKey(agent: r.agent, id: id)
            if r.closedAt == nil { out[key] = .open } else if out[key] == nil { out[key] = .closed }
        }
        return out
    }

    func applyFilter() {
        let scope = filter.selectedSegment
        let sessions = manager.workspace.sessions
        var byAgent: [AgentKey: SearchPlace]?
        var keep: [SearchHit] = []
        var places: [SearchPlace] = []
        for hit in hits {
            let p: SearchPlace
            if let id = hit.corralSessionId, let r = sessions[id] {
                p = r.closedAt == nil ? .open : .closed
            } else {
                if byAgent == nil { byAgent = agentPlaces() }
                p = byAgent?[AgentKey(agent: hit.agent, id: hit.sessionId)] ?? .outside
            }
            let ok: Bool
            switch scope {
            case 1: ok = p == .open
            case 2: ok = p == .closed
            case 3: ok = p == .outside
            default: ok = true
            }
            if ok {
                keep.append(hit)
                places.append(p)
            }
        }
        if searched, keep == shown, places == shownPlaces {
            // Same rows: keep rows, selection and any entrance in flight; refresh relative times in place.
            let now = Date()
            table.enumerateAvailableRowViews { rowView, row in
                guard row < shown.count else { return }
                (rowView.view(atColumn: 0) as? SearchHitCell)?.configure(shown[row], place: shownPlaces[row], now: now)
            }
            updateChrome()
            return
        }
        // Details open: they follow their session if the new results still have it (→ right after
        // typing), else the list comes back. Decided before the reload so no stale load is queued.
        let keepRow = previewShown ? keep.firstIndex { $0.key == preview.hitKey } : nil
        let dropPreview = previewShown && keepRow == nil
        if dropPreview {
            previewShown = false
            previewGeneration += 1
        }
        shown = keep
        shownPlaces = places
        searched = true
        table.reloadData()
        if !shown.isEmpty {
            let row = keepRow ?? 0
            table.selectRowIndexes([row], byExtendingSelection: false)
            table.scrollRowToVisible(row)
        }
        // Back to the list after the reload, so it never lays out stale rows.
        if dropPreview {
            preview.isHidden = true
            scroll.isHidden = false
        }
        updateChrome()
    }

    private var trimmedQuery: String { field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines) }

    /// Status, empty state, clear button and footer for the current results.
    private func updateChrome() {
        updateClearButton()
        let q = trimmedQuery
        let n = shown.count
        status.stringValue = q.isEmpty ? "Recent sessions" : (n == 1 ? "1 session" : "\(n) sessions")
        emptyView.isHidden = !searched || n > 0
        if n == 0 {
            if q.isEmpty, filter.selectedSegment != 0, !hits.isEmpty {
                // Recents exist, just not in this scope.
                switch filter.selectedSegment {
                case 1: emptyTitle.stringValue = "No recent open sessions"
                case 2: emptyTitle.stringValue = "No recent closed sessions"
                default: emptyTitle.stringValue = "No recent sessions outside Corral"
                }
                emptyHint.stringValue = "Try All · \(hits.count) \(hits.count == 1 ? "session" : "sessions")"
            } else if q.isEmpty {
                emptyTitle.stringValue = "No recent sessions"
                emptyHint.stringValue = "Sessions you run show up here"
            } else {
                emptyTitle.stringValue = "No matches for “\(q)”"
                let elsewhere = hits.count
                emptyHint.stringValue = filter.selectedSegment != 0 && elsewhere > 0
                    ? "Try All · \(elsewhere) \(elsewhere == 1 ? "match" : "matches")"
                    : "Try fewer or different words"
            }
        }
        updateFooter()
    }

    private func updateFooter() {
        let row = table.selectedRow
        let has = row >= 0 && row < shownPlaces.count
        footerAction.stringValue = has ? shownPlaces[row].action : ""
        footerKey.isHidden = !has
        if let cap = footerKeys.first, let label = footerLabels.first {
            cap.stringValue = previewShown ? "←" : "→"
            label.stringValue = previewShown ? "Back" : "Details"
            cap.isHidden = !has && !previewShown
            label.isHidden = cap.isHidden
        }
    }

    // MARK: Details (→)

    /// Shows the selected result's details; the index fills in its matches right after.
    func showPreview() {
        let row = table.selectedRow
        guard row >= 0, row < shown.count else { return }
        previewShown = true
        scroll.isHidden = true
        emptyView.isHidden = true
        preview.isHidden = false
        loadPreview(row)
        updateFooter()
    }

    func hidePreview() {
        previewShown = false
        previewGeneration += 1
        preview.isHidden = true
        scroll.isHidden = false
        updateChrome()
    }

    /// Pause before asking the index, so holding ↓ doesn't queue a detail query per row.
    static var previewDelay = 0.08

    private func loadPreview(_ row: Int) {
        let hit = shown[row]
        let place = row < shownPlaces.count ? shownPlaces[row] : .outside
        let searched = !trimmedQuery.isEmpty
        let query = trimmedQuery
        previewGeneration += 1
        let gen = previewGeneration
        preview.show(hit, place: place, detail: nil, searched: searched)
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.previewDelay) { [weak self] in
            guard let self, gen == self.previewGeneration, self.previewShown else { return }
            self.manager.index.detail(key: hit.key, query: query) { [weak self] detail in
                guard let self, gen == self.previewGeneration, self.previewShown else { return }
                self.preview.show(hit, place: place, detail: detail, searched: searched)
            }
        }
    }

    private func updateClearButton() { clearButton.isHidden = field.stringValue.isEmpty }

    @objc func openSelected() {
        let row = table.selectedRow
        guard row >= 0, row < shown.count else { return }
        let hit = shown[row]
        invalidatePendingDismiss()
        staggerPending = false
        window?.orderOut(nil)
        window?.alphaValue = 1
        manager.open(hit: hit)
    }

    /// Esc: closes the details first, then clears a non-empty query, then closes the panel.
    func cancel() {
        if previewShown {
            hidePreview()
        } else if field.stringValue.isEmpty {
            dismiss(animated: true)
        } else {
            field.stringValue = ""
            updateClearButton()
            pending?.cancel()
            runQuery()
        }
    }

    // MARK: Keyboard in the search field

    func control(_ control: NSControl, textView: NSTextView, doCommandBy sel: Selector) -> Bool {
        switch sel {
        case #selector(NSResponder.moveDown(_:)): moveSelection(1); return true
        case #selector(NSResponder.moveUp(_:)): moveSelection(-1); return true
        case #selector(NSResponder.moveRight(_:)):
            // → at the end of the query opens the details; elsewhere it moves the caret.
            let caret = textView.selectedRange()
            guard !previewShown, !textView.hasMarkedText(), caret.length == 0,
                  caret.location >= (textView.string as NSString).length, table.selectedRow >= 0 else { return false }
            showPreview()
            return true
        case #selector(NSResponder.moveLeft(_:)):
            guard previewShown else { return false }
            hidePreview()
            return true
        case #selector(NSResponder.insertNewline(_:)): openSelected(); return true
        case #selector(NSResponder.insertTab(_:)): filter.cycle(1); return true
        case #selector(NSResponder.insertBacktab(_:)): filter.cycle(-1); return true
        case #selector(NSResponder.cancelOperation(_:)): cancel(); return true
        default: return false
        }
    }

    private func moveSelection(_ d: Int) {
        guard !shown.isEmpty else { return }
        let next = max(0, min(shown.count - 1, table.selectedRow + d))
        table.selectRowIndexes([next], byExtendingSelection: false)
        table.scrollRowToVisible(next)
    }

    @objc private func scrolled() { MainActor.assumeIsolated { table.refreshHover() } }

    // MARK: Table

    /// Title, the info line (when, where, how many matches), then the snippet lines.
    static func rowHeight(snippetLines n: Int) -> CGFloat { 50 + 16 * CGFloat(min(SearchHitCell.maxLines, n)) }

    func numberOfRows(in tableView: NSTableView) -> Int { shown.count }

    func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
        row < shown.count ? Self.rowHeight(snippetLines: shown[row].snippets.count) : 44
    }

    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
        let v = tableView.makeView(withIdentifier: SearchRowView.reuse, owner: self) as? SearchRowView ?? SearchRowView()
        v.identifier = SearchRowView.reuse
        v.hovered = row == table.hoveredRow
        return v
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard row < shown.count else { return nil }
        let hit = shown[row]
        let cell = tableView.makeView(withIdentifier: SearchHitCell.reuse, owner: self) as? SearchHitCell ?? SearchHitCell()
        cell.identifier = SearchHitCell.reuse
        cell.configure(hit, place: row < shownPlaces.count ? shownPlaces[row] : .outside)
        cell.selected = tableView.selectedRowIndexes.contains(row)
        return cell
    }

    func tableView(_ tableView: NSTableView, didAdd rowView: NSTableRowView, forRow row: Int) {
        (rowView.view(atColumn: 0) as? SearchHitCell)?.selected = rowView.isSelected
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        table.enumerateAvailableRowViews { rowView, _ in
            (rowView.view(atColumn: 0) as? SearchHitCell)?.selected = rowView.isSelected
        }
        // ↑↓ in the details browse the other results' details.
        if previewShown, table.selectedRow >= 0, table.selectedRow < shown.count { loadPreview(table.selectedRow) }
        updateFooter()
    }
}

// MARK: - Window and surface

/// Borderless, key-capable floating panel; the surface draws its own rounded frame.
final class SearchPanel: NSPanel {
    var onCancel: (() -> Void)?
    /// The query field: typing keys go back to it after a click into the details' text (selecting
    /// to copy), so ←, ↑↓, ↩ and esc keep working. ⌘ shortcuts (⌘C) stay with the selection.
    weak var queryField: NSTextField?
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
    override func cancelOperation(_ sender: Any?) { onCancel?() }

    override func sendEvent(_ event: NSEvent) {
        if event.type == .keyDown, !event.modifierFlags.contains(.command), let field = queryField,
           field.currentEditor() == nil || firstResponder !== field.currentEditor() {
            makeFirstResponder(field)
            let end = (field.stringValue as NSString).length
            field.currentEditor()?.selectedRange = NSRange(location: end, length: 0)
        }
        super.sendEvent(event)
    }
}

/// The panel's drawn frame: elevated fill, r14 continuous, a 1 device-pixel strong hairline. Never masks;
/// content insets keep everything clear of the corners. The window shadow follows its alpha.
final class PanelSurfaceView: NSView {
    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.cornerRadius = 14
        layer?.cornerCurve = .continuous
    }

    required init?(coder: NSCoder) { fatalError() }

    /// No masksToBounds (§3.15): content insets keep everything clear of the corners. AppKit clips a
    /// window's content view by default.
    override var clipsToBounds: Bool {
        get { false }
        set { super.clipsToBounds = false }
    }

    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        let t = Theme.tokens
        layer?.backgroundColor = t.elevated.cgColor
        layer?.borderColor = t.ramp(.elevated).hairlineStrong.cgColor
        layer?.borderWidth = 1 / (window?.backingScaleFactor ?? 2)
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        needsDisplay = true
    }
}

/// 1 pt hairline on the elevated surface.
private final class HairlineView: NSView {
    init() {
        super.init(frame: .zero)
        wantsLayer = true
    }

    required init?(coder: NSCoder) { fatalError() }

    override var wantsUpdateLayer: Bool { true }
    override func updateLayer() { layer?.backgroundColor = Theme.ramp(.elevated).hairline.cgColor }
}

/// ⓧ in the query field: `xmark.circle.fill` with the x knocked out in the surface color
/// (palette [mark, disc]); the disc goes from tertiary to secondary on hover.
final class ClearButton: NSButton {
    private(set) var hovered = false
    private var tracking: NSTrackingArea?

    init() {
        super.init(frame: NSRect(x: 0, y: 0, width: 20, height: 20))
        isBordered = false
        bezelStyle = .regularSquare
        title = ""
        imagePosition = .imageOnly
        imageScaling = .scaleNone
        refusesFirstResponder = true
        setAccessibilityLabel("Clear search")
        translatesAutoresizingMaskIntoConstraints = false
        widthAnchor.constraint(equalToConstant: 20).isActive = true
        heightAnchor.constraint(equalToConstant: 20).isActive = true
        refresh()
    }

    required init?(coder: NSCoder) { fatalError() }

    func refresh() {
        let t = Theme.tokens
        let r = t.ramp(.elevated)
        image = GlyphCache.image("xmark.circle.fill", size: 14, weight: .regular,
                                 colors: [t.elevated, hovered ? r.secondary : r.tertiary])
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let t = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                               owner: self, userInfo: nil)
        addTrackingArea(t)
        tracking = t
    }

    override func mouseEntered(with event: NSEvent) { setHovered(true) }
    override func mouseExited(with event: NSEvent) { setHovered(false) }

    func setHovered(_ h: Bool) {
        guard h != hovered else { return }
        hovered = h
        refresh()
    }
}

// MARK: - Scope chips

/// Capsule scope picker, API-compatible with the NSSegmentedControl it replaced (`selectedSegment`,
/// target/action). One owned indicator layer glides between chips (M27); hover gets a `hover` plate.
final class ScopeChips: NSControl {
    static let height: CGFloat = 22
    static let padding: CGFloat = 9
    static let spacing: CGFloat = 2
    static let font = NSFont.systemFont(ofSize: 12, weight: .medium)

    let labels: [String]
    private(set) var chips: [ScopeChip] = []
    let indicator = CALayer()
    let hoverPlate = CALayer()
    private let textWidths: [CGFloat]
    private var selected = 0
    private(set) var hoveredSegment: Int? { didSet { if hoveredSegment != oldValue { updateHoverPlate() } } }
    private weak var actionTarget: AnyObject?
    private var actionSelector: Selector?
    private var tracking: NSTrackingArea?

    init(labels: [String]) {
        self.labels = labels
        textWidths = labels.map { ceil(($0 as NSString).size(withAttributes: [.font: Self.font]).width) }
        super.init(frame: NSRect(x: 0, y: 0, width: 10, height: Self.height))
        wantsLayer = true
        for l in [hoverPlate, indicator] {
            l.actions = ["position": NSNull(), "bounds": NSNull(), "frame": NSNull(), "backgroundColor": NSNull(),
                         "hidden": NSNull(), "opacity": NSNull(), "cornerRadius": NSNull()]
            l.cornerCurve = .continuous
            l.zPosition = -1
            layer?.addSublayer(l)
        }
        hoverPlate.isHidden = true
        for (i, text) in labels.enumerated() {
            let chip = ScopeChip(title: text)
            chip.onPress = { [weak self] in self?.choose(i) }
            chips.append(chip)
            addSubview(chip)
        }
        setAccessibilityElement(true)
        setAccessibilityRole(.radioGroup)
        refreshSelection(animated: false)
        refreshColors()
    }

    required init?(coder: NSCoder) { fatalError() }

    override var target: AnyObject? {
        get { actionTarget }
        set { actionTarget = newValue }
    }

    override var action: Selector? {
        get { actionSelector }
        set { actionSelector = newValue }
    }

    var segmentCount: Int { labels.count }

    func label(forSegment i: Int) -> String? { labels.indices.contains(i) ? labels[i] : nil }

    var selectedSegment: Int {
        get { selected }
        set { select(newValue, animated: Motion.full && Motion.shouldAnimate(self)) }
    }

    /// Programmatic selection; no action is sent.
    func select(_ i: Int, animated: Bool) {
        let v = min(max(i, 0), labels.count - 1)
        guard v != selected else { return }
        selected = v
        refreshSelection(animated: animated)
    }

    /// A user choice (click, ⇥, VoiceOver): selects and sends the action when it changed.
    func choose(_ i: Int) {
        guard labels.indices.contains(i), i != selected else { return }
        selectedSegment = i
        sendAction(action, to: target)
    }

    /// ⇥ / ⇧⇥: the next or previous scope, wrapping around.
    func cycle(_ step: Int) {
        let n = labels.count
        choose(((selected + step) % n + n) % n)
    }

    override var intrinsicContentSize: NSSize {
        let w = textWidths.reduce(0) { $0 + $1 + 2 * Self.padding } + Self.spacing * CGFloat(max(0, labels.count - 1))
        return NSSize(width: w, height: Self.height)
    }

    func chipFrame(_ i: Int) -> NSRect {
        var x: CGFloat = 0
        for j in 0..<i { x += textWidths[j] + 2 * Self.padding + Self.spacing }
        return NSRect(x: x, y: ((bounds.height - Self.height) / 2).rounded(), width: textWidths[i] + 2 * Self.padding,
                      height: Self.height)
    }

    func segment(at point: NSPoint) -> Int? {
        labels.indices.first { chipFrame($0).insetBy(dx: -Self.spacing / 2, dy: -4).contains(point) }
    }

    override func layout() {
        super.layout()
        for (i, chip) in chips.enumerated() { chip.frame = chipFrame(i) }
        Motion.quiet {
            indicator.frame = chipFrame(selected)
            indicator.cornerRadius = Self.height / 2
            hoverPlate.cornerRadius = Self.height / 2
            if let h = hoveredSegment { hoverPlate.frame = chipFrame(h) }
        }
    }

    /// Moves the indicator; the glide starts from wherever an interrupted glide currently is.
    private func refreshSelection(animated: Bool) {
        let current = indicator.presentation() ?? indicator
        let fromPosition = current.position, fromBounds = current.bounds
        Motion.quiet { indicator.frame = chipFrame(selected) }
        if animated {
            indicator.add(Motion.spring("position", from: NSValue(point: fromPosition), to: NSValue(point: indicator.position)),
                          forKey: "glide.position")
            indicator.add(Motion.spring("bounds", from: NSValue(rect: fromBounds), to: NSValue(rect: indicator.bounds)),
                          forKey: "glide.bounds")
        }
        for (i, chip) in chips.enumerated() { chip.isSelected = i == selected }
        updateHoverPlate()
    }

    private func updateHoverPlate() {
        Motion.quiet {
            if let h = hoveredSegment, h != selected {
                hoverPlate.frame = chipFrame(h)
                hoverPlate.isHidden = false
            } else {
                hoverPlate.isHidden = true
            }
        }
    }

    func refreshColors() {
        let r = Theme.ramp(.elevated)
        Motion.quiet {
            indicator.backgroundColor = r.selected.cgColor
            hoverPlate.backgroundColor = r.hover.cgColor
        }
        for chip in chips { chip.refresh() }
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override var acceptsFirstResponder: Bool { false }

    override func mouseDown(with event: NSEvent) {
        if let i = segment(at: convert(event.locationInWindow, from: nil)) { choose(i) }
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let t = NSTrackingArea(rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                               owner: self, userInfo: nil)
        addTrackingArea(t)
        tracking = t
    }

    override func mouseMoved(with event: NSEvent) { hoveredSegment = segment(at: convert(event.locationInWindow, from: nil)) }
    override func mouseEntered(with event: NSEvent) { mouseMoved(with: event) }
    override func mouseExited(with event: NSEvent) { hoveredSegment = nil }

    override func accessibilityChildren() -> [Any]? { chips }
}

/// One scope chip: its label plus the radio-button accessibility element. Clicks go to `ScopeChips`.
final class ScopeChip: NSView {
    let label = NSTextField(labelWithString: "")
    var isSelected = false { didSet { if isSelected != oldValue { refresh() } } }
    var onPress: (() -> Void)?

    init(title: String) {
        super.init(frame: .zero)
        label.stringValue = title
        label.font = ScopeChips.font
        label.alignment = .center
        label.setAccessibilityElement(false)
        addSubview(label)
        refresh()
    }

    required init?(coder: NSCoder) { fatalError() }

    func refresh() {
        let r = Theme.ramp(.elevated)
        label.textColor = isSelected ? r.primary : r.secondary
    }

    override func layout() {
        super.layout()
        let h = label.intrinsicContentSize.height
        label.frame = NSRect(x: 0, y: ((bounds.height - h) / 2).rounded(), width: bounds.width, height: h)
    }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func isAccessibilityElement() -> Bool { true }
    override func accessibilityRole() -> NSAccessibility.Role? { .radioButton }
    override func accessibilityLabel() -> String? { label.stringValue }
    override func accessibilityValue() -> Any? { NSNumber(value: isSelected) }
    override func accessibilityPerformPress() -> Bool {
        onPress?()
        return true
    }
}

// MARK: - Results

/// Results list: tracks the hovered row for the pill hover fill; never takes focus from the field.
final class SearchResultsTable: NSTableView {
    private(set) var hoveredRow = -1
    private var tracking: NSTrackingArea?

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let t = NSTrackingArea(rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                               owner: self, userInfo: nil)
        addTrackingArea(t)
        tracking = t
    }

    override func mouseMoved(with event: NSEvent) {
        super.mouseMoved(with: event)
        setHovered(row(at: convert(event.locationInWindow, from: nil)))
    }

    override func mouseEntered(with event: NSEvent) { mouseMoved(with: event) }

    override func mouseExited(with event: NSEvent) {
        super.mouseExited(with: event)
        setHovered(-1)
    }

    override func reloadData() {
        hoveredRow = -1
        super.reloadData()
    }

    func setHovered(_ row: Int) {
        let next = row >= 0 && row < numberOfRows ? row : -1
        guard next != hoveredRow else { return }
        if hoveredRow >= 0, hoveredRow < numberOfRows {
            (rowView(atRow: hoveredRow, makeIfNecessary: false) as? SearchRowView)?.hovered = false
        }
        hoveredRow = next
        if next >= 0 { (rowView(atRow: next, makeIfNecessary: false) as? SearchRowView)?.hovered = true }
    }

    /// After a scroll the pointer sits over a different row without moving.
    /// The pointer in window coordinates; tests pin it (the real one is wherever the mouse is).
    var pointerInWindow: (() -> NSPoint)?

    func refreshHover() {
        guard let window else { return setHovered(-1) }
        let p = convert(pointerInWindow?() ?? window.mouseLocationOutsideOfEventStream, from: nil)
        setHovered(visibleRect.contains(p) ? row(at: p) : -1)
    }
}

/// Result pill: r8 fill (hover, selected) plus a 2.5 pt accent bar inside the leading edge of the
/// selected pill. Owned layers, no implicit actions; text never inverts.
final class SearchRowView: NSTableRowView {
    static let reuse = NSUserInterfaceItemIdentifier("hitRow")
    let fill = CALayer()
    let bar = CALayer()
    var hovered = false { didSet { if hovered != oldValue { needsDisplay = true } } }
    private var shownSelected = false
    private var shownHovered = false

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        for l in [fill, bar] {
            l.actions = ["backgroundColor": NSNull(), "frame": NSNull(), "position": NSNull(), "bounds": NSNull(),
                         "hidden": NSNull(), "opacity": NSNull()]
            l.zPosition = -1
            layer?.addSublayer(l)
        }
        fill.cornerRadius = 8
        fill.cornerCurve = .continuous
        bar.cornerRadius = 1.25
        bar.maskedCorners = [.layerMaxXMinYCorner, .layerMaxXMaxYCorner]
        bar.isHidden = true
    }

    convenience init() { self.init(frame: .zero) }

    required init?(coder: NSCoder) { fatalError() }

    override var isSelected: Bool { didSet { needsDisplay = true } }

    override func prepareForReuse() {
        super.prepareForReuse()
        hovered = false
        shownHovered = false
        shownSelected = false
        fill.removeAllAnimations()
        layer?.removeAnimation(forKey: "present.fade")
        layer?.removeAnimation(forKey: "present.rise")
    }

    override var interiorBackgroundStyle: NSView.BackgroundStyle { .normal }
    override var wantsUpdateLayer: Bool { true }
    override func drawSelection(in dirtyRect: NSRect) {}
    override func drawBackground(in dirtyRect: NSRect) {}

    override func updateLayer() {
        let r = Theme.ramp(.elevated)
        // "None" keeps the hover RGB at alpha 0, so a hover fade never passes through black.
        let color = (isSelected ? r.selected : (hovered ? r.hover : r.hover.withAlphaComponent(0))).cgColor
        let hoverOnly = !isSelected && !shownSelected && hovered != shownHovered
        let from = fill.presentation()?.backgroundColor ?? fill.backgroundColor
        Motion.quiet {
            fill.backgroundColor = color
            bar.backgroundColor = Theme.tokens.accent.cgColor
            bar.isHidden = !isSelected
        }
        if hoverOnly, Motion.full, window != nil {
            fill.add(Motion.basic("backgroundColor", from: from, to: color, duration: hovered ? Motion.micro : 0.16),
                     forKey: "hover")
        } else if isSelected != shownSelected {
            fill.removeAnimation(forKey: "hover")   // selection (↑↓, click) is always instant
        }
        shownSelected = isSelected
        shownHovered = hovered
    }

    override func layout() {
        super.layout()
        // Row bounds include the 2 pt intercell spacing; the pill is exactly the row height.
        let pill = bounds.insetBy(dx: 0, dy: 1)
        let g = max(12, pill.height - 20)
        Motion.quiet {
            fill.frame = pill
            bar.frame = CGRect(x: pill.minX, y: pill.midY - g / 2, width: 2.5, height: g)
        }
    }
}

// MARK: - Hit cell

/// One result: agent tile, title, place tag, compact meta (↩ keycap when selected), up to three snippet lines.
final class SearchHitCell: NSTableCellView {
    static let reuse = NSUserInterfaceItemIdentifier("hit")
    static let lineHeight: CGFloat = 16
    /// Snippet lines per result under the info line: the best passage (a prompt or answer when
    /// there is one); → shows every match.
    static let maxLines = 1
    private static let codeStrong = NSFont.monospacedSystemFont(ofSize: 11.5, weight: .semibold)
    /// Resolved once: `GlyphCache.agentSymbol(.pi)` probes `NSImage(systemSymbolName:)` (§5.11: never in configure).
    private static let agentSymbols = Dictionary(uniqueKeysWithValues: AgentKind.allCases.map { ($0, GlyphCache.agentSymbol($0)) })
    private static let snippetParagraph: NSParagraphStyle = {
        let p = NSMutableParagraphStyle()
        p.lineBreakMode = .byTruncatingTail
        p.minimumLineHeight = lineHeight
        p.maximumLineHeight = lineHeight
        return p
    }()
    private static let monthDay: DateFormatter = {
        let f = DateFormatter()
        f.setLocalizedDateFormatFromTemplate("MMMd")
        return f
    }()
    private static let fullDate: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .short
        return f
    }()

    let tile = HitTileView()
    let titleLabel = NSTextField(labelWithString: "")
    let placeTag = PlaceTagView()
    let metaLabel = NSTextField(labelWithString: "")
    let returnKey = ReturnKeyView()
    let snippetView = SnippetView()
    private(set) var place: SearchPlace = .outside
    private(set) var snippetCount = 0
    var selected = false { didSet { if selected != oldValue { applySelection() } } }

    init() {
        super.init(frame: NSRect(x: 0, y: 0, width: 600, height: 44))
        wantsLayer = true
        titleLabel.font = Fonts.hitTitle
        titleLabel.lineBreakMode = .byTruncatingTail
        metaLabel.font = Fonts.hitMeta
        metaLabel.lineBreakMode = .byTruncatingTail
        returnKey.isHidden = true
        for v in [tile, titleLabel, placeTag, metaLabel, returnKey, snippetView] as [NSView] { addSubview(v) }
    }

    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }

    /// Compatibility shim: "OPEN" / "CLOSED" / "" select the place tag.
    func configure(_ hit: SearchHit, badge text: String) {
        switch text.uppercased() {
        case "OPEN": configure(hit, place: .open)
        case "CLOSED": configure(hit, place: .closed)
        default: configure(hit, place: .outside)
        }
    }

    func configure(_ hit: SearchHit, place: SearchPlace, now: Date = Date()) {
        let r = Theme.ramp(.elevated)
        self.place = place
        tile.symbol = Self.agentSymbols[hit.agent] ?? "terminal"
        tile.needsDisplay = true   // colors may have changed with the theme
        returnKey.needsDisplay = true
        tile.toolTip = hit.agent.displayName
        titleLabel.stringValue = hit.title.isEmpty ? "Untitled" : hit.title
        titleLabel.textColor = r.primary
        placeTag.place = place
        metaLabel.stringValue = Self.meta(hit, now: now)
        metaLabel.textColor = r.tertiary
        metaLabel.toolTip = Self.tooltip(hit)
        let lines = Self.lines(hit.snippets, limit: Self.maxLines)
        snippetView.lines = lines
        snippetView.isHidden = lines.isEmpty
        snippetCount = lines.count
        let tag = place == .outside ? "" : ", \(placeTag.text)"
        setAccessibilityLabel("\(titleLabel.stringValue)\(tag), \(metaLabel.stringValue)")
        setAccessibilityHelp(lines.map(\.string).joined(separator: "\n"))
        applySelection()
        needsLayout = true
    }

    private func applySelection() {
        returnKey.isHidden = !selected
        tile.emphasized = selected
        needsLayout = true
    }

    override func layout() {
        super.layout()
        let w = bounds.width
        let titleH = ceil(titleLabel.intrinsicContentSize.height)
        let titleY: CGFloat = 8
        let mid = titleY + titleH / 2
        tile.frame = NSRect(x: 8, y: 8, width: 26, height: 26)
        // Text positions are alignment rects: labels draw with a small inset inside their frames.
        var right = w - 12
        if selected {
            let s = returnKey.intrinsicContentSize
            returnKey.frame = NSRect(x: right - s.width, y: (mid - s.height / 2).rounded(), width: s.width, height: s.height)
            right = returnKey.frame.minX
        }
        let tagW = placeTag.isHidden ? 0 : placeTag.preferredWidth
        let room = max(0, right - 12 - (tagW > 0 ? tagW + 6 : 0) - 42)
        let tw = min(ceil(titleLabel.intrinsicContentSize.width), room)
        titleLabel.frame = titleLabel.frame(forAlignmentRect: NSRect(x: 42, y: titleY, width: tw, height: titleH))
        placeTag.frame = NSRect(x: 42 + tw + 6, y: (mid - 7).rounded(), width: tagW, height: 14)
        // Info line under the title: when it ran, how often it matched, where.
        let mh = ceil(metaLabel.intrinsicContentSize.height)
        metaLabel.frame = metaLabel.frame(forAlignmentRect: NSRect(x: 42, y: 26, width: max(0, w - 42 - 12), height: mh))
        snippetView.frame = NSRect(x: 42 - SnippetView.inset, y: 42, width: max(0, w - 42 - 12 + SnippetView.inset),
                                   height: CGFloat(snippetCount) * Self.lineHeight)
    }

    // MARK: Text

    /// The info line: "Active 2d ago · Started 14 Oct · 18 matches · Documents/Code" (what tells
    /// sessions apart; → shows the matching messages themselves).
    static func meta(_ hit: SearchHit, now: Date = Date()) -> String {
        var parts: [String] = []
        if let u = hit.updated { parts.append("Active \(ago(u, now: now))") }
        if let c = hit.created, hit.updated.map({ $0.timeIntervalSince(c) > 3600 }) ?? true {
            parts.append("Started \(dayOrTime(c, now: now))")
        }
        if hit.matchCount > 0 { parts.append(hit.matchCount == 1 ? "1 match" : "\(hit.matchCount) matches") }
        let path = compactPath(hit.cwd)
        if !path.isEmpty { parts.append(path) }
        return parts.joined(separator: " · ")
    }

    /// "now", "16m ago", "2d ago", past a week "on 14 Oct".
    static func ago(_ date: Date, now: Date = Date()) -> String {
        let w = when(date, now: now)
        if now.timeIntervalSince(date) > 7 * 86_400 { return "on \(w)" }
        return w == "now" ? "now" : "\(w) ago"
    }

    /// Today a time ("09:12"), else the day ("14 Oct").
    static func dayOrTime(_ date: Date, now: Date = Date()) -> String {
        Calendar.current.isDate(date, inSameDayAs: now) ? timeOnly.string(from: date) : monthDay.string(from: date)
    }

    private static let timeOnly: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .none
        f.timeStyle = .short
        return f
    }()

    static func compactPath(_ path: String) -> String {
        guard !path.isEmpty else { return "" }
        let temp = ["/private/tmp/", "/tmp/", "/var/folders/", "/private/var/folders/"]
        if temp.contains(where: { path.hasPrefix($0) }) { return path.pathLeaf }
        let short = abbreviateHome(path)
        let parts = short.split(separator: "/")
        return parts.count > 2 ? parts.suffix(2).joined(separator: "/") : short
    }

    static func abbreviateHome(_ path: String) -> String {
        let home = NSHomeDirectory()
        if path == home { return "~" }
        return path.hasPrefix(home + "/") ? "~" + path.dropFirst(home.count) : path
    }

    static func when(_ date: Date, now: Date = Date()) -> String {
        now.timeIntervalSince(date) > 7 * 86_400 ? monthDay.string(from: date) : RelativeTime.short(since: date, now: now)
    }

    static func tooltip(_ hit: SearchHit) -> String {
        [abbreviateHome(hit.cwd), hit.updated.map { fullDate.string(from: $0) } ?? ""].filter { !$0.isEmpty }
            .joined(separator: "\n")
    }

    /// One styled line per snippet. User prompts lead with an accent "›", commands with a tertiary "$"
    /// and set in mono; matches (FTS \u{1}…\u{2}) are semibold primary and tagged `.searchMatch`.
    static func lines(_ snippets: [SearchSnippet], limit: Int = .max) -> [NSAttributedString] {
        let t = Theme.tokens
        let r = t.ramp(.elevated)
        let para = snippetParagraph
        return snippets.prefix(limit).map { s in
            let code = s.role == "command"
            let base: [NSAttributedString.Key: Any] = [.font: code ? Fonts.hitCode : Fonts.hitSnippet,
                                                       .foregroundColor: r.secondary, .paragraphStyle: para]
            let strong: [NSAttributedString.Key: Any] = [.font: code ? codeStrong : Fonts.hitSnippetStrong,
                                                         .foregroundColor: r.primary, .paragraphStyle: para,
                                                         .searchMatch: true]
            let out = NSMutableAttributedString()
            switch s.role {
            case "user":
                out.append(NSAttributedString(string: "› ", attributes: [.font: Fonts.hitSnippetStrong,
                                                                        .foregroundColor: t.accent, .paragraphStyle: para]))
            case "command":
                out.append(NSAttributedString(string: "$ ", attributes: [.font: Fonts.hitCode,
                                                                        .foregroundColor: r.tertiary, .paragraphStyle: para]))
            default: break
            }
            SearchMarkup.append(s.text, to: out, base: base, strong: strong)
            return out
        }
    }

    /// All snippets as one string (lines joined by "\n"), styled as in the list.
    static func highlight(_ snippets: [SearchSnippet]) -> NSAttributedString {
        let out = NSMutableAttributedString()
        for (i, line) in lines(snippets).enumerated() {
            if i > 0 { out.append(NSAttributedString(string: "\n")) }
            out.append(line)
        }
        return out
    }
}

/// 26 pt agent tile: `sunken` (or `pressed` on the selected pill) with the monochrome agent glyph.
final class HitTileView: NSView {
    var symbol = "terminal" { didSet { if symbol != oldValue { needsDisplay = true } } }
    var emphasized = false { didSet { if emphasized != oldValue { needsDisplay = true } } }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.cornerRadius = 7
        layer?.cornerCurve = .continuous
        layerContentsPlacement = .center
    }

    convenience init() { self.init(frame: NSRect(x: 0, y: 0, width: 26, height: 26)) }

    required init?(coder: NSCoder) { fatalError() }

    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        let r = Theme.ramp(.elevated)
        let scale = window?.backingScaleFactor ?? 2
        layer?.backgroundColor = (emphasized ? r.pressed : r.sunken).cgColor
        layer?.contentsScale = scale
        layer?.contentsGravity = .center
        layer?.contents = GlyphCache.image(symbol, size: 12, weight: .medium, colors: [r.secondary])?
            .layerContents(forContentsScale: scale)
    }
}

/// ↩ on the selected pill: an r4 `pressed` plate, one overlay step above the `selected` pill, so it reads
/// raised in dark and light alike (a KeyCap's `sunken` fill reads as a hole on the pill in dark).
final class ReturnKeyView: NSView {
    let label = NSTextField(labelWithString: KeyHint.format("\r", []))

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.cornerRadius = 4
        layer?.cornerCurve = .continuous
        label.font = Fonts.keycap
        label.alignment = .center
        label.setAccessibilityElement(false)
        addSubview(label)
    }

    convenience init() { self.init(frame: .zero) }

    required init?(coder: NSCoder) { fatalError() }

    var stringValue: String { label.stringValue }

    /// Same metrics as `KeyCap`: 5 pt sides, 2 pt top and bottom.
    override var intrinsicContentSize: NSSize {
        let s = label.intrinsicContentSize
        return NSSize(width: ceil(s.width) + 10, height: ceil(s.height) + 4)
    }

    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        let r = Theme.ramp(.elevated)
        layer?.backgroundColor = r.pressed.cgColor
        label.textColor = r.secondary
    }

    override func layout() {
        super.layout()
        label.frame = bounds.insetBy(dx: 5, dy: 2)
    }
}

/// Open: a filled Ø6 dot + "open" in secondary. Closed: a hollow ring + "closed" in tertiary.
/// Not in Corral: hidden (green stays reserved for done).
final class PlaceTagView: NSView {
    private static let widths: [String: CGFloat] = Dictionary(uniqueKeysWithValues: ["open", "closed"].map {
        ($0, ceil(($0 as NSString).size(withAttributes: [.font: Fonts.monoSmall]).width))
    })
    let dot = CALayer()
    let label = NSTextField(labelWithString: "")
    var place: SearchPlace = .outside { didSet { refresh() } }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        dot.actions = ["backgroundColor": NSNull(), "borderColor": NSNull(), "borderWidth": NSNull(), "frame": NSNull(),
                       "position": NSNull(), "bounds": NSNull()]
        dot.cornerRadius = 3
        layer?.addSublayer(dot)
        label.font = Fonts.monoSmall
        addSubview(label)
        refresh()
    }

    convenience init() { self.init(frame: .zero) }

    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }

    var text: String { place == .open ? "open" : (place == .closed ? "closed" : "") }

    /// Dot 6 + gap 4 + label.
    var preferredWidth: CGFloat { place == .outside ? 0 : 10 + (Self.widths[text] ?? 30) }

    private func refresh() {
        isHidden = place == .outside
        label.stringValue = text
        needsDisplay = true
        needsLayout = true
    }

    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        let r = Theme.ramp(.elevated)
        Motion.quiet {
            if place == .open {
                dot.backgroundColor = r.secondary.cgColor
                dot.borderWidth = 0
            } else {
                dot.backgroundColor = nil
                dot.borderWidth = 1.25
                dot.borderColor = r.tertiary.cgColor
            }
        }
        label.textColor = place == .open ? r.secondary : r.tertiary
    }

    override func layout() {
        super.layout()
        Motion.quiet { dot.frame = CGRect(x: 0, y: ((bounds.height - 6) / 2).rounded(), width: 6, height: 6) }
        let h = ceil(label.intrinsicContentSize.height)
        label.frame = label.frame(forAlignmentRect: NSRect(x: 10, y: ((bounds.height - h) / 2).rounded(),
                                                           width: max(0, bounds.width - 10), height: h))
    }
}

/// Snippet lines, drawn directly: each line truncates at its tail, and matches get a rounded accent
/// wash (α 0.22 dark / 0.16 light) behind semibold primary text. Never yellow, never amber.
final class SnippetView: NSView {
    /// Leading room so a wash around a line's first character is not clipped.
    static let inset: CGFloat = 2
    private static let ellipsis = ceil(("…" as NSString).size(withAttributes: [.font: Fonts.hitSnippet]).width)

    var lines: [NSAttributedString] = [] { didSet { needsDisplay = true } }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layerContentsRedrawPolicy = .onSetNeedsDisplay
    }

    convenience init() { self.init(frame: .zero) }

    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }

    override func isAccessibilityElement() -> Bool { false }

    /// Wash rects (in this view) for every match of every line, clamped to the visible part of the line.
    func matchRects() -> [NSRect] {
        let width = bounds.width - Self.inset
        var rects: [NSRect] = []
        for (i, line) in lines.enumerated() {
            let full = line.size().width
            let limit = full > width ? width - Self.ellipsis : width
            let y = CGFloat(i) * SearchHitCell.lineHeight
            line.enumerateAttribute(.searchMatch, in: NSRange(location: 0, length: line.length)) { value, range, _ in
                guard value != nil else { return }
                let x0 = line.attributedSubstring(from: NSRange(location: 0, length: range.location)).size().width
                guard x0 < limit else { return }
                let x1 = min(x0 + line.attributedSubstring(from: range).size().width, limit)
                rects.append(NSRect(x: Self.inset + x0 - 2, y: y + 1, width: x1 - x0 + 4, height: SearchHitCell.lineHeight - 1))
            }
        }
        return rects
    }

    override func draw(_ dirtyRect: NSRect) {
        let t = Theme.tokens
        t.accent.withAlphaComponent(t.isChromeDark ? 0.22 : 0.16).setFill()
        for r in matchRects() { NSBezierPath(roundedRect: r, xRadius: 3.5, yRadius: 3.5).fill() }
        let width = bounds.width - Self.inset
        for (i, line) in lines.enumerated() {
            let rect = NSRect(x: Self.inset, y: CGFloat(i) * SearchHitCell.lineHeight, width: width,
                              height: SearchHitCell.lineHeight + 4)
            line.draw(with: rect, options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine])
        }
    }
}
