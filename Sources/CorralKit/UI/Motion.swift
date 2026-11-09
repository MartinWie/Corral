import AppKit

/// Animation policy and helpers. Everything is Core Animation driven; nothing redraws on a timer.
/// Rules: set the final model value inside `quiet`, then add an explicit animation from the
/// presentation value; never touch AppKit backing-layer geometry; only the working (L1) and
/// needs-input (L2) loops run forever.

enum Motion {
    /// Tests and snapshots switch this off.
    static var enabled = true
    private(set) static var reduced = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    static var full: Bool { enabled && !reduced }

    static let micro = 0.08, fast = 0.12, base = 0.18, slow = 0.26
    static let std = CAMediaTimingFunction(controlPoints: 0.2, 0, 0, 1)
    static let out = CAMediaTimingFunction(controlPoints: 0.16, 1, 0.3, 1)
    static let exit = CAMediaTimingFunction(controlPoints: 0.4, 0, 1, 1)

    private static var observer: NSObjectProtocol?

    /// Call once at startup: tracks Reduce Motion / Increase Contrast changes.
    static func observeAccessibility() {
        guard observer == nil else { return }
        observer = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification, object: nil, queue: .main
        ) { _ in
            do {
                reduced = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
                NotificationCenter.default.post(name: .corralMotionChanged, object: nil)
                Theme.recompute()
            }
        }
    }

    /// For tests: pretend Reduce Motion is on/off.
    static func setReduced(_ value: Bool) {
        reduced = value
        NotificationCenter.default.post(name: .corralMotionChanged, object: nil)
    }

    /// Tests: treat windows as on screen (an invisible test window is never occlusion-visible).
    static var assumeVisible = false

    static func shouldAnimate(_ v: NSView) -> Bool {
        guard enabled, let window = v.window, !v.isHiddenOrHasHiddenAncestor else { return false }
        return assumeVisible || window.occlusionState.contains(.visible)
    }

    /// Spring that settles in about `duration * 1.6`.
    static func spring(_ key: String, from: Any?, to: Any?, duration: Double = 0.25, bounce: Double = 0) -> CASpringAnimation {
        let a = CASpringAnimation(perceptualDuration: duration, bounce: bounce)
        a.keyPath = key
        a.fromValue = from
        a.toValue = to
        a.duration = a.settlingDuration
        return a
    }

    static func basic(_ key: String, from: Any?, to: Any?, duration: Double, timing: CAMediaTimingFunction = std,
                      delay: Double = 0) -> CABasicAnimation {
        let a = CABasicAnimation(keyPath: key)
        a.fromValue = from
        a.toValue = to
        a.duration = duration
        a.timingFunction = timing
        if delay > 0 {
            a.beginTime = CACurrentMediaTime() + delay
            a.fillMode = .backwards
        }
        return a
    }

    /// Forever animation, phase-synced to wall clock so all loops pulse together, capped at 30 fps.
    static func loop(_ a: CAAnimation, period: CFTimeInterval) -> CAAnimation {
        a.duration = period
        a.repeatCount = .infinity
        a.isRemovedOnCompletion = false
        a.timeOffset = CACurrentMediaTime().truncatingRemainder(dividingBy: period)
        a.preferredFrameRateRange = CAFrameRateRange(minimum: 15, maximum: 30, preferred: 30)
        return a
    }

    /// Runs `body` without implicit animations.
    static func quiet(_ body: () -> Void) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        body()
        CATransaction.commit()
    }

    private static var lastTransition: [UUID: CFTimeInterval] = [:]
    private static var lastSwitch: CFTimeInterval = 0

    /// True when the previous transition for `id` was < 250 ms ago (records now).
    static func flapping(_ id: UUID) -> Bool {
        let now = CACurrentMediaTime()
        defer { lastTransition[id] = now }
        guard let last = lastTransition[id] else { return false }
        return now - last < 0.25
    }

    /// False when the previous session switch was < 150 ms ago, so key repeat never fades (records now).
    static func switchFadeAllowed() -> Bool {
        let now = CACurrentMediaTime()
        defer { lastSwitch = now }
        return now - lastSwitch >= 0.15
    }

    /// Presentation-only scale about the layer's visual center (backing layers anchor at 0,0).
    static func centeredScale(_ layer: CALayer, from: CGFloat, to: CGFloat = 1) -> CAAnimation {
        let b = layer.bounds
        let ax = layer.anchorPoint.x * b.width, ay = layer.anchorPoint.y * b.height
        let cx = b.midX - ax, cy = b.midY - ay
        func t(_ s: CGFloat) -> CATransform3D {
            var m = CATransform3DMakeTranslation(cx, cy, 0)
            m = CATransform3DScale(m, s, s, 1)
            return CATransform3DTranslate(m, -cx, -cy, 0)
        }
        let a = spring("transform", from: NSValue(caTransform3D: t(from)), to: NSValue(caTransform3D: t(to)))
        return a
    }

    /// M2 page entrance (terminal ↔ placeholder ↔ launch cover): rise 8 pt over 0.22 s; under
    /// Reduce Motion opacity only, 0.15 s.
    static func pageEntrance(full: Bool) -> (rise: CGFloat, duration: Double) {
        full ? (-8, 0.22) : (0, 0.15)
    }

    static func pageEntrance(_ layer: CALayer?) {
        let e = pageEntrance(full: full)
        entrance(layer, rise: e.rise, duration: e.duration)
    }

    /// Fade-in (and optional rise) of a view's content; presentation only.
    static func entrance(_ layer: CALayer?, rise: CGFloat = 0, duration: Double = 0.22, delay: Double = 0) {
        guard let layer, full || enabled else { return }
        let fade = basic("opacity", from: 0, to: layer.opacity, duration: duration, timing: out, delay: delay)
        layer.add(fade, forKey: "entrance.opacity")
        if rise != 0, full {
            let move = basic("transform.translation.y", from: rise, to: 0, duration: duration, timing: out, delay: delay)
            layer.add(move, forKey: "entrance.rise")
        }
    }
}
