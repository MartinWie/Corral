import AppKit

/// Scrollback search (⌘F) floating at the card's top-trailing corner, driving Ghostty's search
/// bindings (spec §3.14). Drawn, not a material: elevated card fill, strong hairline, float shadow.
/// Overlays the terminal and never resizes it.
final class FindBar: NSView, NSTextFieldDelegate {
    static let height: CGFloat = 32
    static let radius: CGFloat = 10
    static let fieldWidth: CGFloat = 200
    static let minFieldWidth: CGFloat = 100
    /// Field width preference: below `dragThatCanResizeWindow` (510) and the card-margin priority.
    static let flexiblePriority = NSLayoutConstraint.Priority(490)

    let field = NSTextField()
    let count = NSTextField(labelWithString: "")
    let glyph = NSImageView()
    /// 1×16 hairline between the count and the chevrons; colors itself in `updateLayer`.
    let divider = FindBarDivider()
    let prevButton = GhostButton(symbol: "chevron.up", size: 11, frame: NSRect(x: 0, y: 0, width: 22, height: 22))
    let nextButton = GhostButton(symbol: "chevron.down", size: 11, frame: NSRect(x: 0, y: 0, width: 22, height: 22))
    let closeButton = GhostButton(symbol: "xmark", size: 10, frame: NSRect(x: 0, y: 0, width: 22, height: 22))

    var onChange: ((String) -> Void)?
    var onNext: (() -> Void)?
    var onPrevious: (() -> Void)?
    var onClose: (() -> Void)?
    var total = -1 { didSet { updateCount() } }
    var selected = -1 { didSet { updateCount() } }

    /// Logical visibility: false as soon as a hide starts, even while it fades out.
    private(set) var isPresented = false
    private var generation = 0
    private var alertColor: NSColor = .clear

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layerContentsRedrawPolicy = .onSetNeedsDisplay
        translatesAutoresizingMaskIntoConstraints = false

        glyph.imageScaling = .scaleNone
        glyph.setContentHuggingPriority(.required, for: .horizontal)

        field.isBordered = false
        field.drawsBackground = false
        field.isBezeled = false
        field.focusRingType = .none
        field.font = Fonts.findField
        field.delegate = self
        field.cell?.usesSingleLineMode = true
        field.cell?.wraps = false
        field.cell?.isScrollable = true
        field.setAccessibilityLabel("Find in scrollback")

        count.font = Fonts.findCount
        count.alignment = .right
        count.lineBreakMode = .byClipping
        count.setContentHuggingPriority(.required, for: .horizontal)

        for b in [prevButton, nextButton, closeButton] {
            b.surface = .card
            b.target = self
        }
        prevButton.action = #selector(prevTapped)
        nextButton.action = #selector(nextTapped)
        closeButton.action = #selector(closeTapped)
        prevButton.toolTip = "Previous match (⇧↩)"
        nextButton.toolTip = "Next match (↩)"
        closeButton.toolTip = "Close (esc)"
        prevButton.setAccessibilityLabel("Previous match")
        nextButton.setAccessibilityLabel("Next match")
        closeButton.setAccessibilityLabel("Close find")

        let row = NSStackView(views: [glyph, field, count, divider, prevButton, nextButton, closeButton])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 4
        row.edgeInsets = NSEdgeInsets(top: 0, left: 10, bottom: 0, right: 6)
        row.setCustomSpacing(6, after: glyph)
        row.setCustomSpacing(6, after: count)
        row.setCustomSpacing(6, after: divider)
        row.translatesAutoresizingMaskIntoConstraints = false
        addSubview(row)
        // The field gives way first on a narrow card (below the window-drag priority, so the bar
        // never sets a minimum window width).
        let fieldWidth = field.widthAnchor.constraint(equalToConstant: Self.fieldWidth)
        fieldWidth.priority = Self.flexiblePriority
        NSLayoutConstraint.activate([
            row.topAnchor.constraint(equalTo: topAnchor),
            row.bottomAnchor.constraint(equalTo: bottomAnchor),
            row.leadingAnchor.constraint(equalTo: leadingAnchor),
            row.trailingAnchor.constraint(equalTo: trailingAnchor),
            heightAnchor.constraint(equalToConstant: Self.height),
            fieldWidth,
            field.widthAnchor.constraint(greaterThanOrEqualToConstant: Self.minFieldWidth),
            count.widthAnchor.constraint(greaterThanOrEqualToConstant: 44),
        ])
        setAccessibilityRole(.group)
        setAccessibilityLabel("Find in scrollback")
        applyTheme()
        NotificationCenter.default.addObserver(self, selector: #selector(themeChanged), name: .corralThemeDidChange, object: nil)
    }

    required init?(coder: NSCoder) { fatalError() }

    deinit { NotificationCenter.default.removeObserver(self) }

    @objc private func themeChanged() { MainActor.assumeIsolated { applyTheme() } }

    // MARK: Appearance

    func applyTheme() {
        let t = Theme.tokens
        let r = t.ramp(.card)
        appearance = t.cardAppearance
        glyph.image = GlyphCache.image("magnifyingglass", size: 11, weight: .medium, colors: [r.tertiary])
        field.textColor = r.primary
        field.placeholderAttributedString = NSAttributedString(string: "Find in scrollback", attributes: [
            .font: Fonts.findField, .foregroundColor: r.tertiary,
        ])
        alertColor = ColorMath.guarded(RGB(t.status.error.text), on: RGB(t.cardElevated), target: 4.5).color
        divider.needsDisplay = true
        updateCount()
        needsDisplay = true
    }

    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        guard let l = layer else { return }
        let t = Theme.tokens
        l.backgroundColor = t.cardElevated.cgColor
        l.cornerRadius = Self.radius
        l.cornerCurve = .continuous
        l.masksToBounds = false   // after the radius, which turns masking on; masking would clip the shadow
        l.borderWidth = 1
        l.borderColor = t.ramp(.card).hairlineStrong.cgColor
        // `float` elevation (§2.9).
        l.shadowColor = NSColor.black.cgColor
        l.shadowOpacity = Float(t.isCardDark ? 0.30 : 0.12)
        l.shadowRadius = 10
        l.shadowOffset = CGSize(width: 0, height: -3)
        updateShadowPath()
    }

    override func layout() {
        super.layout()
        updateShadowPath()
    }

    private func updateShadowPath() {
        let path = CGPath(roundedRect: bounds, cornerWidth: Self.radius, cornerHeight: Self.radius, transform: nil)
        Motion.quiet { layer?.shadowPath = path }
    }

    // MARK: Show / hide (M22, M23)

    /// Unhides the bar, focuses the field and searches for `needle` (or the text still in the field).
    func show(needle: String?) {
        reveal()
        if let needle, !needle.isEmpty { field.stringValue = needle }
        updateCount()
        window?.makeFirstResponder(field)
        if !field.stringValue.isEmpty { onChange?(field.stringValue) }
    }

    /// M22: fade in and drop 6 pt into place; overlays the terminal, never pushes it.
    func reveal() {
        generation += 1
        let wasHidden = isHidden || !isPresented
        isPresented = true
        // Interrupting an M23 fade-out continues from where it is instead of dipping to 0.
        let fadingOut = !isHidden && layer?.animation(forKey: "find.out") != nil
        let from: Float? = fadingOut ? (layer?.presentation()?.opacity ?? 0) : nil
        layer?.removeAnimation(forKey: "find.out")
        isHidden = false
        if wasHidden, Motion.shouldAnimate(self) { addRevealAnimation(from: from) }
    }

    /// `from`: the presentation opacity of an interrupted fade-out (the bar is already in place, so
    /// no drop). Nil for a fresh show: fade from 0 and drop 6 pt into place.
    func addRevealAnimation(from: Float? = nil) {
        guard let l = layer else { return }
        l.add(Motion.basic("opacity", from: from ?? 0, to: 1, duration: Motion.fast, timing: Motion.out), forKey: "find.in")
        if from == nil, Motion.full {
            l.add(Motion.spring("transform.translation.y", from: 6, to: 0), forKey: "find.in.y")
        }
    }

    /// M23: fade out, then hide and clear. Idempotent; a later `reveal()` cancels a pending hide.
    func dismiss() {
        guard isPresented || (!isHidden && layer?.animation(forKey: "find.out") == nil) else { return }
        isPresented = false
        generation += 1
        guard Motion.shouldAnimate(self) else { finishDismiss(); return }
        addDismissAnimation(generation: generation)
    }

    func addDismissAnimation(generation g: Int) {
        guard let l = layer else { finishDismiss(); return }
        l.removeAnimation(forKey: "find.in")
        l.removeAnimation(forKey: "find.in.y")
        let fade = Motion.basic("opacity", from: l.presentation()?.opacity ?? 1, to: 0, duration: 0.10, timing: Motion.exit)
        fade.fillMode = .forwards
        fade.isRemovedOnCompletion = false
        CATransaction.begin()
        CATransaction.setCompletionBlock { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.generation == g else { return }
                self.finishDismiss()
            }
        }
        l.add(fade, forKey: "find.out")
        CATransaction.commit()
    }

    private func finishDismiss() {
        isHidden = true
        layer?.removeAnimation(forKey: "find.out")
        reset()
    }

    func reset() {
        field.stringValue = ""
        total = -1
        selected = -1
    }

    // MARK: Count

    /// Zero matches for a non-empty query: the count turns red and Enter shakes the bar.
    var noMatches: Bool { total == 0 && !field.stringValue.isEmpty }

    private func updateCount() {
        if total < 0 {
            count.stringValue = ""
        } else {
            count.stringValue = selected >= 0 ? "\(selected + 1)/\(total)" : "\(total)"
        }
        count.textColor = noMatches ? alertColor : Theme.ramp(.card).tertiary
        prevButton.isEnabled = total != 0
        nextButton.isEnabled = total != 0
    }

    /// M24: horizontal shake when Enter finds nothing (Reduce Motion: none, the count is already red).
    func shake() {
        guard Motion.full, Motion.shouldAnimate(self) else { return }
        addShakeAnimation()
    }

    func addShakeAnimation() {
        let a = CAKeyframeAnimation(keyPath: "transform.translation.x")
        a.values = [0, -3, 3, -2.5, 2.5, -1, 0]
        a.keyTimes = [0, 0.15, 0.35, 0.55, 0.75, 0.9, 1]
        a.duration = 0.30
        a.timingFunction = Motion.std
        layer?.add(a, forKey: "find.shake")
    }

    // MARK: Actions

    @objc func fieldChanged() {
        updateCount()
        onChange?(field.stringValue)
    }

    @objc func prevTapped() { onPrevious?() }
    @objc func nextTapped() { onNext?() }
    @objc func closeTapped() { onClose?() }

    func controlTextDidChange(_ obj: Notification) { fieldChanged() }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy sel: Selector) -> Bool {
        switch sel {
        case #selector(NSResponder.insertNewline(_:)):
            if noMatches { shake() }
            if NSApp.currentEvent?.modifierFlags.contains(.shift) == true { onPrevious?() } else { onNext?() }
            return true
        case #selector(NSResponder.cancelOperation(_:)):
            onClose?()
            return true
        default:
            return false
        }
    }
}

extension Fonts {
    /// Find bar query (mono 12) and match count (mono-digit 10.5).
    static let findField = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
    static let findCount = NSFont.monospacedDigitSystemFont(ofSize: 10.5, weight: .medium)
}

/// The find bar's 1×16 divider. Its fill is the strong hairline rebased onto the bar's elevated fill
/// (the ramp's overlays are composited over the card, which is darker than the bar in dark themes).
final class FindBarDivider: NSView {
    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layerContentsRedrawPolicy = .onSetNeedsDisplay
        translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: 1),
            heightAnchor.constraint(equalToConstant: 16),
        ])
    }

    required init?(coder: NSCoder) { fatalError() }

    override var wantsUpdateLayer: Bool { true }

    static var color: NSColor {
        let t = Theme.tokens
        let r = t.ramp(.card)
        return CardOverlay.rebase(r.hairlineStrong, ramp: r, onto: t.cardElevated)
    }

    override func updateLayer() {
        layer?.backgroundColor = Self.color.cgColor
    }
}

/// Moves a ramp overlay (an opaque composite of `primary` over the ramp's surface) onto another
/// fill with the same alpha, so hairlines and plates keep their contrast on elevated or sunken fills.
enum CardOverlay {
    static func alpha(of overlay: NSColor, ramp r: Ramp) -> Double {
        let o = RGB(overlay), p = RGB(r.primary), s = RGB(r.surface)
        let deltas = [(o.r - s.r, p.r - s.r), (o.g - s.g, p.g - s.g), (o.b - s.b, p.b - s.b)]
        guard let best = deltas.max(by: { abs($0.1) < abs($1.1) }), abs(best.1) > 0.001 else { return 0 }
        return min(max(best.0 / best.1, 0), 1)
    }

    static func rebase(_ overlay: NSColor, ramp r: Ramp, onto fill: NSColor) -> NSColor {
        ColorMath.over(RGB(r.primary), RGB(fill), alpha(of: overlay, ramp: r)).color
    }
}
