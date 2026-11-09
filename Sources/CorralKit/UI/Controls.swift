import AppKit

/// Borderless icon button: tertiary symbol, primary + hover fill on hover, pressed fill when down.
final class GhostButton: NSButton {
    var surface: Surface = .chrome { didSet { needsDisplay = true } }
    var symbol: String { didSet { refreshImage() } }
    var symbolSize: CGFloat { didSet { refreshImage() } }
    var symbolWeight: NSFont.Weight = .medium { didSet { refreshImage() } }
    private(set) var hovered = false
    private var tracking: NSTrackingArea?

    init(symbol: String, size: CGFloat = 13, frame: NSRect = NSRect(x: 0, y: 0, width: 24, height: 24),
         target: AnyObject? = nil, action: Selector? = nil) {
        self.symbol = symbol
        self.symbolSize = size
        super.init(frame: frame)
        isBordered = false
        bezelStyle = .regularSquare
        title = ""
        imagePosition = .imageOnly
        self.target = target
        self.action = action
        wantsLayer = true
        layer?.cornerRadius = 6
        layer?.cornerCurve = .continuous
        translatesAutoresizingMaskIntoConstraints = false
        widthAnchor.constraint(equalToConstant: frame.width).isActive = true
        heightAnchor.constraint(equalToConstant: frame.height).isActive = true
        refreshImage()
        NotificationCenter.default.addObserver(self, selector: #selector(themeChanged), name: .corralThemeDidChange, object: nil)
    }

    required init?(coder: NSCoder) { fatalError() }

    deinit { NotificationCenter.default.removeObserver(self) }

    @objc private func themeChanged() { MainActor.assumeIsolated { refreshImage() } }

    override var wantsUpdateLayer: Bool { true }

    override var isEnabled: Bool { didSet { refreshImage() } }

    private func refreshImage() {
        let r = Theme.ramp(surface)
        let color = !isEnabled ? r.quaternary : (hovered ? r.primary : r.tertiary)
        image = GlyphCache.image(symbol, size: symbolSize, weight: symbolWeight, colors: [color])
        needsDisplay = true
    }

    override func updateLayer() {
        let r = Theme.ramp(surface)
        let fill: NSColor? = !isEnabled ? nil : (isHighlighted ? r.pressed : (hovered ? r.hover : nil))
        layer?.backgroundColor = fill?.cgColor
    }

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
        refreshImage()
    }
}

/// Primary call to action: accent fill, rounded 7.
final class ProminentButton: NSButton {
    private var hovered = false
    private var tracking: NSTrackingArea?

    init(title: String, target: AnyObject? = nil, action: Selector? = nil) {
        super.init(frame: NSRect(x: 0, y: 0, width: 100, height: 30))
        self.title = title
        self.target = target
        self.action = action
        isBordered = false
        wantsLayer = true
        layer?.cornerRadius = 7
        layer?.cornerCurve = .continuous
        translatesAutoresizingMaskIntoConstraints = false
        heightAnchor.constraint(equalToConstant: 30).isActive = true
        refreshTitle()
        NotificationCenter.default.addObserver(self, selector: #selector(themeChanged), name: .corralThemeDidChange, object: nil)
    }

    required init?(coder: NSCoder) { fatalError() }
    deinit { NotificationCenter.default.removeObserver(self) }

    override var title: String { didSet { refreshTitle() } }

    @objc private func themeChanged() { MainActor.assumeIsolated { refreshTitle() } }

    private func refreshTitle() {
        let t = Theme.tokens
        attributedTitle = NSAttributedString(string: title, attributes: [
            .font: NSFont.systemFont(ofSize: 13, weight: .semibold), .foregroundColor: t.onAccent,
        ])
        needsDisplay = true
    }

    override var intrinsicContentSize: NSSize {
        let s = attributedTitle.size()
        return NSSize(width: ceil(s.width) + 28, height: 30)
    }

    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        let t = Theme.tokens
        var c = RGB(t.accent)
        if isHighlighted {
            c = ColorMath.mix(c, t.isChromeDark ? RGB(0, 0, 0) : RGB(1, 1, 1), 0.10)
        } else if hovered {
            c = ColorMath.mix(c, t.isChromeDark ? RGB(1, 1, 1) : RGB(0, 0, 0), t.isChromeDark ? 0.08 : 0.06)
        }
        layer?.backgroundColor = c.color.cgColor
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let t = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
                               owner: self, userInfo: nil)
        addTrackingArea(t)
        tracking = t
    }

    override func mouseEntered(with event: NSEvent) { hovered = true; needsDisplay = true }
    override func mouseExited(with event: NSEvent) { hovered = false; needsDisplay = true }
}

/// Keyboard shortcut chip, e.g. ⌘K.
final class KeyCap: NSView {
    private let label = NSTextField(labelWithString: "")
    private let bottom = CALayer()
    var surface: Surface = .chrome { didSet { needsDisplay = true } }

    /// Kept natively so per-row change checks don't read back (and compare) a bridged string.
    var stringValue: String = "" {
        didSet {
            guard stringValue != oldValue else { return }
            label.stringValue = stringValue
            isHidden = stringValue.isEmpty
        }
    }

    init(_ text: String = "", surface: Surface = .chrome) {
        self.surface = surface
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 4
        layer?.cornerCurve = .continuous
        bottom.actions = ["backgroundColor": NSNull(), "frame": NSNull(), "position": NSNull(), "bounds": NSNull()]
        layer?.addSublayer(bottom)
        label.font = Fonts.keycap
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)
        translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 5),
            label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -5),
            label.topAnchor.constraint(equalTo: topAnchor, constant: 2),
            label.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -2),
        ])
        label.stringValue = text
        isHidden = text.isEmpty
        stringValue = text
        NotificationCenter.default.addObserver(self, selector: #selector(themeChanged), name: .corralThemeDidChange, object: nil)
    }

    required init?(coder: NSCoder) { fatalError() }
    deinit { NotificationCenter.default.removeObserver(self) }

    @objc private func themeChanged() { MainActor.assumeIsolated { needsDisplay = true } }

    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        let r = Theme.ramp(surface)
        layer?.backgroundColor = r.sunken.cgColor
        bottom.backgroundColor = r.hairline.cgColor
        label.textColor = r.secondary
    }

    override func layout() {
        super.layout()
        Motion.quiet { bottom.frame = CGRect(x: 0, y: 0, width: bounds.width, height: 1) }
    }
}

/// Capsule count badge (amber by default) with an optional pulsing halo.
final class BadgeView: NSView {
    let halo = CALayer()
    let plate = CALayer()
    let text = CATextLayer()
    var fill: NSColor = .systemOrange { didSet { needsDisplay = true } }
    var textColor: NSColor = .black { didSet { needsDisplay = true } }

    var stringValue: String {
        get { (text.string as? String) ?? "" }
        set {
            Motion.quiet { text.string = newValue }
            invalidateIntrinsicContentSize()
            needsLayout = true
        }
    }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        for l in [halo, plate, text] {
            l.actions = ["position": NSNull(), "bounds": NSNull(), "frame": NSNull(), "contents": NSNull(),
                         "backgroundColor": NSNull(), "foregroundColor": NSNull(), "string": NSNull(), "opacity": NSNull()]
            layer?.addSublayer(l)
        }
        halo.opacity = 0
        text.font = Fonts.badge
        text.fontSize = 10
        text.alignmentMode = .center
        text.contentsScale = 2
    }

    required init?(coder: NSCoder) { fatalError() }

    override var intrinsicContentSize: NSSize {
        let w = (stringValue as NSString).size(withAttributes: [.font: Fonts.badge]).width
        return NSSize(width: max(16, ceil(w) + 10), height: 16)
    }

    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        plate.backgroundColor = fill.cgColor
        halo.backgroundColor = fill.withAlphaComponent(0.4).cgColor
        text.foregroundColor = textColor.cgColor
    }

    override func layout() {
        super.layout()
        Motion.quiet {
            plate.frame = bounds
            plate.cornerRadius = bounds.height / 2
            halo.frame = bounds
            halo.cornerRadius = bounds.height / 2
            let h = Fonts.badge.ascender - Fonts.badge.descender
            text.frame = CGRect(x: 0, y: (bounds.height - h) / 2 - 0.5, width: bounds.width, height: h)
        }
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        text.contentsScale = window?.backingScaleFactor ?? 2
    }
}

/// Small layer-backed symbol view (no NSImageView overhead).
final class GlyphView: NSView {
    var symbol: String = "sparkle" { didSet { if oldValue != symbol { needsDisplay = true } } }
    var size: CGFloat = 11 { didSet { needsDisplay = true } }
    var color: NSColor = .secondaryLabelColor { didSet { needsDisplay = true } }
    var weight: NSFont.Weight = .medium

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.contentsGravity = .resizeAspect
        layer?.actions = ["contents": NSNull()]
    }

    required init?(coder: NSCoder) { fatalError() }

    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        layer?.contents = GlyphCache.cgImage(symbol, size: size, weight: weight, colors: [color],
                                             scale: window?.backingScaleFactor ?? 2)
    }
}

/// Gradient overlay at a scroll edge (chrome → clear); never intercepts clicks.
final class EdgeFadeView: NSView {
    let gradient = CAGradientLayer()
    let top: Bool

    init(top: Bool) {
        self.top = top
        super.init(frame: .zero)
        wantsLayer = true
        gradient.actions = ["colors": NSNull(), "frame": NSNull(), "bounds": NSNull(), "position": NSNull()]
        layer?.addSublayer(gradient)
        translatesAutoresizingMaskIntoConstraints = false
        refresh()
    }

    required init?(coder: NSCoder) { fatalError() }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    func refresh() {
        let c = Theme.tokens.chrome
        gradient.colors = [c.cgColor, c.withAlphaComponent(0).cgColor]
        // CA's y axis points up in a non-flipped view.
        gradient.startPoint = CGPoint(x: 0.5, y: top ? 1 : 0)
        gradient.endPoint = CGPoint(x: 0.5, y: top ? 0 : 1)
    }

    override func layout() {
        super.layout()
        Motion.quiet { gradient.frame = bounds }
    }
}
