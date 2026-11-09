import AppKit
import CorralCore

/// Right side (spec §3.2): the chrome surface with the floating terminal card. The card stacks all
/// live terminals (only the selected one visible), the scrollback find bar, and the placeholder
/// pages for closed sessions, background agents and the empty state.
final class TerminalContainerViewController: NSViewController {
    let manager: SessionManager
    let card = CardView()
    /// Terminal stack, inset 4 inside the card so its corners and border never touch terminal pixels.
    let stack = NSView()
    let placeholder = PlaceholderView()
    /// Over the selected terminal while its agent launches (one shared view, configured per session).
    let launchCover = LaunchCoverView()
    let findBar = FindBar()
    /// Where a session dragged in from the sidebar would go.
    let dropPreview = SplitDropPreview()
    private weak var findTarget: TerminalSurface?
    private(set) var shownSession: UUID?
    /// The card on screen: the shown session's, or the holder's when it shares one (side by side).
    private(set) var shownHost: UUID?
    /// Split cards (panes, sessions side by side) by holder: nested split views shown instead of the
    /// holder's terminal view; the other sessions' terminals live inside them.
    private(set) var splitHosts: [UUID: NSView] = [:]
    /// Where keyboard focus goes when a switch must not focus the new terminal but the focused
    /// terminal is being hidden (the window owner returns the sidebar list, nil when collapsed).
    var focusFallback: (() -> NSView?)?

    static let cardMargin: CGFloat = 6
    static let terminalInset: CGFloat = 4

    private var cardLeading: NSLayoutConstraint!
    private var cardTrailing: NSLayoutConstraint!
    private var cardBottom: NSLayoutConstraint!

    init(manager: SessionManager) {
        self.manager = manager
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError() }

    deinit { NotificationCenter.default.removeObserver(self) }

    override func loadView() {
        let root = ContainerBackdropView()
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.clipsToBounds = false
        placeholder.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(card)
        card.addSubview(stack)
        card.addSubview(launchCover)
        card.addSubview(placeholder)
        card.addSubview(dropPreview)
        card.addSubview(findBar)
        card.dropTarget = self
        card.registerForDraggedTypes([SidebarViewController.dragType])
        let inset = Self.terminalInset
        cardLeading = card.leadingAnchor.constraint(equalTo: root.leadingAnchor)
        cardTrailing = card.trailingAnchor.constraint(equalTo: root.trailingAnchor)
        cardBottom = card.bottomAnchor.constraint(equalTo: root.bottomAnchor)
        NSLayoutConstraint.activate([
            card.topAnchor.constraint(equalTo: root.safeAreaLayoutGuide.topAnchor),
            cardLeading, cardTrailing, cardBottom,
            stack.topAnchor.constraint(equalTo: card.topAnchor, constant: inset),
            stack.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: inset),
            stack.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -inset),
            stack.bottomAnchor.constraint(equalTo: card.bottomAnchor, constant: -inset),
            launchCover.topAnchor.constraint(equalTo: stack.topAnchor),
            launchCover.leadingAnchor.constraint(equalTo: stack.leadingAnchor),
            launchCover.trailingAnchor.constraint(equalTo: stack.trailingAnchor),
            launchCover.bottomAnchor.constraint(equalTo: stack.bottomAnchor),
            placeholder.topAnchor.constraint(equalTo: card.topAnchor),
            placeholder.leadingAnchor.constraint(equalTo: card.leadingAnchor),
            placeholder.trailingAnchor.constraint(equalTo: card.trailingAnchor),
            placeholder.bottomAnchor.constraint(equalTo: card.bottomAnchor),
            findBar.topAnchor.constraint(equalTo: card.topAnchor, constant: 8),
            findBar.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -8),
        ])
        // Below the window-drag priority: the bar never sets a minimum card (or window) width.
        let barLeading = findBar.leadingAnchor.constraint(greaterThanOrEqualTo: card.leadingAnchor, constant: 8)
        barLeading.priority = PlaceholderView.marginPriority
        barLeading.isActive = true
        updateMargins()
        findBar.isHidden = true
        findBar.onChange = { [weak self] text in self?.findTarget?.perform(binding: "search:\(text)") }
        findBar.onNext = { [weak self] in self?.findTarget?.perform(binding: "navigate_search:next") }
        findBar.onPrevious = { [weak self] in self?.findTarget?.perform(binding: "navigate_search:previous") }
        findBar.onClose = { [weak self] in self?.endFind() }
        launchCover.onClick = { [weak self] in self?.revealLaunch() }
        view = root
        NotificationCenter.default.addObserver(self, selector: #selector(themeChanged), name: .corralThemeDidChange, object: nil)
        recolor()
    }

    // MARK: Card geometry

    /// Card leading margin is 0 next to the sidebar, 6 when it is collapsed (set by the window, instant).
    var sidebarCollapsed = false {
        didSet { if sidebarCollapsed != oldValue { updateMargins() } }
    }

    private(set) var isFullScreen = false

    /// Full screen: card margins, radius, border and shadow go to 0, instantly.
    func setFullScreen(_ on: Bool) {
        _ = view
        isFullScreen = on
        card.flat = on
        updateMargins()
    }

    /// Current card margins (leading, trailing, bottom), all ≥ 0.
    var cardMargins: (leading: CGFloat, trailing: CGFloat, bottom: CGFloat) {
        let m = Self.cardMargin
        if isFullScreen { return (0, 0, 0) }
        return (sidebarCollapsed ? m : 0, m, m)
    }

    private func updateMargins() {
        guard let cardLeading else { return }
        let m = cardMargins
        cardLeading.constant = m.leading
        cardTrailing.constant = -m.trailing
        cardBottom.constant = -m.bottom
    }

    // MARK: Theme

    /// Recomputes the tokens from the terminal config. A change posts `.corralThemeDidChange`, which
    /// recolors chrome and card here; the placeholder and find bar observe it themselves.
    /// Recolors from the current tokens. Only the window writes the theme (Theme.update on
    /// .appearance); views just read it, so several windows (or tests) can't fight over it.
    func applyBackground() {
        _ = view
        recolor()
    }

    @objc private func themeChanged() { MainActor.assumeIsolated { recolor() } }

    private func recolor() {
        view.needsDisplay = true
        card.needsDisplay = true
    }

    // MARK: Terminals

    /// Shows the selected session's terminal; adds terminals of new sessions on first use.
    /// Hidden terminals don't autoresize; the visible one gets its frame refreshed when shown.
    func showSelected(focus: Bool) {
        _ = view
        let sel = manager.workspace.selected
        let host = sel.map(hostId)
        let previous = shownHost
        var incoming: NSView?
        // Hiding the view that holds keyboard focus makes AppKit search the whole window for the
        // next key view (every sidebar row): hand focus over first.
        if let window = view.window, let responder = window.firstResponder as? NSView,
           manager.live.keys.contains(where: { $0 != host && hostId($0) == $0 && hostView($0).map(responder.isDescendant(of:)) == true }) {
            let next = focus ? sel.flatMap { manager.focusedTerminal($0)?.view } : focusFallback?()
            if next.map({ !window.makeFirstResponder($0) }) ?? true { window.makeFirstResponder(nil) }
        }
        for (id, ls) in manager.live {
            // A session on another's card lives inside that card's host.
            guard hostId(id) == id, let v = hostView(id) else { continue }
            if v.superview !== stack {
                v.autoresizingMask = []
                v.frame = stack.bounds
                v.isHidden = true
                stack.addSubview(v)
                terminals(of: id).forEach { $0.setVisible(false) }
            }
            let visible = id == host
            if visible {
                if v.frame != stack.bounds { v.frame = stack.bounds }
                if v.autoresizingMask != [.width, .height] { v.autoresizingMask = [.width, .height] }
            } else if !v.autoresizingMask.isEmpty {
                v.autoresizingMask = []
            }
            if v.isHidden == visible {
                v.isHidden = !visible
                if splitHosts[id] == nil { ls.terminal.setVisible(visible) } else { terminals(of: id).forEach { $0.setVisible(visible) } }
                if visible { incoming = v }
            }
        }
        if findBar.isPresented || findTarget != nil,
           !(host.map { terminals(of: $0).contains { $0 === findTarget } } ?? false) { endFind() }
        // Selected without focus (sidebar edge chip) next to the terminal being typed in: keys go to
        // the selected session, so ⌘W, ⌘D or Find never act on another one than the keyboard's.
        if !focus, host == previous, let sel, let h = host, let window = view.window,
           let responder = window.firstResponder as? NSView, let target = manager.focusedTerminal(sel)?.view,
           responder !== target, terminals(of: h).contains(where: { responder === $0.view || responder.isDescendant(of: $0.view) }) {
            window.makeFirstResponder(target)
        }
        shownSession = sel
        shownHost = host
        if let sel, let ls = manager.live[sel] {
            placeholder.isHidden = true
            var faded = false
            if host != previous, Motion.switchFadeAllowed(), let incoming, Motion.shouldAnimate(incoming) {
                fadeIn(incoming)
                faded = true
            }
            updateLaunchCover(animated: false, entrance: faded)
            if focus { view.window?.makeFirstResponder(manager.focusedTerminal(sel)?.view ?? ls.terminal.view) }
        } else {
            launchCover.dismiss(animated: false)
            presentPlaceholder(.empty) { placeholder.showEmpty() }
        }
    }

    /// M1: the incoming terminal dissolves in (presentation only; its model opacity stays 1).
    /// Never crossfades two live surfaces: the outgoing one is already hidden.
    func fadeIn(_ terminal: NSView) {
        terminal.layer?.add(Motion.basic("opacity", from: 0, to: 1, duration: 0.10, timing: Motion.out), forKey: "switch.fade")
    }

    // MARK: Launch cover

    /// Shows the cover for the shown session while it launches, otherwise hides it (crossfade when
    /// `animated`: the agent just showed up).
    func updateLaunchCover(animated: Bool, entrance: Bool = false) {
        // The cover spans the card: never over sessions sharing it.
        guard let sel = shownSession, let ls = manager.live[sel], let launch = ls.launch,
              manager.sideBySide(sel).count == 1 else {
            launchCover.dismiss(animated: animated && Motion.shouldAnimate(launchCover))
            return
        }
        guard launchCover.session != sel || !launchCover.isShowing else { return }
        let cwd = ls.status.cwd ?? manager.workspace.sessions[sel]?.cwd ?? NSHomeDirectory()
        launchCover.show(session: sel, kind: launch.kind, agent: launch.agent, cwd: cwd, entrance: entrance)
    }

    /// A session's status changed: the shown one may have finished launching.
    func sessionStatusChanged(_ id: UUID) {
        guard id == shownSession, (manager.live[id]?.launch != nil) != launchCover.isShowing else { return }
        updateLaunchCover(animated: true)
    }

    /// Click on the cover: show the terminal now and put focus in it.
    func revealLaunch() {
        guard let sel = shownSession else { return }
        manager.launchReady(sel)
        focusTerminal()
    }

    func focusTerminal() {
        guard let sel = manager.workspace.selected, let t = manager.focusedTerminal(sel) else { return }
        view.window?.makeFirstResponder(t.view)
    }

    // MARK: Split panes

    /// What a session shows in the stack: its split host, else its terminal view.
    func hostView(_ id: UUID) -> NSView? {
        splitHosts[id] ?? manager.live[id]?.terminal.view
    }

    /// The card session `id` shows on: its holder's when that card is built, else its own.
    func hostId(_ id: UUID) -> UUID {
        if let owner = manager.layoutOwner(of: id), splitHosts[owner] != nil { return owner }
        return id
    }

    /// Every terminal on `id`'s card: its own, the panes' and other sessions' on it.
    func terminals(of id: UUID) -> [TerminalSurface] {
        guard let main = manager.live[id]?.terminal else { return [] }
        let others = (manager.paneLayouts[id]?.leaves ?? []).filter { $0 != id }
        return [main] + others.compactMap { manager.panes[$0]?.terminal ?? manager.live[$0]?.terminal }
    }

    /// A session's panes changed: rebuild its host from the layout (views move, terminals stay
    /// alive), place what left the split (a closed layout, a promoted pane) and focus the session's
    /// focused terminal when it is the one shown.
    func panesChanged(_ owner: UUID) {
        _ = view
        // Focus goes back into the card only if it was there (or nowhere): never out of the sidebar.
        let responder = view.window?.firstResponder
        let focusOnCard = responder == nil || responder === view.window
            || (responder as? NSView).map { r in terminals(of: owner).contains { r === $0.view || r.isDescendant(of: $0.view) } } ?? false
        let old = splitHosts.removeValue(forKey: owner)
        if let layout = manager.paneLayouts[owner], manager.live[owner] != nil {
            // Built hidden: showSelected reveals it (and every terminal in it) only if it is shown.
            let host = NSView(frame: stack.bounds)
            host.autoresizesSubviews = true
            host.isHidden = true
            if let content = buildPanes(layout, owner: owner, frame: host.bounds) { host.addSubview(content) }
            stack.addSubview(host)
            splitHosts[owner] = host
            terminals(of: owner).forEach { $0.setVisible(false) }
        }
        old?.removeFromSuperview()
        showSelected(focus: false)
        if focusOnCard, let sel = shownSession, hostId(sel) == owner || sel == owner, let t = manager.focusedTerminal(sel) {
            view.window?.makeFirstResponder(t.view)
        }
    }

    private func buildPanes(_ layout: PaneLayout, owner: UUID, frame: NSRect) -> NSView? {
        switch layout {
        case .leaf(let id):
            guard let v = manager.panes[id]?.terminal.view ?? manager.live[id]?.terminal.view else { return nil }
            v.frame = frame
            v.autoresizingMask = [.width, .height]
            v.isHidden = false
            return v
        case .split(_, let a, let b) where !Self.present(a, manager) || !Self.present(b, manager):
            // A session not started yet (restoring) or gone: the other side takes the space.
            return Self.present(a, manager) ? buildPanes(a, owner: owner, frame: frame)
                : Self.present(b, manager) ? buildPanes(b, owner: owner, frame: frame) : nil
        case .split(let sideBySide, let a, let b):
            let split = PaneSplitView(frame: frame)
            split.isVertical = sideBySide
            split.dividerStyle = .thin
            split.autoresizingMask = [.width, .height]
            let d = split.dividerThickness
            let local = NSRect(origin: .zero, size: frame.size)
            let (fa, fb): (NSRect, NSRect)
            if sideBySide {
                let w = (local.width - d) / 2
                fa = NSRect(x: 0, y: 0, width: w, height: local.height)
                fb = NSRect(x: w + d, y: 0, width: local.width - w - d, height: local.height)
            } else {
                let h = (local.height - d) / 2
                fa = NSRect(x: 0, y: 0, width: local.width, height: h)
                fb = NSRect(x: 0, y: h + d, width: local.width, height: local.height - h - d)
            }
            for (sub, f) in [(a, fa), (b, fb)] {
                if let v = buildPanes(sub, owner: owner, frame: f) { split.addSubview(v) }
            }
            split.adjustSubviews()
            return split
        }
    }

    /// The terminals on `owner`'s card as laid out now (unit square of the host, y down): dragged
    /// dividers count, leaves not shown (a session still starting) are left out. Nil before layout.
    func cardBoxes(_ owner: UUID) -> [UUID: PaneBox]? {
        guard let host = splitHosts[owner], let layout = manager.paneLayouts[owner] else { return nil }
        let b = host.bounds
        guard b.width > 0, b.height > 0 else { return nil }
        var out: [UUID: PaneBox] = [:]
        for leaf in layout.leaves {
            guard let v = manager.panes[leaf]?.terminal.view ?? manager.live[leaf]?.terminal.view,
                  v.isDescendant(of: host), !v.isHidden else { continue }
            let r = v.convert(v.bounds, to: host)
            guard r.width > 0, r.height > 0 else { return nil }
            let top = host.isFlipped ? r.minY - b.minY : b.maxY - r.maxY
            out[leaf] = PaneBox(x: (r.minX - b.minX) / b.width, y: top / b.height, width: r.width / b.width, height: r.height / b.height)
        }
        return out.isEmpty ? nil : out
    }

    /// Some terminal of `layout` exists.
    private static func present(_ layout: PaneLayout, _ manager: SessionManager) -> Bool {
        layout.leaves.contains { manager.panes[$0] != nil || manager.live[$0] != nil }
    }

    func showClosed(_ record: SessionRecord) {
        hideTerminals()
        presentPlaceholder(.closed(record.id)) {
            placeholder.showClosed(record) { [weak self] in self?.manager.reopen(record.id) }
        }
    }

    func showBackground(_ agent: BackgroundAgent) {
        hideTerminals()
        presentPlaceholder(.background(agent.id)) {
            placeholder.showBackground(agent) { [weak self] in self?.manager.attach(agent) }
        }
    }

    /// Background jobs changed: refill the open background page in place when its job did (state,
    /// needs, last change). No entrance animation, and unchanged text keeps any selection.
    func refreshBackground(_ agents: [BackgroundAgent]) {
        guard !placeholder.isHidden, case .background(let id)? = placeholder.page,
              let agent = agents.first(where: { $0.id == id }), agent != placeholder.shownBackground else { return }
        presentPlaceholder(.background(id)) {
            placeholder.showBackground(agent) { [weak self] in self?.manager.attach(agent) }
        }
    }

    /// Fills the placeholder; M2 entrance only when it replaces a terminal or changes page kind.
    private func presentPlaceholder(_ page: PlaceholderView.Page, _ fill: () -> Void) {
        let changed = placeholder.isHidden || placeholder.page != page
        let entering = Self.placeholderEnters(hidden: placeholder.isHidden, current: placeholder.page, next: page)
        // Any page change counts as a switch for the 150 ms key-repeat throttle (shared with M1).
        let allowed = changed && Motion.switchFadeAllowed()
        fill()
        placeholder.isHidden = false
        if entering, allowed { placeholder.playEntrance() }
    }

    /// M2 scope (§4.2: terminal ↔ placeholder): the placeholder appears, or switches between the
    /// empty state and a preview. Moving between previews (arrowing through closed or background
    /// rows) refreshes in place, so keyboard scrubbing stays instant (principle 4).
    static func placeholderEnters(hidden: Bool, current: PlaceholderView.Page?, next: PlaceholderView.Page) -> Bool {
        guard !hidden, let current else { return true }
        return (current == .empty) != (next == .empty)
    }

    private func hideTerminals() {
        _ = view
        for id in manager.live.keys {
            guard hostId(id) == id, let v = hostView(id) else { continue }
            if !v.isHidden {
                v.isHidden = true
                terminals(of: id).forEach { $0.setVisible(false) }
            }
            if !v.autoresizingMask.isEmpty { v.autoresizingMask = [] }
        }
        if findBar.isPresented || findTarget != nil { endFind() }
        shownSession = nil
        shownHost = nil
        launchCover.dismiss(animated: false)
    }

    // MARK: Find in scrollback

    func findAction(_ action: TerminalAction, terminal: TerminalSurface) {
        _ = view
        // Late search actions from a surface whose search was already ended (switch, placeholder)
        // must not touch the bar now serving another terminal.
        let current = findTarget == nil || findTarget === terminal
        switch action {
        case .startSearch(let needle):
            findTarget = terminal
            findBar.show(needle: needle)
        case .endSearch where current:
            hideFind()
        case .searchTotal(let n) where current:
            findBar.total = n
        case .searchSelected(let n) where current:
            findBar.selected = n
        default:
            break
        }
    }

    var findTargetSession: UUID? { findTarget?.sessionId }

    /// Ghostty already ended the search (`.endSearch`): just hide the bar.
    private func hideFind() {
        findBar.dismiss()
        if let t = findTarget, !t.view.isHiddenOrHasHiddenAncestor { view.window?.makeFirstResponder(t.view) }
        findTarget = nil
    }

    /// Ends the search on the target surface too, so its match highlights never outlive the bar
    /// (close button, Esc, session switch, placeholder page).
    private func endFind() {
        findTarget?.perform(binding: "end_search")
        hideFind()
    }
}

// MARK: Sessions dropped beside the shown one

extension TerminalContainerViewController: CardDropTarget {
    /// The open session a sidebar drag carries when it can join the shown session's card.
    func droppableSession(_ token: String?) -> UUID? {
        guard let token, token.hasPrefix("s:"), let id = UUID(uuidString: String(token.dropFirst(2))),
              let sel = shownSession, sel != id, manager.live[sel] != nil, manager.live[id] != nil,
              !manager.sideBySide(sel).contains(id) else { return nil }
        return id
    }

    /// The card's side nearest to `point` (stack coordinates, y up).
    static func dropSide(_ point: NSPoint, in bounds: NSRect) -> SplitDirection {
        let dx = (point.x - bounds.midX) / max(bounds.width, 1)
        let dy = (point.y - bounds.midY) / max(bounds.height, 1)
        if abs(dx) >= abs(dy) { return dx < 0 ? .left : .right }
        return dy > 0 ? .up : .down
    }

    /// The half of the terminal area `side` takes (card coordinates).
    func dropFrame(_ side: SplitDirection) -> NSRect {
        let r = stack.frame.insetBy(dx: 4, dy: 4)
        switch side {
        case .left: return NSRect(x: r.minX, y: r.minY, width: r.width / 2, height: r.height)
        case .right: return NSRect(x: r.midX, y: r.minY, width: r.width / 2, height: r.height)
        case .up: return NSRect(x: r.minX, y: r.midY, width: r.width, height: r.height / 2)
        case .down: return NSRect(x: r.minX, y: r.minY, width: r.width, height: r.height / 2)
        }
    }

    /// A drag over the card at `point` (card coordinates): previews where the session goes.
    func dragOver(token: String?, at point: NSPoint) -> NSDragOperation {
        guard let id = droppableSession(token) else {
            dropPreview.hide()
            return []
        }
        let side = Self.dropSide(card.convert(point, to: stack), in: stack.bounds)
        dropPreview.show(side, frame: dropFrame(side), title: manager.workspace.sessions[id]?.displayTitle ?? "")
        return .move
    }

    /// Drops the session on the previewed side.
    func drop(token: String?, at point: NSPoint) -> Bool {
        defer { dropPreview.hide() }
        guard let id = droppableSession(token), let sel = shownSession else { return false }
        let side = Self.dropSide(card.convert(point, to: stack), in: stack.bounds)
        manager.showBeside(id, of: sel, direction: side)
        return true
    }

    func cardDrag(_ info: NSDraggingInfo) -> NSDragOperation {
        dragOver(token: info.draggingPasteboard.string(forType: SidebarViewController.dragType),
                 at: card.convert(info.draggingLocation, from: nil))
    }

    func cardDragEnded() { dropPreview.hide() }

    func cardDrop(_ info: NSDraggingInfo) -> Bool {
        drop(token: info.draggingPasteboard.string(forType: SidebarViewController.dragType),
             at: card.convert(info.draggingLocation, from: nil))
    }
}

/// Divider between split panes: a hairline in the card's colors.
final class PaneSplitView: NSSplitView {
    override var dividerThickness: CGFloat { 1 }
    override var dividerColor: NSColor { Theme.ramp(.card).hairline }
}
