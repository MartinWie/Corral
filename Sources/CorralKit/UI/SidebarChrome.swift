import AppKit
import CorralCore

private enum ChromeFonts {
    static let chip = NSFont.monospacedDigitSystemFont(ofSize: 10, weight: .semibold)
    static let link = NSFont.systemFont(ofSize: 11, weight: .semibold)
}

/// Renders into a bitmap at `scale` (layer contents; never in configure paths).
private func renderImage(size: NSSize, scale: CGFloat, _ draw: (NSRect) -> Void) -> CGImage? {
    guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(ceil(size.width * scale)),
                                     pixelsHigh: Int(ceil(size.height * scale)), bitsPerSample: 8, samplesPerPixel: 4,
                                     hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0,
                                     bitsPerPixel: 0) else { return nil }
    rep.size = size
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    draw(NSRect(origin: .zero, size: size))
    NSGraphicsContext.restoreGraphicsState()
    return rep.cgImage
}

// MARK: - Bottom bar statusline (§3.11)

/// One clickable statusline segment: [glyph 9] n. The glyph is its own layer so it can bump (M18).
final class StatusSegmentButton: NSButton {
    let glyph = NSView(frame: NSRect(x: 0, y: 0, width: 10, height: 10))
    let countLabel = NSTextField(labelWithString: "")
    let segment: SidebarStatusBar.Segment
    private(set) var count = 0
    private var hovered = false
    private var tracking: NSTrackingArea?

    init(segment: SidebarStatusBar.Segment) {
        self.segment = segment
        super.init(frame: NSRect(x: 0, y: 0, width: 30, height: 20))
        title = ""
        isBordered = false
        setButtonType(.momentaryChange)
        wantsLayer = true
        layer?.cornerRadius = 5
        layer?.cornerCurve = .continuous
        translatesAutoresizingMaskIntoConstraints = false
        glyph.wantsLayer = true
        glyph.layer?.contentsGravity = .center
        glyph.layer?.actions = SidebarFX.quietActions
        glyph.translatesAutoresizingMaskIntoConstraints = false
        countLabel.font = Fonts.statusline
        countLabel.translatesAutoresizingMaskIntoConstraints = false
        addSubview(glyph)
        addSubview(countLabel)
        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: 20),
            glyph.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 5),
            glyph.centerYAnchor.constraint(equalTo: centerYAnchor),
            glyph.widthAnchor.constraint(equalToConstant: 10),
            glyph.heightAnchor.constraint(equalToConstant: 10),
            countLabel.leadingAnchor.constraint(equalTo: glyph.trailingAnchor, constant: 3),
            countLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -5),
            countLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError() }

    override var intrinsicContentSize: NSSize {
        NSSize(width: 5 + 10 + 3 + countLabel.intrinsicContentSize.width + 5, height: 20)
    }

    /// Clicks anywhere on the segment go to the button, never to the label.
    override func hitTest(_ point: NSPoint) -> NSView? {
        frame.contains(point) && !isHidden ? self : nil
    }

    func setCount(_ n: Int) {
        count = n
        let s = "\(n)"
        if countLabel.stringValue != s { countLabel.stringValue = s }
        invalidateIntrinsicContentSize()
        let noun: String
        switch segment {
        case .needsInput: noun = "waiting for input"
        case .working: noun = "working"
        case .done: noun = "done, unread"
        case .error: noun = n == 1 ? "error" : "errors"
        }
        setAccessibilityLabel("\(n) \(noun)")
    }

    func applyTheme() {
        let color = SidebarStatusBar.color(for: segment)
        countLabel.textColor = color
        let scale = window?.backingScaleFactor ?? 2
        Motion.quiet {
            glyph.layer?.contents = SidebarStatusBar.glyphImage(segment, color: color, scale: scale)
            glyph.layer?.contentsScale = scale
        }
        needsDisplay = true
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        applyTheme()
    }

    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        let r = Theme.ramp(.chrome)
        layer?.backgroundColor = isHighlighted ? r.pressed.cgColor : (hovered ? r.hover.cgColor : nil)
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

/// 32 pt bar under the list: per-state counts on the left (click = next in that state), New Folder right.
final class SidebarStatusBar: NSView {
    enum Segment: Int, CaseIterable { case needsInput, working, done, error }

    struct Counts: Equatable {
        var needsInput = 0, working = 0, doneUnread = 0, error = 0, total = 0

        func value(_ s: Segment) -> Int {
            switch s {
            case .needsInput: return needsInput
            case .working: return working
            case .done: return doneUnread
            case .error: return error
            }
        }
    }

    let segmentStack = NSStackView()
    private(set) var buttons: [Segment: StatusSegmentButton] = [:]
    /// Shown when every count is zero: "N sessions".
    let totalLabel = NSTextField(labelWithString: "")
    let newFolderButton = GhostButton(symbol: "folder.badge.plus", size: 13, frame: NSRect(x: 0, y: 0, width: 24, height: 24),
                                      target: nil, action: #selector(MainWindowController.newFolder(_:)))
    /// Opens the keyboard-shortcuts sheet (also ⌘/).
    let shortcutsButton = GhostButton(symbol: "keyboard", size: 12, frame: NSRect(x: 0, y: 0, width: 22, height: 22),
                                      target: nil, action: #selector(MainWindowController.showShortcuts(_:)))
    private let hairline = SidebarFX.ownedLayer()
    private(set) var counts: Counts?
    var onSegment: ((Segment) -> Void)?

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.addSublayer(hairline)
        segmentStack.orientation = .horizontal
        segmentStack.spacing = 0
        segmentStack.alignment = .centerY
        segmentStack.translatesAutoresizingMaskIntoConstraints = false
        segmentStack.setHuggingPriority(.required, for: .horizontal)
        for seg in Segment.allCases {
            let b = StatusSegmentButton(segment: seg)
            b.target = self
            b.action = #selector(segmentClicked(_:))
            b.isHidden = true
            buttons[seg] = b
            segmentStack.addArrangedSubview(b)
        }
        totalLabel.font = Fonts.statusline
        totalLabel.translatesAutoresizingMaskIntoConstraints = false
        segmentStack.addArrangedSubview(totalLabel)
        segmentStack.setCustomSpacing(5, after: buttons[.error]!)
        newFolderButton.setAccessibilityLabel("New Folder")
        shortcutsButton.setAccessibilityLabel("Keyboard Shortcuts")
        refreshTooltips()
        addSubview(segmentStack)
        addSubview(shortcutsButton)
        addSubview(newFolderButton)
        NSLayoutConstraint.activate([
            // 10 pt padding: segments carry 5 pt of their own.
            segmentStack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 5),
            segmentStack.centerYAnchor.constraint(equalTo: centerYAnchor),
            shortcutsButton.leadingAnchor.constraint(equalTo: segmentStack.trailingAnchor, constant: 2),
            shortcutsButton.centerYAnchor.constraint(equalTo: centerYAnchor),
            shortcutsButton.trailingAnchor.constraint(lessThanOrEqualTo: newFolderButton.leadingAnchor, constant: -6),
            newFolderButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -5),
            newFolderButton.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
        NotificationCenter.default.addObserver(self, selector: #selector(themeChanged), name: .corralThemeDidChange, object: nil)
    }

    required init?(coder: NSCoder) { fatalError() }

    deinit { NotificationCenter.default.removeObserver(self) }

    @objc private func themeChanged() { MainActor.assumeIsolated { applyTheme() } }

    /// Tooltips name the menu's current shortcuts.
    func refreshTooltips() {
        newFolderButton.toolTip = KeyHint.string(for: #selector(MainWindowController.newFolder(_:))).map { "New Folder (\($0))" }
            ?? "New Folder"
        shortcutsButton.toolTip = KeyHint.string(for: #selector(MainWindowController.showShortcuts(_:)))
            .map { "Keyboard Shortcuts (\($0))" } ?? "Keyboard Shortcuts"
        for (seg, b) in buttons { b.toolTip = Self.tooltip(seg) }
    }

    static func tooltip(_ s: Segment) -> String {
        switch s {
        case .needsInput:
            return KeyHint.string(for: #selector(MainWindowController.nextAttention(_:))).map { "Next needing input (\($0))" }
                ?? "Next needing input"
        case .working: return "Next working session"
        case .done: return "Next finished session"
        case .error: return "Next session with an error"
        }
    }

    static func color(for s: Segment) -> NSColor {
        let p = Theme.tokens.status
        switch s {
        case .needsInput: return p.needsInput.text
        case .working: return p.working.text
        case .done: return p.done.text
        case .error: return p.error.text
        }
    }

    private static var glyphs: [String: CGImage] = [:]

    /// Cached 9 pt glyphs; the working arc is drawn (ring track + 110° arc), the rest are filled symbols
    /// in palette mode [inner mark, shape] so the ?, ✓ and ! read as cut-outs in the bar color.
    static func glyphImage(_ s: Segment, color: NSColor, scale: CGFloat) -> CGImage? {
        let ink = Theme.tokens.chrome
        let key = "\(s.rawValue)-\(RGB(color).hex)-\(RGB(ink).hex)-\(scale)"
        if let hit = glyphs[key] { return hit }
        let img: CGImage?
        switch s {
        case .working:
            img = renderImage(size: NSSize(width: 9, height: 9), scale: scale) { r in
                let ring = NSBezierPath(ovalIn: r.insetBy(dx: 1, dy: 1))
                ring.lineWidth = 1.5
                color.withAlphaComponent(0.3).setStroke()
                ring.stroke()
                let arc = NSBezierPath()
                arc.appendArc(withCenter: NSPoint(x: r.midX, y: r.midY), radius: r.width / 2 - 1, startAngle: 90, endAngle: -20,
                              clockwise: true)
                arc.lineWidth = 1.5
                arc.lineCapStyle = .round
                color.setStroke()
                arc.stroke()
            }
        case .needsInput:
            img = GlyphCache.cgImage("questionmark.bubble.fill", size: 9, weight: .semibold, colors: [ink, color], scale: scale)
        case .done:
            img = GlyphCache.cgImage("checkmark.circle.fill", size: 9, weight: .semibold, colors: [ink, color], scale: scale)
        case .error:
            img = GlyphCache.cgImage("exclamationmark.triangle.fill", size: 9, weight: .semibold, colors: [ink, color],
                                     scale: scale)
        }
        if glyphs.count > 64 { glyphs.removeAll() }
        glyphs[key] = img
        return img
    }

    /// Shows only non-zero segments; animates count changes (M18) when `animated`.
    func update(_ c: Counts, animated: Bool) {
        let old = counts
        guard c != old else { return }
        counts = c
        let anim = animated && SidebarFX.canAnimate(self)
        for seg in Segment.allCases {
            guard let b = buttons[seg] else { continue }
            let n = c.value(seg)
            let prev = old?.value(seg) ?? 0
            if b.isHidden != (n == 0) { b.isHidden = n == 0 }
            guard n != b.count || old == nil else { continue }
            b.setCount(n)
            guard anim, n > 0, let layer = b.countLabel.layer else { continue }
            if prev > 0 { SidebarFX.push(layer, up: n > prev) }
            if seg == .needsInput, n > prev, Motion.full, let g = b.glyph.layer { SidebarFX.bump(g, peak: 1.3) }
        }
        let quiet = Segment.allCases.allSatisfy { c.value($0) == 0 }
        totalLabel.isHidden = !quiet
        let total = c.total == 1 ? "1 session" : "\(c.total) sessions"
        if totalLabel.stringValue != total { totalLabel.stringValue = total }
    }

    func applyTheme() {
        buttons.values.forEach { $0.applyTheme() }
        totalLabel.textColor = Theme.ramp(.chrome).quaternary
        needsDisplay = true
    }

    @objc func segmentClicked(_ sender: StatusSegmentButton) { onSegment?(sender.segment) }

    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        Motion.quiet { hairline.backgroundColor = Theme.ramp(.chrome).hairline.cgColor }
        totalLabel.textColor = Theme.ramp(.chrome).quaternary
    }

    override func layout() {
        super.layout()
        let flipped = layer?.contentsAreFlipped() ?? isFlipped
        Motion.quiet { hairline.frame = CGRect(x: 0, y: flipped ? 0 : bounds.height - 1, width: bounds.width, height: 1) }
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        applyTheme()
    }
}

// MARK: - Attention edge chip (§3.10)

/// Amber capsule at the top or bottom scroll edge: "↑ 2 waiting". Click scrolls to the nearest one.
final class AttentionEdgeChip: NSView {
    enum Direction { case up, down }

    let direction: Direction
    let label = NSTextField(labelWithString: "")
    private let plate = SidebarFX.ownedLayer()
    private(set) var count = 0
    private var generation = 0
    private(set) var hiding = false
    var onClick: (() -> Void)?
    /// The list under the chip: wheel events over the chip scroll it instead of stalling.
    weak var scrollTarget: NSScrollView?
    private(set) var hovered = false { didSet { if hovered != oldValue { needsDisplay = true } } }
    private(set) var pressed = false { didSet { if pressed != oldValue { needsDisplay = true } } }
    private var tracking: NSTrackingArea?

    init(direction: Direction) {
        self.direction = direction
        super.init(frame: NSRect(x: 0, y: 0, width: 80, height: 20))
        wantsLayer = true
        plate.zPosition = -1
        plate.cornerCurve = .continuous
        plate.shadowColor = NSColor.black.cgColor
        plate.shadowRadius = 10
        layer?.addSublayer(plate)
        label.font = ChromeFonts.chip
        label.alignment = .center
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)
        translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: 20),
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 9),
            label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -9),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
        isHidden = true
        setAccessibilityRole(.button)
        toolTip = direction == .up ? "Scroll up to the next session waiting for input"
            : "Scroll down to the next session waiting for input"
        NotificationCenter.default.addObserver(self, selector: #selector(themeChanged), name: .corralThemeDidChange, object: nil)
    }

    required init?(coder: NSCoder) { fatalError() }
    deinit { NotificationCenter.default.removeObserver(self) }

    @objc private func themeChanged() { MainActor.assumeIsolated { needsDisplay = true } }

    var isShown: Bool { !isHidden && !hiding }

    static func text(_ n: Int, _ d: Direction) -> String { "\(d == .up ? "↑" : "↓") \(n) waiting" }

    func update(count n: Int, animated: Bool) {
        let old = count
        count = n
        let anim = animated && SidebarFX.canAnimate(self)
        if n > 0 {
            let text = Self.text(n, direction)
            if label.stringValue != text { label.stringValue = text }
            setAccessibilityLabel("\(n) waiting \(direction == .up ? "above" : "below")")
            if !isShown {
                show(animated: anim)
            } else if anim, n != old, let l = label.layer {
                SidebarFX.push(l, up: n > old)
            }
        } else if isShown {
            hide(animated: anim)
        }
    }

    private func show(animated: Bool) {
        generation += 1
        hiding = false
        layer?.removeAnimation(forKey: "sidebar.chip.out")
        isHidden = false
        guard animated, let layer else { return }
        layer.add(Motion.basic("opacity", from: 0, to: 1, duration: Motion.fast, timing: Motion.out), forKey: "sidebar.chip.in")
        if Motion.full {
            // Slides in from beyond its edge: up from below for ↓, down from above for ↑.
            let towardsTop = (direction == .up) != layer.contentsAreFlipped()
            layer.add(Motion.spring("transform.translation.y", from: towardsTop ? 6 : -6, to: 0), forKey: "sidebar.chip.move")
        }
    }

    private func hide(animated: Bool) {
        guard animated, let layer else {
            isHidden = true
            hiding = false
            return
        }
        hiding = true
        let generation = self.generation
        let fade = Motion.basic("opacity", from: layer.presentation()?.opacity ?? 1, to: 0, duration: Motion.fast, timing: Motion.exit)
        fade.fillMode = .forwards
        fade.isRemovedOnCompletion = false
        CATransaction.begin()
        CATransaction.setCompletionBlock { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.generation == generation, self.hiding else { return }
                self.isHidden = true
                self.hiding = false
                self.layer?.removeAnimation(forKey: "sidebar.chip.out")
            }
        }
        layer.add(fade, forKey: "sidebar.chip.out")
        CATransaction.commit()
    }

    private func inside(_ event: NSEvent) -> Bool { bounds.contains(convert(event.locationInWindow, from: nil)) }

    /// Button semantics: press darkens, release inside fires, dragging out cancels.
    override func mouseDown(with event: NSEvent) { pressed = true }
    override func mouseDragged(with event: NSEvent) { pressed = inside(event) }

    override func mouseUp(with event: NSEvent) {
        let fire = pressed && inside(event)
        pressed = false
        if fire { onClick?() }
    }

    override func scrollWheel(with event: NSEvent) {
        if let scrollTarget { scrollTarget.scrollWheel(with: event) } else { super.scrollWheel(with: event) }
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let t = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
                               owner: self, userInfo: nil)
        addTrackingArea(t)
        tracking = t
    }

    override func mouseEntered(with event: NSEvent) { hovered = true }
    override func mouseExited(with event: NSEvent) { hovered = false }

    override var isHidden: Bool {
        didSet { if isHidden { hovered = false; pressed = false } }
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func accessibilityPerformPress() -> Bool { onClick?(); return true }

    override func resetCursorRects() { addCursorRect(bounds, cursor: .pointingHand) }

    override var wantsUpdateLayer: Bool { true }

    /// Amber at rest; hover lifts it a step (OKLab L), press sinks it toward the ink.
    static func plateColor(_ t: ThemeTokens = Theme.tokens, hovered: Bool, pressed: Bool) -> NSColor {
        let amber = RGB(t.status.needsInput.fill)
        if pressed { return ColorMath.mix(amber, RGB(t.status.needsInput.onFill), 0.16).clamped.color }
        if hovered { return ColorMath.withLightness(amber, ColorMath.lightness(amber) + 0.035).clamped.color }
        return t.status.needsInput.fill
    }

    override func updateLayer() {
        let t = Theme.tokens
        Motion.quiet {
            plate.backgroundColor = Self.plateColor(t, hovered: hovered, pressed: pressed).cgColor
            plate.shadowOpacity = t.isChromeDark ? 0.30 : 0.12
        }
        label.textColor = t.status.needsInput.onFill
    }

    /// The plate's current fill (tests).
    var plateFill: CGColor? { plate.backgroundColor }

    override func layout() {
        super.layout()
        let flipped = layer?.contentsAreFlipped() ?? isFlipped
        Motion.quiet {
            plate.frame = bounds
            plate.cornerRadius = bounds.height / 2
            plate.shadowOffset = CGSize(width: 0, height: flipped ? 3 : -3)
            plate.shadowPath = CGPath(roundedRect: bounds, cornerWidth: bounds.height / 2, cornerHeight: bounds.height / 2,
                                      transform: nil)
        }
    }
}

// MARK: - Integrations banner (§3.12)

/// Borderless accent link with an underline on hover.
final class LinkButton: NSButton {
    private var hovered = false
    private var tracking: NSTrackingArea?

    init(title: String, action: Selector?) {
        super.init(frame: .zero)
        self.title = title
        self.action = action
        target = nil
        isBordered = false
        setButtonType(.momentaryChange)
        translatesAutoresizingMaskIntoConstraints = false
        refresh()
    }

    required init?(coder: NSCoder) { fatalError() }

    func refresh() {
        var attrs: [NSAttributedString.Key: Any] = [.font: ChromeFonts.link, .foregroundColor: Theme.tokens.accent]
        if hovered { attrs[.underlineStyle] = NSUnderlineStyle.single.rawValue }
        attributedTitle = NSAttributedString(string: title, attributes: attrs)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let t = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
                               owner: self, userInfo: nil)
        addTrackingArea(t)
        tracking = t
    }

    override func mouseEntered(with event: NSEvent) { hovered = true; refresh() }
    override func mouseExited(with event: NSEvent) { hovered = false; refresh() }
    override func resetCursorRects() { addCursorRect(bounds, cursor: .pointingHand) }
}

/// Sunken card above the bar while agent hooks are missing.
final class IntegrationsCard: NSView {
    let icon = GlyphView(frame: NSRect(x: 0, y: 0, width: 14, height: 14))
    let label = NSTextField(wrappingLabelWithString: "")
    let button = LinkButton(title: "Install Integrations…", action: #selector(AppDelegate.installIntegrations(_:)))
    private(set) var missing: [String] = []

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.cornerRadius = 8
        layer?.cornerCurve = .continuous
        layer?.borderWidth = 1
        translatesAutoresizingMaskIntoConstraints = false
        icon.symbol = "puzzlepiece.extension"
        icon.size = 12
        icon.translatesAutoresizingMaskIntoConstraints = false
        label.font = Fonts.caption
        label.translatesAutoresizingMaskIntoConstraints = false
        label.setContentCompressionResistancePriority(.init(250), for: .horizontal)
        for v in [icon, label, button] as [NSView] { addSubview(v) }
        NSLayoutConstraint.activate([
            icon.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            icon.topAnchor.constraint(equalTo: topAnchor, constant: 10),
            icon.widthAnchor.constraint(equalToConstant: 14),
            icon.heightAnchor.constraint(equalToConstant: 14),
            label.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 6),
            label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            label.topAnchor.constraint(equalTo: topAnchor, constant: 10),
            button.leadingAnchor.constraint(equalTo: label.leadingAnchor),
            button.topAnchor.constraint(equalTo: label.bottomAnchor, constant: 4),
            button.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -10),
        ])
        applyTheme()
        NotificationCenter.default.addObserver(self, selector: #selector(themeChanged), name: .corralThemeDidChange, object: nil)
    }

    required init?(coder: NSCoder) { fatalError() }
    deinit { NotificationCenter.default.removeObserver(self) }

    @objc private func themeChanged() { MainActor.assumeIsolated { applyTheme() } }

    func update(missing names: [String]) {
        missing = names
        let text = "Exact agent status needs hooks for \(names.joined(separator: ", "))."
        if label.stringValue != text { label.stringValue = text }
    }

    func applyTheme() {
        let t = Theme.tokens
        icon.color = t.accent
        label.textColor = t.ramp(.chrome).secondary
        button.refresh()
        needsDisplay = true
    }

    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        let r = Theme.ramp(.chrome)
        layer?.backgroundColor = r.sunken.cgColor
        layer?.borderColor = r.hairline.cgColor
    }

    override func layout() {
        super.layout()
        // Wrapping labels need their width before they can report a height.
        let w = label.frame.width
        if w > 0, abs(label.preferredMaxLayoutWidth - w) > 0.5 {
            label.preferredMaxLayoutWidth = w
            needsLayout = true
        }
    }
}
