import AppKit
import CorralCore

struct StatusVisual: Equatable {
    var activity: Activity
    var unread: Bool
    var agent: AgentKind
    /// Quiet styling (closed rows): quaternary idle glyph.
    var quiet = false
}

/// Status glyph left of a session name (spec §3.5). Shape, size and motion carry the state, not hue alone:
/// needs input (amber bubble, 16 wide, halo + L2 ping) > error (red triangle, 14) > done-unread disc = working
/// ring (12) > calm glyphs (9–11).
///
///     view.layer (AppKit-owned, never transformed)
///      └ stage (pops)  ├ halo  ├ track  ├ arc (L1)  ├ disc └ check  └ glyph
///
/// Every layer is created once, switched with `isHidden`, and has no implicit actions. Only the working
/// spin (L1) and the needs-input ping (L2) loop, and only while the icon can be seen; everything else is a
/// one-shot from the model value.
final class StatusIconView: NSView {
    /// What is drawn. Several visuals share a look (unread does not matter while working).
    enum Look: Hashable {
        case needsInput, error, doneUnread, working, exited
        case doneSeen(quiet: Bool)
        case idle(AgentKind, quiet: Bool)

        init(_ v: StatusVisual) {
            switch v.activity {
            case .needsInput: self = .needsInput
            case .error: self = .error
            case .done: self = v.unread ? .doneUnread : .doneSeen(quiet: v.quiet)
            case .working: self = .working
            case .exited: self = .exited
            case .idle: self = .idle(v.agent, quiet: v.quiet)
            }
        }

        var label: String {
            switch self {
            case .needsInput: return "Needs input"
            case .error: return "Error"
            case .doneUnread: return "Done, unread"
            case .working: return "Working"
            case .doneSeen: return "Done"
            case .exited: return "Exited"
            case .idle: return "Idle"
            }
        }

        var parts: Parts {
            switch self {
            case .needsInput: return [.halo, .glyph]
            case .working: return .ring
            case .doneUnread: return .disc
            case .error, .doneSeen, .exited, .idle: return .glyph
            }
        }

        /// Calm states arrive with a plain crossfade (M16); the rest have their own entrance.
        func crossfades(from old: Look) -> Bool {
            switch self {
            case .idle, .exited: return true
            case .doneSeen: return old != .doneUnread
            default: return false
            }
        }
    }

    struct Parts: OptionSet {
        let rawValue: Int
        static let halo = Parts(rawValue: 1)
        static let ring = Parts(rawValue: 2)
        static let disc = Parts(rawValue: 4)
        static let glyph = Parts(rawValue: 8)
    }

    static let spinKey = "L1"
    static let pingKey = "L2"
    static let spinPeriod: CFTimeInterval = 1.0
    static let pingPeriod: CFTimeInterval = 1.6
    /// A transition closer than this to the previous one (same icon, same session) is a flapping burst and snaps.
    static let flapWindow: CFTimeInterval = 0.25
    /// Halo fill: amber at α 0.40. Ping, burst and static halo are layer opacities on top of it, so their
    /// effective alphas are 0.16 (ping peak), 0.20 (burst) and 0.12 (static).
    static let haloAlpha: CGFloat = 0.40
    /// Static halo (selected row in the key window, Reduce Motion): scale and layer opacity.
    static let staticHalo: (scale: CGFloat, opacity: Float) = (1.25, 0.30)
    /// Slots at or above this size (preview tiles) draw no halo by default.
    static let haloMaxSlot: CGFloat = 20

    /// 16 in session rows, 14 in compact rows, 28 in preview tiles; every metric scales by slot / 16.
    let slot: CGFloat
    /// Ramp for the calm glyph colors (`.card` inside preview tiles).
    var surface: Surface = .chrome { didSet { if oldValue != surface { refreshArt() } } }
    /// Selected row in the key window: the halo stays static and L2 does not run.
    var haloSuppressed = false { didSet { if oldValue != haloSuppressed { haloSuppressionChanged() } } }
    /// Whether needs input draws a halo at all (static, L2 or burst). Off by default for preview tiles: the
    /// sidebar row already pings for that agent, and the rule is one L2 per waiting thing (§4.3).
    var showsHalo: Bool { didSet { if oldValue != showsHalo { haloVisibilityChanged() } } }
    private(set) var loopsPaused = false
    private(set) var visual: StatusVisual?
    private(set) var look: Look?
    /// Testing only: treats the window as visible, so transitions and loops run without showing a window.
    var forceOnScreen = false { didSet { if oldValue != forceOnScreen { syncLoops() } } }

    let stage = CALayer()
    let halo = CALayer()
    let track = CALayer()
    let arc = CALayer()
    let disc = CALayer()
    let check = CAShapeLayer()
    let glyph = CALayer()
    var allLayers: [CALayer] { [stage, halo, track, arc, disc, check, glyph] }

    private var lastSession: UUID?
    /// When this icon last ran a transition for `lastSession` (flapping guard).
    private(set) var lastTransitionAt: CFTimeInterval?
    /// Bumped by every snap/transition so a stale fade completion leaves newer state alone.
    private(set) var generation = 0
    /// Layers fading out after a transition; hidden when the fade completes.
    private(set) var outgoing: [CALayer] = []
    /// Resolved glyph bitmaps per look for the current theme, surface and scale: a status change is one
    /// dictionary hit. Cleared whenever any of those change.
    private var art: [Look: CGImage] = [:]
    /// Backing scale the art was last built for (0 = never).
    private(set) var artScale: CGFloat = 0
    /// Registered in `loopers` (the look wants a loop).
    private var isLooper = false

    private static let noActions: [String: CAAction] = Dictionary(uniqueKeysWithValues: [
        "position", "bounds", "frame", "anchorPoint", "transform", "opacity", "hidden", "contents", "contentsScale",
        "backgroundColor", "borderColor", "borderWidth", "cornerRadius", "strokeColor", "fillColor", "strokeEnd",
        "path", "lineWidth", "sublayers", "onOrderIn", "onOrderOut",
    ].map { ($0, NSNull() as CAAction) })

    init(slot: CGFloat = 16) {
        self.slot = slot
        self.showsHalo = slot < Self.haloMaxSlot
        super.init(frame: NSRect(x: 0, y: 0, width: slot, height: slot))
        setUp()
    }

    override convenience init(frame frameRect: NSRect) {
        let side = min(frameRect.width, frameRect.height)
        self.init(slot: side > 0 ? side : 16)
        frame = frameRect
    }

    required init?(coder: NSCoder) { fatalError() }

    deinit { NotificationCenter.default.removeObserver(self) }

    private func setUp() {
        wantsLayer = true
        clipsToBounds = false
        layer?.masksToBounds = false
        setAccessibilityElement(true)
        setAccessibilityRole(.image)
        let k = slot / 16
        let mid = CGPoint(x: slot / 2, y: slot / 2)
        func place(_ l: CALayer, _ side: CGFloat) {
            l.bounds = CGRect(x: 0, y: 0, width: side, height: side)
            l.position = mid
        }
        for l in allLayers { l.actions = Self.noActions }
        place(stage, slot)
        place(halo, 16 * k)
        halo.cornerRadius = 8 * k
        halo.opacity = 0
        place(track, 12 * k)
        track.cornerRadius = 6 * k
        track.borderWidth = 1.75 * k
        place(arc, slot)
        arc.contentsGravity = .resize
        place(disc, 12 * k)
        disc.cornerRadius = 6 * k
        check.frame = disc.bounds
        check.path = Self.checkPath(k)
        check.lineWidth = 1.6 * k
        check.lineCap = .round
        check.lineJoin = .round
        check.fillColor = nil
        disc.addSublayer(check)
        place(glyph, StatusIconArt.canvas(slot))
        glyph.contentsGravity = .resize
        for l in [halo, track, arc, disc, glyph] {
            l.isHidden = true
            stage.addSublayer(l)
        }
        layer?.addSublayer(stage)
        applyColors()
        let nc = NotificationCenter.default
        nc.addObserver(self, selector: #selector(themeChanged), name: .corralThemeDidChange, object: nil)
        nc.addObserver(self, selector: #selector(motionChanged), name: .corralMotionChanged, object: nil)
    }

    /// Check mark in the 12 pt disc: M(3.6, 6.2) L(5.3, 7.9) L(8.5, 4.4), given top-down, drawn in y-up layer space.
    private static func checkPath(_ k: CGFloat) -> CGPath {
        let p = CGMutablePath()
        p.move(to: CGPoint(x: 3.6 * k, y: (12 - 6.2) * k))
        p.addLine(to: CGPoint(x: 5.3 * k, y: (12 - 7.9) * k))
        p.addLine(to: CGPoint(x: 8.5 * k, y: (12 - 4.4) * k))
        return p
    }

    override var intrinsicContentSize: NSSize { NSSize(width: slot, height: slot) }

    override func layout() {
        super.layout()
        centerStage()
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        centerStage()
    }

    private func centerStage() {
        Motion.quiet { stage.position = CGPoint(x: bounds.midX, y: bounds.midY) }
    }

    // MARK: State

    /// Shows `v`. Animates only for the same session, a changed look, on screen, and outside a flapping burst;
    /// otherwise it snaps and re-adds just the loop the new look needs.
    func apply(_ v: StatusVisual, session: UUID?, animated: Bool) {
        let new = Look(v)
        let old = look
        // The flap history belongs to one session.
        if session != lastSession { lastTransitionAt = nil }
        let animate = old != nil && old != new && transitionAllowed(session: session, animated: animated)
        visual = v
        lastSession = session
        guard old != new else { return }
        look = new
        if animate, let old { transition(from: old, to: new) } else { snap(new) }
    }

    /// Unanimated convenience (tests, simple rows).
    func update(activity: Activity, unread: Bool, agent: AgentKind) {
        apply(StatusVisual(activity: activity, unread: unread, agent: agent), session: nil, animated: false)
    }

    /// The flapping rule is kept per icon rather than in the shared `Motion.flapping(session)`: a session can
    /// show in two icons at once (sidebar row and preview tile), and its row may consult `Motion.flapping` for
    /// the wash, so a shared record would make every second consumer of one update read as a flap.
    private func transitionAllowed(session: UUID?, animated: Bool) -> Bool {
        guard animated, Motion.enabled, forceOnScreen || Motion.shouldAnimate(self),
              let session, session == lastSession else { return false }
        let now = CACurrentMediaTime()
        defer { lastTransitionAt = now }
        return !Self.isFlap(last: lastTransitionAt, now: now)
    }

    /// True when a transition at `now` follows the previous one (`last`) within `flapWindow`.
    static func isFlap(last: CFTimeInterval?, now: CFTimeInterval) -> Bool {
        guard let last else { return false }
        return now - last < flapWindow
    }

    func setLoopsPaused(_ paused: Bool) {
        loopsPaused = paused
        syncLoops()
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        generation += 1
        for l in allLayers { l.removeAllAnimations() }
        Motion.quiet {
            if let look { configureLayers(for: look) }
            stage.transform = CATransform3DIdentity
        }
        outgoing.removeAll()
        lastSession = nil
        lastTransitionAt = nil
        look = nil
        visual = nil
        setLooper(false)
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        // Art built before the cell was attached assumed 2×; rebuild it for a window on another scale.
        if let scale = window?.backingScaleFactor, scale != artScale { refreshArt() }
        syncLoops()
    }

    override func viewDidHide() {
        super.viewDidHide()
        syncLoops()
    }

    override func viewDidUnhide() {
        super.viewDidUnhide()
        syncLoops()
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        refreshArt()
    }

    @objc private func themeChanged() { MainActor.assumeIsolated { refreshArt() } }

    @objc private func motionChanged() {
        MainActor.assumeIsolated {
            if let look { snap(look) }
        }
    }

    // MARK: Rendering

    private var scale: CGFloat { window?.backingScaleFactor ?? 2 }

    /// The halo is static whenever it must not ping: suppressed, Reduce Motion, or motion off.
    private var haloIsStatic: Bool { haloSuppressed || !Motion.full }

    /// The layers `look` shows on this icon (no halo when `showsHalo` is off).
    func parts(for look: Look) -> Parts {
        showsHalo ? look.parts : look.parts.subtracting(.halo)
    }

    private func applyColors() {
        let s = Theme.tokens.status
        let scale = scale
        artScale = scale
        for l in [arc, glyph, check] as [CALayer] { l.contentsScale = scale }
        halo.backgroundColor = s.needsInput.fill.withAlphaComponent(Self.haloAlpha).cgColor
        track.borderColor = s.working.fill.withAlphaComponent(0.25).cgColor
        disc.backgroundColor = s.done.fill.cgColor
        check.strokeColor = s.done.onFill.cgColor
        arc.contents = StatusIconArt.arc(color: s.working.fill, slot: slot, scale: scale)
    }

    private func applyGlyph(_ look: Look) {
        if let hit = art[look] {
            glyph.contents = hit
            return
        }
        guard let spec = Self.glyphSpec(look),
              let image = StatusIconArt.glyph(spec, colors: glyphColors(look), slot: slot, scale: scale) else { return }
        art[look] = image
        glyph.contents = image
    }

    private func refreshArt() {
        art.removeAll(keepingCapacity: true)
        Motion.quiet {
            applyColors()
            if let look { applyGlyph(look) }
        }
    }

    /// Halo visibility and its resting model value: static form, or invisible while L2 (or nothing) drives it.
    private func applyHalo(_ look: Look) {
        let shown = parts(for: look).contains(.halo)
        let still = shown && haloIsStatic
        halo.isHidden = !shown
        halo.opacity = still ? Self.staticHalo.opacity : 0
        halo.transform = still ? CATransform3DMakeScale(Self.staticHalo.scale, Self.staticHalo.scale, 1) : CATransform3DIdentity
    }

    /// Final model state for `look`; callers wrap it in a transaction without implicit actions.
    private func configureLayers(for look: Look) {
        outgoing.removeAll()
        let p = look.parts
        track.isHidden = !p.contains(.ring)
        arc.isHidden = !p.contains(.ring)
        disc.isHidden = !p.contains(.disc)
        glyph.isHidden = !p.contains(.glyph)
        for l in [stage, track, arc, disc, glyph] {
            l.opacity = 1
            l.transform = CATransform3DIdentity
        }
        check.strokeEnd = 1
        applyHalo(look)
        if p.contains(.glyph) { applyGlyph(look) }
        setAccessibilityLabel(look.label)
    }

    private func removeOneShots() {
        for l in allLayers {
            for key in l.animationKeys() ?? [] where key != Self.spinKey && key != Self.pingKey {
                l.removeAnimation(forKey: key)
            }
        }
    }

    private func snap(_ look: Look) {
        generation += 1
        Motion.quiet {
            removeOneShots()
            configureLayers(for: look)
        }
        syncLoops()
    }

    // MARK: Loops

    /// Loops run only where they can be seen: full motion, not paused, attached, not hidden, window visible.
    var loopsAllowed: Bool {
        guard Motion.full, !loopsPaused, let window, !isHiddenOrHasHiddenAncestor else { return false }
        return forceOnScreen || window.occlusionState.contains(.visible)
    }

    /// Adds the loop the look needs (phase-synced) and removes the others. `pingDelay` starts L2 on the
    /// first period boundary after the delay, so it follows an entrance burst cleanly.
    private func syncLoops(pingDelay: CFTimeInterval? = nil) {
        let spin = look == .working
        let ping = look == .needsInput && showsHalo && !haloSuppressed
        setLooper(spin || ping)
        let allowed = (spin || ping) && loopsAllowed
        if allowed && spin {
            if arc.animation(forKey: Self.spinKey) == nil { arc.add(Self.spinLoop(), forKey: Self.spinKey) }
        } else {
            arc.removeAnimation(forKey: Self.spinKey)
        }
        if allowed && ping {
            if halo.animation(forKey: Self.pingKey) == nil { halo.add(pingLoop(delay: pingDelay), forKey: Self.pingKey) }
        } else {
            halo.removeAnimation(forKey: Self.pingKey)
        }
    }

    /// Icons whose look wants a loop. One shared observer re-syncs them when their window's occlusion
    /// changes (shown, covered, app hidden), so a cell configured while its window was not visible starts
    /// its loop once it is, without any per-view observer.
    private static let loopers = NSHashTable<StatusIconView>.weakObjects()
    private static var occlusionObserver: NSObjectProtocol?

    private func setLooper(_ on: Bool) {
        guard on != isLooper else { return }
        isLooper = on
        if on {
            Self.observeOcclusion()
            Self.loopers.add(self)
        } else {
            Self.loopers.remove(self)
        }
    }

    private static func observeOcclusion() {
        guard occlusionObserver == nil else { return }
        occlusionObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didChangeOcclusionStateNotification, object: nil, queue: nil
        ) { note in
            let window = note.object as? NSWindow
            MainActor.assumeIsolated { occlusionChanged(window) }
        }
    }

    /// Re-syncs the loops of every looping icon in `window`.
    static func occlusionChanged(_ window: NSWindow?) {
        guard let window else { return }
        for v in loopers.allObjects where v.window === window { v.syncLoops() }
    }

    static var looperCount: Int { loopers.allObjects.count }

    /// L1: the cached arc turns clockwise once per second.
    private static func spinLoop() -> CAAnimation {
        let a = CABasicAnimation(keyPath: "transform.rotation.z")
        a.fromValue = 0
        a.toValue = -2 * Double.pi
        a.timingFunction = CAMediaTimingFunction(name: .linear)
        return Motion.loop(a, period: spinPeriod)
    }

    /// L2: the halo grows 1 → 1.6 while its layer opacity fades 0.40 → 0 over the first 1.1 s of each 1.6 s period.
    private func pingLoop(delay: CFTimeInterval?) -> CAAnimation {
        let grow = CABasicAnimation(keyPath: "transform.scale")
        grow.fromValue = 1
        grow.toValue = 1.6
        grow.timingFunction = Motion.out
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = 0.40
        fade.toValue = 0
        fade.timingFunction = CAMediaTimingFunction(controlPoints: 0.3, 0, 0.6, 1)
        for a in [grow, fade] {
            a.duration = 1.1
            a.fillMode = .forwards
        }
        let group = CAAnimationGroup()
        group.animations = [grow, fade]
        let loop = Motion.loop(group, period: Self.pingPeriod)
        if let delay {
            let start = ((CACurrentMediaTime() + delay) / Self.pingPeriod).rounded(.up) * Self.pingPeriod
            loop.timeOffset = 0
            loop.beginTime = halo.convertTime(start, from: nil)
        }
        return loop
    }

    private func haloSuppressionChanged() {
        guard look == .needsInput, showsHalo, Motion.full else { return }
        let animate = forceOnScreen || Motion.shouldAnimate(self)
        let from = halo.presentation() ?? halo
        let (opacity, transform) = (from.opacity, from.transform)
        Motion.quiet { applyHalo(.needsInput) }
        if animate {
            halo.add(Motion.basic("opacity", from: opacity, to: halo.opacity, duration: Motion.fast), forKey: "settle")
            halo.add(Motion.basic("transform", from: NSValue(caTransform3D: transform),
                                  to: NSValue(caTransform3D: halo.transform), duration: Motion.fast), forKey: "settle.scale")
        }
        syncLoops(pingDelay: animate ? Motion.fast : nil)
    }

    private func haloVisibilityChanged() {
        guard let look else { return }
        Motion.quiet {
            halo.removeAllAnimations()
            applyHalo(look)
        }
        syncLoops()
    }

    // MARK: Transitions (M10–M16)

    /// One-shot from `old` to `new`. The model is final first; animations run from fixed or presentation values.
    func transition(from old: Look, to new: Look) {
        generation += 1
        let gen = generation
        let full = Motion.full
        let haloNow = halo.presentation() ?? halo
        let arcNow = arc.presentation() ?? arc
        let (haloOpacity, haloTransform, arcTransform) = (haloNow.opacity, haloNow.transform, arcNow.transform)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        CATransaction.setCompletionBlock { [weak self] in
            MainActor.assumeIsolated { self?.finishOutgoing(gen) }
        }
        removeOneShots()
        configureLayers(for: new)
        if !full || new.crossfades(from: old) {
            let fade = CATransition()
            fade.type = .fade
            fade.duration = 0.15
            fade.timingFunction = Motion.std
            stage.add(fade, forKey: kCATransition)
        } else {
            let leaving = parts(for: old).subtracting(parts(for: new))
            // M15: the unread disc settles (shrinks and fades) into the quiet check.
            var settle = false
            if case .doneSeen = new, old == .doneUnread { settle = true }
            if leaving.contains(.halo) {
                halo.transform = haloTransform
                fadeOut(halo, from: haloOpacity, duration: Motion.fast)
            }
            if leaving.contains(.ring) {
                arc.transform = arcTransform
                fadeOut(track, duration: 0.10)
                fadeOut(arc, duration: 0.10)
            }
            if leaving.contains(.disc) {
                fadeOut(disc, duration: settle ? 0.20 : 0.10)
                if settle { disc.add(Motion.basic("transform.scale", from: 1, to: 0.8, duration: 0.20), forKey: "shrink") }
            }
            if leaving.contains(.glyph) { fadeOut(glyph, duration: 0.10) }
            enter(new)
        }
        CATransaction.commit()
        syncLoops(pingDelay: full && new == .needsInput ? 0.5 : nil)
    }

    private func fadeOut(_ l: CALayer, from opacity: Float = 1, duration: Double) {
        l.isHidden = false
        l.opacity = 0
        l.add(Motion.basic("opacity", from: opacity, to: 0, duration: duration, timing: Motion.exit), forKey: "out")
        outgoing.append(l)
    }

    private func enter(_ new: Look) {
        let pop = { (from: CGFloat) in Motion.spring("transform.scale", from: from, to: 1, duration: 0.30, bounce: 0.30) }
        switch new {
        case .working:
            stage.add(Motion.basic("transform.scale", from: 0.8, to: 1, duration: Motion.fast, timing: Motion.out), forKey: "pop")
            for l in [track, arc] {
                l.add(Motion.basic("opacity", from: 0, to: 1, duration: Motion.fast, timing: Motion.out), forKey: "in")
            }
        case .doneUnread:
            disc.add(pop(0.4), forKey: "pop")
            disc.add(Motion.basic("opacity", from: 0, to: 1, duration: Motion.micro, timing: Motion.out), forKey: "in")
            check.add(Motion.basic("strokeEnd", from: 0, to: 1, duration: 0.20, timing: Motion.out, delay: 0.06), forKey: "draw")
        case .needsInput:
            stage.add(pop(0.6), forKey: "pop")
            guard showsHalo else { break }
            if haloSuppressed {
                let s = Self.staticHalo
                halo.add(Motion.basic("opacity", from: 0, to: s.opacity, duration: 0.25, timing: Motion.out), forKey: "in")
                halo.add(Motion.basic("transform.scale", from: 1, to: s.scale, duration: 0.25, timing: Motion.out), forKey: "in.scale")
            } else {
                let grow = CABasicAnimation(keyPath: "transform.scale")
                grow.fromValue = 1
                grow.toValue = 1.9
                let fade = CABasicAnimation(keyPath: "opacity")
                fade.fromValue = 0.5
                fade.toValue = 0
                let burst = CAAnimationGroup()
                burst.animations = [grow, fade]
                burst.duration = 0.5
                burst.timingFunction = Motion.out
                halo.add(burst, forKey: "burst")
            }
        case .error:
            stage.add(pop(0.7), forKey: "pop")
            let k = Double(slot / 16)
            let shake = CAKeyframeAnimation(keyPath: "transform.translation.x")
            shake.values = [0, -2.5, 2.5, -1.5, 1.5, 0].map { $0 * k }
            shake.duration = 0.32
            shake.timingFunction = CAMediaTimingFunction(name: .easeOut)
            glyph.add(shake, forKey: "shake")
        case .doneSeen:
            glyph.add(Motion.basic("opacity", from: 0, to: 1, duration: 0.20), forKey: "in")
        case .exited, .idle:
            break
        }
    }

    /// Hides the layers that faded out, unless a newer state took over meanwhile.
    func finishOutgoing(_ gen: Int) {
        guard gen == generation else { return }
        Motion.quiet { for l in outgoing { l.isHidden = true } }
        outgoing.removeAll()
    }

    // MARK: Glyphs

    /// Symbol, configuration and the ink box it is fitted into (in 16 pt slot units). Rank by size:
    /// bubble 16 wide > triangle ≈ 14 > disc = ring 12 > calm glyphs ≤ 11.
    static func glyphSpec(_ look: Look) -> StatusIconArt.Spec? {
        switch look {
        case .needsInput:
            return .init(symbol: "questionmark.bubble.fill", size: 11.5, weight: .semibold, box: CGSize(width: 16, height: 15.5))
        case .error:
            return .init(symbol: "exclamationmark.triangle.fill", size: 11.5, weight: .semibold, box: CGSize(width: 14, height: 13.75))
        case .doneSeen:
            return .init(symbol: "checkmark", size: 9, weight: .bold, box: CGSize(width: 9, height: 9))
        case .exited:
            return .init(symbol: "stop.circle", size: 11, weight: .regular, box: CGSize(width: 11, height: 11))
        case .idle(let agent, _):
            let box: CGSize
            switch agent {
            case .shell: box = CGSize(width: 11, height: 9.5)
            case .claude: box = CGSize(width: 11, height: 11)
            case .opencode: box = CGSize(width: 11, height: 8)
            case .pi: box = CGSize(width: 10, height: 9)
            }
            return .init(symbol: cachedAgentSymbol(agent), size: 11, weight: .medium, box: box)
        case .working, .doneUnread:
            return nil
        }
    }

    private func glyphColors(_ look: Look) -> [NSColor] {
        let t = Theme.tokens
        let r = t.ramp(surface)
        switch look {
        case .needsInput: return [t.status.needsInput.onFill, t.status.needsInput.fill]
        case .error: return [t.status.error.onFill, t.status.error.fill]
        case .doneSeen(let quiet), .idle(_, let quiet): return [quiet ? r.quaternary : r.tertiary]
        case .exited: return [r.quaternary]
        case .working, .doneUnread: return []
        }
    }

    private static var agentSymbols: [AgentKind: String] = [:]

    /// `GlyphCache.agentSymbol` probes the symbol catalog for "pi"; resolve each agent once.
    private static func cachedAgentSymbol(_ agent: AgentKind) -> String {
        if let s = agentSymbols[agent] { return s }
        let s = GlyphCache.agentSymbol(agent)
        agentSymbols[agent] = s
        return s
    }

    // MARK: Static helpers (other views)

    static func agentSymbol(_ agent: AgentKind) -> String { cachedAgentSymbol(agent) }

    /// Symbol, themed color and accessibility label for a state, for views that draw a single image.
    static func style(activity: Activity, unread: Bool, agent: AgentKind) -> (String, NSColor, String) {
        let t = Theme.tokens
        let r = t.ramp(.chrome)
        let label = Look(StatusVisual(activity: activity, unread: unread, agent: agent)).label
        switch activity {
        case .needsInput: return ("questionmark.bubble.fill", t.status.needsInput.fill, label)
        case .working: return ("circle.dashed", t.status.working.fill, label)
        case .done: return unread ? ("checkmark.circle.fill", t.status.done.fill, label) : ("checkmark", r.tertiary, label)
        case .error: return ("exclamationmark.triangle.fill", t.status.error.fill, label)
        case .exited: return ("stop.circle", r.quaternary, label)
        case .idle: return (agentSymbol(agent), r.tertiary, label)
        }
    }
}

/// Bitmaps for the icon: SF Symbols (from `GlyphCache`) fitted by their ink box and optically centered on a
/// canvas a little larger than the slot (so antialiased edges of a slot-wide glyph are never clipped), and
/// the working arc. Cached per (art, slot, scale, colors); never built on a cache hit.
@MainActor
enum StatusIconArt {
    struct Spec: Hashable {
        var symbol: String
        var size: CGFloat
        var weight: NSFont.Weight
        /// Ink is scaled to fit this box (16 pt slot units).
        var box: CGSize

        func hash(into h: inout Hasher) {
            h.combine(symbol)
            h.combine(size)
            h.combine(weight)
            h.combine(box.width)
            h.combine(box.height)
        }
    }

    /// Glyph canvas margin around the slot, in whole points so the canvas stays on the pixel grid.
    static let pad: CGFloat = 2

    /// Side of a glyph bitmap (and of the glyph layer) for `slot`.
    static func canvas(_ slot: CGFloat) -> CGFloat { slot + 2 * pad }

    private struct Key: Hashable {
        var spec: Spec?
        var slot: CGFloat
        var scale: CGFloat
        var colors: [UInt32]
    }

    private struct InkKey: Hashable {
        var symbol: String
        var size: CGFloat
        var weight: NSFont.Weight
    }

    private static var images: [Key: CGImage] = [:]
    private static var inks: [InkKey: CGRect] = [:]
    private static let limit = 256

    static var count: Int { images.count }

    static func glyph(_ s: Spec, colors: [NSColor], slot: CGFloat, scale: CGFloat) -> CGImage? {
        let key = Key(spec: s, slot: slot, scale: scale, colors: colors.map(pack))
        if let hit = images[key] { return hit }
        guard let img = GlyphCache.image(s.symbol, size: s.size, weight: s.weight, colors: colors, scale: scale),
              let mono = GlyphCache.image(s.symbol, size: s.size, weight: s.weight, colors: [.black], scale: scale)
        else { return nil }
        let inkKey = InkKey(symbol: s.symbol, size: s.size, weight: s.weight)
        let ink = inks[inkKey] ?? inkBounds(size: mono.size) { mono.draw(in: CGRect(origin: .zero, size: mono.size)) }
        inks[inkKey] = ink
        let k = slot / 16
        let side = canvas(slot)
        let f = min(s.box.width * k / ink.width, s.box.height * k / ink.height)
        // Center the ink box, with its origin on the pixel grid so straight edges stay crisp.
        let x = ((side - ink.width * f) / 2 * scale).rounded() / scale - ink.minX * f
        let y = ((side - ink.height * f) / 2 * scale).rounded() / scale - ink.minY * f
        let rect = CGRect(x: x, y: y, width: mono.size.width * f, height: mono.size.height * f)
        return store(key, render(side: side, scale: scale) { _ in img.draw(in: rect) })
    }

    /// 110° arc on the 12 pt ring (1.75 pt, round caps) from 12 o'clock clockwise; L1 spins it.
    static func arc(color: NSColor, slot: CGFloat, scale: CGFloat) -> CGImage? {
        let key = Key(spec: nil, slot: slot, scale: scale, colors: [pack(color)])
        if let hit = images[key] { return hit }
        let k = slot / 16
        let width = 1.75 * k
        let cg = color.cgColor
        return store(key, render(side: slot, scale: scale) { ctx in
            ctx.setStrokeColor(cg)
            ctx.setLineWidth(width)
            ctx.setLineCap(.round)
            let start = CGFloat.pi / 2
            ctx.addArc(center: CGPoint(x: slot / 2, y: slot / 2), radius: 6 * k - width / 2,
                       startAngle: start, endAngle: start - 110 * .pi / 180, clockwise: true)
            ctx.strokePath()
        })
    }

    /// Bounding box (y-up points) of everything `draw` paints with alpha > 0.1, measured at 4×.
    static func inkBounds(size: CGSize, draw: () -> Void) -> CGRect {
        let s: CGFloat = 4
        let w = max(1, Int(ceil(size.width * s))), h = max(1, Int(ceil(size.height * s)))
        let full = CGRect(origin: .zero, size: size)
        guard let ctx = bitmap(w, h) else { return full }
        ctx.scaleBy(x: s, y: s)
        withContext(ctx, draw)
        guard let data = ctx.data else { return full }
        let px = data.assumingMemoryBound(to: UInt8.self)
        let stride = ctx.bytesPerRow
        var minX = w, maxX = -1, minRow = h, maxRow = -1
        for row in 0..<h {
            for x in 0..<w where px[row * stride + x * 4 + 3] > 25 {
                minX = min(minX, x)
                maxX = max(maxX, x)
                minRow = min(minRow, row)
                maxRow = max(maxRow, row)
            }
        }
        guard maxX >= 0 else { return full }
        // Memory row 0 is the top of the bitmap.
        return CGRect(x: CGFloat(minX) / s, y: CGFloat(h - 1 - maxRow) / s,
                      width: CGFloat(maxX - minX + 1) / s, height: CGFloat(maxRow - minRow + 1) / s)
    }

    private static func store(_ key: Key, _ image: CGImage?) -> CGImage? {
        guard let image else { return nil }
        if images.count >= limit { images.removeAll(keepingCapacity: true) }
        images[key] = image
        return image
    }

    private static func render(side: CGFloat, scale: CGFloat, _ draw: (CGContext) -> Void) -> CGImage? {
        let px = max(1, Int((side * scale).rounded()))
        guard let ctx = bitmap(px, px) else { return nil }
        ctx.scaleBy(x: scale, y: scale)
        withContext(ctx) { draw(ctx) }
        return ctx.makeImage()
    }

    private static func bitmap(_ w: Int, _ h: Int) -> CGContext? {
        CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                  space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
    }

    private static func withContext(_ ctx: CGContext, _ body: () -> Void) {
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: false)
        body()
        NSGraphicsContext.restoreGraphicsState()
    }

    private static func pack(_ c: NSColor) -> UInt32 {
        guard let s = c.usingColorSpace(.sRGB) else { return UInt32(truncatingIfNeeded: c.hash) }
        func byte(_ v: CGFloat) -> UInt32 { UInt32(max(0, min(255, (v * 255).rounded()))) }
        return byte(s.redComponent) << 24 | byte(s.greenComponent) << 16 | byte(s.blueComponent) << 8 | byte(s.alphaComponent)
    }
}
