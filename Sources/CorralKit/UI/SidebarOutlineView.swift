import AppKit
import CorralCore

/// Cells that follow their row's hover, selection and loop state (spec §3.4).
protocol SidebarCell: AnyObject {
    func setHovered(_ hovered: Bool, animated: Bool)
    /// Row selection or window key state changed (halo suppression, name emphasis).
    func rowStateChanged(selected: Bool, keyWindow: Bool)
    func setLoopsPaused(_ paused: Bool)
    /// 30 s clock: re-render relative times in place.
    func refreshTime(now: Date)
}

extension SidebarCell {
    func rowStateChanged(selected: Bool, keyWindow: Bool) {}
    func setLoopsPaused(_ paused: Bool) {}
    func refreshTime(now: Date) {}
}

/// Small one-shot Core Animation helpers shared by the sidebar views. Model values are set first
/// (inside `Motion.quiet`), then an explicit animation runs from the on-screen value.
enum SidebarFX {
    /// Tests only: run the animated branches without an on-screen window (offscreen and alpha-0
    /// windows always report as occluded). Nothing waits for these animations to finish.
    static var forceAnimations = false

    /// `Motion.shouldAnimate`, plus the test override.
    static func canAnimate(_ v: NSView) -> Bool {
        forceAnimations ? Motion.enabled : Motion.shouldAnimate(v)
    }

    /// Sets `alphaValue` and fades from the presentation opacity.
    static func fade(_ v: NSView, to alpha: CGFloat, duration: Double = Motion.micro, animated: Bool) {
        let changed = abs(v.alphaValue - alpha) > 0.001
        guard changed else { return }
        let from = v.layer?.presentation()?.opacity ?? Float(v.alphaValue)
        Motion.quiet { v.alphaValue = alpha }
        guard let layer = v.layer else { return }
        if animated {
            layer.add(Motion.basic("opacity", from: from, to: Float(alpha), duration: duration), forKey: "sidebar.fade")
        } else {
            layer.removeAnimation(forKey: "sidebar.fade")
        }
    }

    /// Centered scale on any layer (presentation only), e.g. 1 → 1.3 → 1.
    static func bump(_ layer: CALayer, peak: CGFloat, duration: Double = 0.3) {
        let a = CAKeyframeAnimation(keyPath: "transform")
        a.values = [centered(layer, 1), centered(layer, peak), centered(layer, 1)]
        a.keyTimes = [0, 0.4, 1]
        a.timingFunctions = [Motion.out, Motion.std]
        a.duration = duration
        layer.add(a, forKey: "sidebar.bump")
    }

    /// `T(c)·S·T(−c)`: scale about the visual center whatever the anchor point.
    static func centered(_ layer: CALayer, _ s: CGFloat) -> NSValue {
        let b = layer.bounds
        let cx = b.midX - layer.anchorPoint.x * b.width
        let cy = b.midY - layer.anchorPoint.y * b.height
        var m = CATransform3DMakeTranslation(cx, cy, 0)
        m = CATransform3DScale(m, s, s, 1)
        return NSValue(caTransform3D: CATransform3DTranslate(m, -cx, -cy, 0))
    }

    /// Text push (count changes): new value slides in from the top on increase. Fade under Reduce Motion.
    static func push(_ layer: CALayer, up: Bool, duration: Double = Motion.base) {
        let t = CATransition()
        if Motion.full {
            t.type = .push
            // Subtypes are in layer coordinates; flip them when the host is drawn top-down.
            let fromTop = layer.contentsAreFlipped() ? !up : up
            t.subtype = fromTop ? .fromTop : .fromBottom
        } else {
            t.type = .fade
        }
        t.duration = duration
        t.timingFunction = Motion.std
        layer.add(t, forKey: "sidebar.push")
    }

    /// Animates a color property from its on-screen value; `nil` targets fade to the same color at alpha 0.
    static func color(_ layer: CALayer, _ key: String, to target: CGColor?, duration: Double?) {
        let current: CGColor? = key == "borderColor" ? layer.borderColor : layer.backgroundColor
        let shown: CGColor? = layer.presentation().flatMap { key == "borderColor" ? $0.borderColor : $0.backgroundColor } ?? current
        let resolved = target ?? current?.copy(alpha: 0)
        if let c = current, let r = resolved, c == r { return }
        if current == nil, resolved == nil { return }
        Motion.quiet {
            if key == "borderColor" { layer.borderColor = resolved } else { layer.backgroundColor = resolved }
        }
        if let duration, let to = resolved {
            let from = shown ?? to.copy(alpha: 0)
            layer.add(Motion.basic(key, from: from, to: to, duration: duration), forKey: "sidebar.\(key)")
        } else {
            layer.removeAnimation(forKey: "sidebar.\(key)")
        }
    }

    /// Plain layer with every implicit action disabled.
    static func ownedLayer() -> CALayer {
        let l = CALayer()
        l.actions = quietActions
        return l
    }

    static let quietActions: [String: CAAction] = [
        "position": NSNull(), "bounds": NSNull(), "frame": NSNull(), "contents": NSNull(), "transform": NSNull(),
        "backgroundColor": NSNull(), "borderColor": NSNull(), "borderWidth": NSNull(), "opacity": NSNull(),
        "hidden": NSNull(), "cornerRadius": NSNull(), "shadowPath": NSNull(), "shadowOpacity": NSNull(),
        "sublayers": NSNull(), "onOrderIn": NSNull(), "onOrderOut": NSNull(),
    ]
}

/// Plain outline with our own row view: no system selection, custom cell geometry, hover tracking.
final class SidebarOutlineView: NSOutlineView {
    /// `.gap` drop feedback; set false to fall back to `.regular` (spec §5.15).
    static var gapFeedback = true
    /// Leading cell origin at level 0 and the trailing margin.
    static let margin: CGFloat = 14

    private(set) var hoveredRow = -1
    /// Full reloads so far (tests assert that structural ops avoid them).
    private(set) var reloadCount = 0
    /// Window key state changes (row recolor, hint dismissal).
    var onKeyChange: ((Bool) -> Void)?
    /// Window occlusion changes; true = visible again (catch-up for skipped clock ticks).
    var onOcclusionChange: ((Bool) -> Void)?
    private var tracking: NSTrackingArea?
    private var windowObservers: [NSObjectProtocol] = []

    func applyStyle() {
        style = .plain
        backgroundColor = .clear
        // `.regular` makes layer-backed row views add their own selection subview (ignoring
        // drawSelection); `.none` still sets isSelected on row views, and SidebarRowView draws it.
        selectionHighlightStyle = .none
        intercellSpacing = .zero
        indentationPerLevel = Self.margin
        rowSizeStyle = .custom
        floatsGroupRows = false
        // Typing never jumps between sessions by name: it belongs to the selected session (`onTyping`).
        allowsTypeSelect = false
        focusRingType = .none
        headerView = nil
        usesAutomaticRowHeights = false
        draggingDestinationFeedbackStyle = Self.gapFeedback ? .gap : .regular
    }

    // MARK: Geometry

    override func frameOfOutlineCell(atRow row: Int) -> NSRect { .zero }

    override func frameOfCell(atColumn column: Int, row: Int) -> NSRect {
        let base = super.frameOfCell(atColumn: column, row: row)
        let x = Self.cellX(level: effectiveLevel(row))
        return NSRect(x: x, y: base.minY, width: max(0, bounds.width - x - Self.margin), height: base.height)
    }

    static func cellX(level: Int) -> CGFloat { margin + margin * CGFloat(level) }

    /// Children of section headers sit at the header's level (§2.8).
    func effectiveLevel(_ row: Int) -> Int {
        let level = self.level(forRow: row)
        if let n = item(atRow: row) as? SidebarNode, n.kind.isPreview { return max(0, level - 1) }
        return max(0, level)
    }

    // MARK: Hover

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let t = NSTrackingArea(rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
                               owner: self, userInfo: nil)
        addTrackingArea(t)
        tracking = t
    }

    override func mouseMoved(with event: NSEvent) {
        super.mouseMoved(with: event)
        setHoveredRow(row(at: convert(event.locationInWindow, from: nil)))
    }

    override func mouseEntered(with event: NSEvent) {
        super.mouseEntered(with: event)
        guard event.trackingArea === tracking else { return }
        setHoveredRow(row(at: convert(event.locationInWindow, from: nil)))
    }

    override func mouseExited(with event: NSEvent) {
        super.mouseExited(with: event)
        guard event.trackingArea === tracking else { return }
        setHoveredRow(-1)
    }

    /// Moves the hover to `row` (-1 = none), toggling the old and new row views and cells.
    func setHoveredRow(_ row: Int, animated: Bool = true) {
        let next = row >= 0 && row < numberOfRows ? row : -1
        guard next != hoveredRow else { return }
        let old = hoveredRow
        hoveredRow = next
        if old >= 0, old < numberOfRows { applyHover(false, row: old, animated: animated) }
        if next >= 0 { applyHover(true, row: next, animated: animated) }
    }

    private func applyHover(_ on: Bool, row: Int, animated: Bool) {
        (rowView(atRow: row, makeIfNecessary: false) as? SidebarRowView)?.hovered = on
        (view(atColumn: 0, row: row, makeIfNecessary: false) as? SidebarCell)?.setHovered(on, animated: animated)
    }

    /// Clears hover on every attached row view and cell. Structural updates shift row indexes, so a stale
    /// `hoveredRow` would leave the fill and × on the wrong row (or swallow the next refresh).
    func resetHover() {
        enumerateAvailableRowViews { rv, _ in
            guard let srv = rv as? SidebarRowView else { return }
            srv.hovered = false
            (srv.cellView as? SidebarCell)?.setHovered(false, animated: false)
        }
        hoveredRow = -1
    }

    /// After scrolling or a structural change: hover follows the pointer without a mouse event.
    func refreshHoverFromMouse() {
        guard let w = window, w.isKeyWindow else { setHoveredRow(-1, animated: false); return }
        let p = convert(w.mouseLocationOutsideOfEventStream, from: nil)
        setHoveredRow(visibleRect.contains(p) ? row(at: p) : -1)
    }

    override func reloadData() {
        reloadCount += 1
        hoveredRow = -1
        super.reloadData()
    }

    // MARK: Focus and key state

    /// Text typed while the list has the keyboard; true when the selected session's terminal took it.
    var onTyping: ((NSEvent) -> Bool)?

    override func keyDown(with event: NSEvent) {
        if Self.isTyping(event), onTyping?(event) == true { return }
        super.keyDown(with: event)
    }

    /// Text, not a list key: no ⌘/⌃, no control characters (Return, Tab, Escape, Delete) and no
    /// function keys (arrows, Home, Page Down…). Option may be part of it (@ on many layouts).
    static func isTyping(_ event: NSEvent) -> Bool {
        let mods = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        guard mods.isDisjoint(with: [.command, .control]), let chars = event.characters, !chars.isEmpty else { return false }
        return chars.unicodeScalars.allSatisfy {
            !CharacterSet.controlCharacters.contains($0) && !(0xF700...0xF8FF).contains($0.value)
        }
    }

    override func becomeFirstResponder() -> Bool {
        let ok = super.becomeFirstResponder()
        refreshRowStates()
        return ok
    }

    override func resignFirstResponder() -> Bool {
        let ok = super.resignFirstResponder()
        refreshRowStates()
        return ok
    }

    override func viewWillMove(toWindow newWindow: NSWindow?) {
        super.viewWillMove(toWindow: newWindow)
        windowObservers.forEach { NotificationCenter.default.removeObserver($0) }
        windowObservers = []
        guard let newWindow else { return }
        windowObservers.append(NotificationCenter.default.addObserver(forName: NSWindow.didChangeOcclusionStateNotification,
                                                                      object: newWindow, queue: .main) { [weak self] note in
            MainActor.assumeIsolated {
                guard let w = note.object as? NSWindow else { return }
                self?.onOcclusionChange?(w.occlusionState.contains(.visible))
            }
        })
        for (name, key) in [(NSWindow.didBecomeKeyNotification, true), (NSWindow.didResignKeyNotification, false)] {
            windowObservers.append(NotificationCenter.default.addObserver(forName: name, object: newWindow, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.refreshRowStates()
                    if !key { self?.setHoveredRow(-1, animated: false) }
                    self?.onKeyChange?(key)
                }
            })
        }
    }

    deinit {
        windowObservers.forEach { NotificationCenter.default.removeObserver($0) }
    }

    /// Focus or key change: recolor instantly (no animation per §4.2).
    func refreshRowStates() {
        enumerateAvailableRowViews { rv, _ in (rv as? SidebarRowView)?.refreshInstantly() }
    }
}

/// Row background: an owned pill `fill` and a 3 pt `gutter`, never the system selection.
final class SidebarRowView: NSTableRowView {
    enum Kind { case session, folder, header, compact }
    enum Tone { case plain, attention }

    /// Fill precedence (§3.4), first match wins.
    enum FillState: Equatable {
        case none, header, dropTarget, attentionSelected, attention, selectedFocused, selectedKey, selectedInactive,
             companion, hovered
    }

    struct Look: Equatable {
        var fill: NSColor?
        var border: NSColor?
        var gutter: NSColor?
    }

    static let reuseID = NSUserInterfaceItemIdentifier("SidebarRowView")

    var kind: Kind = .session {
        didSet { if kind != oldValue { cause = .snap; needsLayout = true; needsDisplay = true } }
    }
    var tone: Tone = .plain {
        didSet { if tone != oldValue { cause = .tone; needsDisplay = true } }
    }
    var hovered = false {
        didSet { if hovered != oldValue { cause = .hover; needsDisplay = true } }
    }
    var dropTarget = false {
        didSet { if dropTarget != oldValue { cause = .drop; needsDisplay = true } }
    }
    /// On screen next to the selected session (they share a card): a quieter selection fill.
    var companion = false {
        didSet { if companion != oldValue { cause = .selection; needsDisplay = true } }
    }
    /// The item this row view shows; animations only run while it stays the same.
    weak var node: SidebarNode?

    let fill = SidebarFX.ownedLayer()
    let gutter = SidebarFX.ownedLayer()
    let hairline = SidebarFX.ownedLayer()

    private enum Cause { case snap, hover, selection, tone, drop }
    private var cause: Cause = .snap
    private weak var renderedNode: SidebarNode?
    private var rendered = false
    private(set) var state: FillState = .none
    private static var lastSelectionChange: CFTimeInterval = 0

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layerContentsRedrawPolicy = .onSetNeedsDisplay
        fill.cornerRadius = 8
        fill.cornerCurve = .continuous
        // A clear 1 px border is always present so the attention border can fade in and out.
        fill.borderWidth = 1
        fill.borderColor = NSColor.clear.cgColor
        fill.zPosition = -2
        gutter.cornerRadius = 1.5
        gutter.maskedCorners = [.layerMaxXMinYCorner, .layerMaxXMaxYCorner]
        gutter.zPosition = -1
        hairline.zPosition = -1
        hairline.isHidden = true
        for l in [fill, gutter, hairline] { layer?.addSublayer(l) }
    }

    required init?(coder: NSCoder) { fatalError() }

    override var isSelected: Bool {
        didSet {
            guard isSelected != oldValue else { return }
            cause = .selection
            needsDisplay = true
            syncCell()
        }
    }

    override var isEmphasized: Bool {
        didSet { if isEmphasized != oldValue { needsDisplay = true } }
    }

    override var isTargetForDropOperation: Bool {
        didSet { dropTarget = isTargetForDropOperation }
    }

    override var interiorBackgroundStyle: NSView.BackgroundStyle { .normal }
    override var wantsUpdateLayer: Bool { true }
    override func drawSelection(in dirtyRect: NSRect) {}
    override func drawBackground(in dirtyRect: NSRect) {}
    override func drawSeparator(in dirtyRect: NSRect) {}
    override func drawDraggingDestinationFeedback(in dirtyRect: NSRect) {}

    /// Window key / focus / theme changes recolor without animation.
    func refreshInstantly() {
        cause = .snap
        needsDisplay = true
        syncCell()
    }

    /// The cell view, if one is attached yet (`view(atColumn:)` throws before that).
    var cellView: NSView? { numberOfColumns > 0 ? view(atColumn: 0) as? NSView : nil }

    /// Tells the cell about selection and key state.
    func syncCell() {
        (cellView as? SidebarCell)?.rowStateChanged(selected: isSelected, keyWindow: window?.isKeyWindow ?? false)
    }

    private var hasKeyboardFocus: Bool {
        guard let w = window, w.isKeyWindow, let table = superview as? NSTableView else { return false }
        return w.firstResponder === table
    }

    static func fillState(kind: Kind, tone: Tone, selected: Bool, focused: Bool, windowKey: Bool,
                          hovered: Bool, dropTarget: Bool, companion: Bool = false) -> FillState {
        if kind == .header { return .header }
        if dropTarget { return .dropTarget }
        if tone == .attention { return selected ? .attentionSelected : .attention }
        if selected { return focused ? .selectedFocused : (windowKey ? .selectedKey : .selectedInactive) }
        if companion { return .companion }
        if hovered { return .hovered }
        return .none
    }

    static func look(_ state: FillState, _ t: ThemeTokens = Theme.tokens) -> Look {
        let r = t.ramp(.chrome)
        let amber = t.status.needsInput.fill
        switch state {
        case .none, .header:
            return Look()
        case .dropTarget:
            return Look(fill: t.accent.withAlphaComponent(0.16), border: t.accent.withAlphaComponent(0.55))
        case .attentionSelected:
            return Look(fill: t.status.washSelected, border: amber.withAlphaComponent(0.45), gutter: amber)
        case .attention:
            return Look(fill: t.status.wash, border: t.status.washBorder, gutter: amber)
        case .selectedFocused:
            return Look(fill: r.selected, gutter: t.accent)
        case .selectedKey:
            return Look(fill: r.selected)
        case .selectedInactive:
            return Look(fill: ColorMath.mix(RGB(t.chrome), RGB(r.selected), 0.6).color)
        case .companion:
            return Look(fill: ColorMath.mix(RGB(t.chrome), RGB(r.selected), 0.45).color)
        case .hovered:
            return Look(fill: r.hover)
        }
    }

    override func updateLayer() {
        let next = Self.fillState(kind: kind, tone: tone, selected: isSelected, focused: hasKeyboardFocus,
                                  windowKey: window?.isKeyWindow ?? false, hovered: hovered, dropTarget: dropTarget,
                                  companion: companion)
        let look = Self.look(next)
        let sameItem = rendered && renderedNode === node
        let animate = sameItem && cause != .snap && next != state && SidebarFX.canAnimate(self)

        var fillDuration: Double?
        var gutterDuration: Double?
        if animate {
            switch cause {
            case .hover:
                fillDuration = hovered ? Motion.micro : 0.16
            case .selection:
                let now = CACurrentMediaTime()
                fillDuration = now - Self.lastSelectionChange < 0.15 ? Motion.micro : Motion.fast
                Self.lastSelectionChange = now
                gutterDuration = fillDuration
            case .tone:
                fillDuration = tone == .attention ? Motion.base : 0.20
                gutterDuration = tone == .attention ? nil : Motion.fast
            case .drop:
                fillDuration = 0.10
            case .snap:
                break
            }
        }

        SidebarFX.color(fill, "backgroundColor", to: look.fill?.cgColor, duration: fillDuration)
        SidebarFX.color(fill, "borderColor", to: look.border?.cgColor, duration: fillDuration)

        let gutterWasShown = gutter.backgroundColor.map { $0.alpha > 0 } ?? false
        SidebarFX.color(gutter, "backgroundColor", to: look.gutter?.cgColor, duration: gutterDuration)
        if animate, cause == .tone, tone == .attention, look.gutter != nil, !gutterWasShown, Motion.full {
            // M12: the gutter grows from its center (snappy spring).
            gutter.add(Motion.spring("transform.scale.y", from: 0, to: 1), forKey: "sidebar.grow")
        }

        Motion.quiet {
            hairline.isHidden = kind != .header
            hairline.backgroundColor = Theme.ramp(.chrome).hairline.cgColor
        }

        state = next
        renderedNode = node
        rendered = true
        cause = .snap
    }

    /// M6 arrival tint: accent α 0.18 fading out over the resting fill.
    func flashArrival() {
        guard SidebarFX.canAnimate(self) else { return }
        let to = fill.backgroundColor ?? Theme.tokens.accent.withAlphaComponent(0).cgColor
        let a = Motion.basic("backgroundColor", from: Theme.tokens.accent.withAlphaComponent(0.18).cgColor, to: to,
                             duration: 0.6, timing: Motion.out, delay: 0.1)
        fill.add(a, forKey: "sidebar.arrival")
    }

    override func layout() {
        super.layout()
        let h = bounds.height
        let g = max(10, h - 16)
        // Our sublayers live in the backing layer's space; ask CA which way y points.
        let flipped = layer?.contentsAreFlipped() ?? isFlipped
        Motion.quiet {
            fill.frame = bounds.insetBy(dx: 6, dy: 1)
            gutter.frame = CGRect(x: 0, y: (h - g) / 2, width: 3, height: g)
            hairline.frame = CGRect(x: SidebarOutlineView.margin, y: flipped ? 4 : h - 5,
                                    width: max(0, bounds.width - 2 * SidebarOutlineView.margin), height: 1)
        }
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        for l in [fill, gutter] { l.removeAllAnimations() }
        hovered = false
        dropTarget = false
        cause = .snap
    }
}
