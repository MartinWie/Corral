import AppKit

extension Fonts {
    /// Toolbar attention count (§3.1): `badge` at 11 pt.
    static let toolbarBadge = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .bold)
}

/// Toolbar "next needing input" control (§3.1, M19). Always 56×24, so the toolbar never relayouts.
/// - 0 waiting: outline bubble in `quaternary`, disabled.
/// - n waiting: an owned amber capsule (h 22, centered) with a filled bubble and the count in `onAmber`.
///   The bubble's "?" is knocked out, so it shows the capsule fill (hover and press tints included).
/// Never loops; `setLoopsPaused` only cancels in-flight one-shots and makes updates snap.
final class AttentionToolbarView: NSButton {
    static let size = NSSize(width: 56, height: 24)
    static let capsuleHeight: CGFloat = 22
    static let fillSymbol = "questionmark.bubble.fill"
    static let idleSymbol = "questionmark.bubble"
    private static let countFont = Fonts.toolbarBadge
    private static let lineHeight = ceil(countFont.ascender - countFont.descender)
    private static let inset: CGFloat = 7
    private static let gap: CGFloat = 3
    private static let noActions: [String: CAAction] = [
        "position": NSNull(), "bounds": NSNull(), "frame": NSNull(), "contents": NSNull(), "opacity": NSNull(),
        "backgroundColor": NSNull(), "foregroundColor": NSNull(), "string": NSNull(), "transform": NSNull(),
        "hidden": NSNull(), "contentsScale": NSNull(), "cornerRadius": NSNull(),
    ]

    /// Owned layers (never the AppKit backing layer's geometry).
    let capsule = CALayer()
    let fillGlyph = CALayer()
    let countText = CATextLayer()
    let idleGlyph = CALayer()

    private(set) var count = 0
    /// Text shown in the capsule; kept while the capsule fades out at 0.
    private(set) var displayedCount = ""
    private(set) var hovered = false
    private(set) var loopsPaused = false
    private var tracking: NSTrackingArea?
    private var fillGlyphSize = NSSize(width: 15, height: 14)
    private var idleGlyphSize = NSSize(width: 16, height: 15)

    static func label(for n: Int) -> String { n > 99 ? "99+" : "\(n)" }

    init(target: AnyObject? = nil, action: Selector? = nil) {
        super.init(frame: NSRect(origin: .zero, size: Self.size))
        title = ""
        isBordered = false
        imagePosition = .noImage
        refusesFirstResponder = true
        self.target = target
        self.action = action
        wantsLayer = true
        translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: Self.size.width),
            heightAnchor.constraint(equalToConstant: Self.size.height),
        ])
        for l in [capsule, fillGlyph, countText, idleGlyph] { l.actions = Self.noActions }
        capsule.masksToBounds = true // clips the count push (M19); one small layer, never a row or the terminal
        capsule.opacity = 0
        fillGlyph.contentsGravity = .resizeAspect
        idleGlyph.contentsGravity = .resizeAspect
        countText.font = Self.countFont
        countText.fontSize = Self.countFont.pointSize
        countText.alignmentMode = .left
        countText.truncationMode = .none
        capsule.addSublayer(fillGlyph)
        capsule.addSublayer(countText)
        layer?.addSublayer(idleGlyph)
        layer?.addSublayer(capsule)
        super.isEnabled = false
        setAccessibilityLabel("Next needing input")
        refreshColors()
        updateAccessibility()
        NotificationCenter.default.addObserver(self, selector: #selector(themeChanged), name: .corralThemeDidChange, object: nil)
    }

    required init?(coder: NSCoder) { fatalError() }

    deinit { NotificationCenter.default.removeObserver(self) }

    override var intrinsicContentSize: NSSize { Self.size }
    override var wantsUpdateLayer: Bool { true }
    override var isEnabled: Bool { didSet { needsDisplay = true } }
    override var isHighlighted: Bool { didSet { needsDisplay = true } }

    // MARK: Count

    /// Updates the count; animates only when visible, motion is on and loops aren't paused.
    func setCount(_ n: Int, animated: Bool = true) {
        applyCount(n, animate: animated && !loopsPaused && Motion.shouldAnimate(self))
    }

    /// Sets the final model state in `quiet`, then (optionally) adds M19 one-shots from presentation values.
    func applyCount(_ n: Int, animate: Bool) {
        let n = max(0, n)
        let old = count
        guard n != old else { return }
        count = n
        isEnabled = n > 0
        // Presentation values before the model changes, so interrupted one-shots continue from where they are.
        let oldWidth = capsule.presentation()?.bounds.width ?? capsule.bounds.width
        let capsuleFrom = capsule.presentation()?.opacity ?? capsule.opacity
        let idleFrom = idleGlyph.presentation()?.opacity ?? idleGlyph.opacity
        let oldLabel = displayedCount
        Motion.quiet {
            if n > 0 {
                displayedCount = Self.label(for: n)
                countText.string = displayedCount
            }
            capsule.opacity = n > 0 ? 1 : 0
            idleGlyph.opacity = n > 0 ? 0 : 1
            layoutLayers()
        }
        updateAccessibility()
        guard animate else {
            removeOwnedAnimations()
            return
        }
        let full = Motion.full
        let width = capsule.bounds.width
        let followWidth = full && abs(width - oldWidth) > 0.5
        if old == 0 {
            // 0 → n: capsule pops in, outline bubble swaps out. A capsule still fading out (1 → 0 → 1 flap)
            // only fades back, following a new width: popping it from 0.6 would jump.
            capsule.add(Motion.basic("opacity", from: capsuleFrom, to: 1, duration: full ? Motion.fast : 0.15,
                                     timing: Motion.out), forKey: "fade")
            if full, capsuleFrom < 0.05 {
                capsule.add(Motion.spring("transform.scale", from: 0.6, to: 1, duration: 0.30, bounce: 0.30), forKey: "pop")
            } else if followWidth {
                capsule.add(Motion.spring("bounds.size.width", from: oldWidth, to: width), forKey: "width")
            }
            idleGlyph.add(Motion.basic("opacity", from: idleFrom, to: 0, duration: Motion.micro, timing: Motion.exit),
                          forKey: "fade")
        } else if n == 0 {
            // n → 0: capsule fades (0.12), the calm outline returns.
            capsule.removeAnimation(forKey: "pop")
            capsule.add(Motion.basic("opacity", from: capsuleFrom, to: 0, duration: Motion.fast, timing: Motion.exit),
                        forKey: "fade")
            idleGlyph.add(Motion.basic("opacity", from: idleFrom, to: 1, duration: Motion.fast, timing: Motion.out),
                          forKey: "fade")
        } else {
            // n → m: text push (fade under Reduce Motion) when the shown label changes ("99+" stays put);
            // the capsule follows the new width.
            if displayedCount != oldLabel {
                let t = CATransition()
                t.type = full ? .push : .fade
                t.subtype = n > old ? .fromTop : .fromBottom
                t.duration = full ? Motion.base : 0.15
                t.timingFunction = Motion.std
                countText.add(t, forKey: kCATransition)
            }
            if followWidth {
                capsule.add(Motion.spring("bounds.size.width", from: oldWidth, to: width), forKey: "width")
            }
        }
    }

    private func removeOwnedAnimations() {
        for l in [capsule, fillGlyph, countText, idleGlyph] { l.removeAllAnimations() }
    }

    /// Window occluded / app hidden: drop anything in flight and snap future updates (there are no loops here).
    func setLoopsPaused(_ paused: Bool) {
        loopsPaused = paused
        if paused { removeOwnedAnimations() }
    }

    private func updateAccessibility() {
        setAccessibilityValue(count == 0 ? "None waiting" : "\(count) waiting")
    }

    // MARK: Drawing

    /// Amber fill; hover mixes toward the contrast side, pressed the other way (same rule as ProminentButton).
    var capsuleFill: NSColor {
        let t = Theme.tokens
        var c = RGB(t.status.needsInput.fill)
        if isHighlighted {
            c = ColorMath.mix(c, t.isChromeDark ? RGB(0, 0, 0) : RGB(1, 1, 1), 0.10)
        } else if hovered && isEnabled {
            c = ColorMath.mix(c, t.isChromeDark ? RGB(1, 1, 1) : RGB(0, 0, 0), t.isChromeDark ? 0.08 : 0.06)
        }
        return c.color
    }

    override func updateLayer() {
        Motion.quiet { capsule.backgroundColor = capsuleFill.cgColor }
    }

    private func refreshColors() {
        let t = Theme.tokens
        let scale = window?.backingScaleFactor ?? 2
        let on = t.status.needsInput.onFill
        let quaternary = t.ramp(.chrome).quaternary
        let fill = Self.knockoutGlyph(Self.fillSymbol, size: 12, weight: .medium, color: on, scale: scale)
        if let fill { fillGlyphSize = fill.size }
        if let img = GlyphCache.image(Self.idleSymbol, size: 13, weight: .medium, colors: [quaternary]) {
            idleGlyphSize = img.size
        }
        Motion.quiet {
            fillGlyph.contents = fill?.image
            idleGlyph.contents = GlyphCache.cgImage(Self.idleSymbol, size: 13, weight: .medium, colors: [quaternary], scale: scale)
            countText.foregroundColor = on.cgColor
            for l in [fillGlyph, idleGlyph, countText] { l.contentsScale = scale }
            capsule.backgroundColor = capsuleFill.cgColor
            layoutLayers()
        }
        needsDisplay = true
    }

    private static var knockouts: [String: (image: CGImage, size: NSSize)] = [:]

    /// The symbol drawn monochrome, then tinted with `.sourceAtop` in sRGB: knocked-out parts (the "?" of
    /// `questionmark.bubble.fill`) stay transparent. A one-color palette would paint them in the tint too.
    static func knockoutGlyph(_ name: String, size: CGFloat, weight: NSFont.Weight, color: NSColor,
                              scale: CGFloat) -> (image: CGImage, size: NSSize)? {
        let c = color.usingColorSpace(.sRGB) ?? color
        let key = "\(name)|\(size)|\(weight.rawValue)|\(RGB(c).hex)|\(c.alphaComponent)|\(scale)"
        if let hit = knockouts[key] { return hit }
        guard let symbol = NSImage(systemSymbolName: name, accessibilityDescription: nil)?
                .withSymbolConfiguration(.init(pointSize: size, weight: weight)),
              let space = CGColorSpace(name: CGColorSpace.sRGB),
              let ctx = CGContext(data: nil, width: Int(ceil(symbol.size.width * scale)),
                                  height: Int(ceil(symbol.size.height * scale)), bitsPerComponent: 8, bytesPerRow: 0,
                                  space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        let rect = NSRect(origin: .zero, size: symbol.size)
        ctx.scaleBy(x: scale, y: scale)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: false)
        symbol.draw(in: rect)
        c.set()
        rect.fill(using: .sourceAtop)
        NSGraphicsContext.restoreGraphicsState()
        guard let image = ctx.makeImage() else { return nil }
        if knockouts.count >= 16 { knockouts.removeAll() } // a few themes × scales
        knockouts[key] = (image, symbol.size)
        return (image, symbol.size)
    }

    @objc private func themeChanged() { MainActor.assumeIsolated { refreshColors() } }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        refreshColors()
    }

    /// Capsule width for the shown text, even so its edges land on whole points when centered.
    var capsuleWidth: CGFloat {
        let text = ceil((displayedCount as NSString).size(withAttributes: [.font: Self.countFont]).width)
        let w = Self.inset + ceil(fillGlyphSize.width) + Self.gap + text + Self.inset
        return min(Self.size.width, ceil(w / 2) * 2)
    }

    override func layout() {
        super.layout()
        Motion.quiet { layoutLayers() }
    }

    private func layoutLayers() {
        let b = bounds.width > 0 ? bounds : NSRect(origin: .zero, size: Self.size)
        let h = Self.capsuleHeight
        idleGlyph.frame = CGRect(x: round(b.midX - idleGlyphSize.width / 2), y: round(b.midY - idleGlyphSize.height / 2),
                                 width: idleGlyphSize.width, height: idleGlyphSize.height)
        capsule.bounds = CGRect(x: 0, y: 0, width: capsuleWidth, height: h)
        capsule.position = CGPoint(x: b.midX, y: b.midY)
        capsule.cornerRadius = h / 2
        let gw = ceil(fillGlyphSize.width)
        fillGlyph.frame = CGRect(x: Self.inset, y: round((h - fillGlyphSize.height) / 2),
                                 width: fillGlyphSize.width, height: fillGlyphSize.height)
        // Wide enough for "99+"; the capsule clips. Nudged half a point for optical centering of digits.
        let nudge: CGFloat = isFlipped ? 0.5 : -0.5
        countText.frame = CGRect(x: Self.inset + gw + Self.gap, y: (h - Self.lineHeight) / 2 + nudge,
                                 width: 32, height: Self.lineHeight)
    }

    // MARK: Hover

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let t = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
                               owner: self, userInfo: nil)
        addTrackingArea(t)
        tracking = t
    }

    override func mouseEntered(with event: NSEvent) { setHovered(true) }
    override func mouseExited(with event: NSEvent) { setHovered(false) }

    func setHovered(_ h: Bool) {
        guard hovered != h else { return }
        hovered = h
        needsDisplay = true
    }
}
