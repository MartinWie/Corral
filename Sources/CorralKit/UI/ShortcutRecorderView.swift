import AppKit
import Carbon.HIToolbox

/// A shortcut field: the combo as key caps. Click it (or press space / return on it) and type the new
/// shortcut. While recording an accent ring breathes and held modifiers pop in as caps; the finishing key
/// lands with a small bounce and a flash. A refused combo shakes the field and says why; a shortcut that
/// moved to another command shrinks away to "None" with an amber flash.
final class ShortcutRecorderView: NSView {
    enum Change { case plain, accepted, displaced }

    static let size = NSSize(width: 140, height: 26)
    static let capHeight: CGFloat = 20
    static let capSpacing: CGFloat = 3
    static let messageDuration = 1.8
    static let font = NSFont.systemFont(ofSize: 11, weight: .medium)
    static let capFont = NSFont.systemFont(ofSize: 11.5, weight: .semibold)
    static let recordingPrompt = "Type shortcut"
    static let nonePrompt = "None"

    /// Command name, for accessibility.
    var name = ""
    /// Replaces the key cap (Session by Number shows "1–9").
    var keyLabel: String?
    enum Answer: Equatable {
        /// Taken; the shortcut now in effect (the store's form of it).
        case taken(KeyCombo?)
        case refused(String)
    }

    /// Offers the recorded combo (nil: remove the shortcut).
    var onRecord: ((KeyCombo?) -> Answer)?
    private(set) var combo: KeyCombo?
    private(set) var isRecording = false
    /// Modifiers held right now, while recording.
    private(set) var liveMods: NSEvent.ModifierFlags = []
    /// Why the last combo was refused; shown in place of the caps for a moment.
    private(set) var message: String?
    private var messageWork: DispatchWorkItem?
    private var hovered = false
    private var tracking: NSTrackingArea?
    /// The surface the field sits on (its colors come from that ramp).
    var surface: Surface = .chrome { didSet { needsDisplay = true } }

    let body = CALayer()
    let prompt = CATextLayer()
    private(set) var caps: [CapLayer] = []

    init() {
        super.init(frame: NSRect(origin: .zero, size: Self.size))
        wantsLayer = true
        layerContentsRedrawPolicy = .onSetNeedsDisplay
        translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: Self.size.width),
            heightAnchor.constraint(equalToConstant: Self.size.height),
        ])
        body.cornerRadius = 7
        body.cornerCurve = .continuous
        body.borderWidth = 1
        body.shadowOffset = .zero
        body.shadowRadius = 5
        body.shadowOpacity = 0
        prompt.font = Self.font
        prompt.fontSize = Self.font.pointSize
        prompt.alignmentMode = .center
        prompt.truncationMode = .end
        body.addSublayer(prompt)
        layer?.addSublayer(body)
        toolTip = "Click, then type the new shortcut"
        NotificationCenter.default.addObserver(self, selector: #selector(themeChanged), name: .corralThemeDidChange, object: nil)
        render(animated: false)
    }

    required init?(coder: NSCoder) { fatalError() }

    deinit { NotificationCenter.default.removeObserver(self) }

    @objc private func themeChanged() { MainActor.assumeIsolated { needsDisplay = true } }

    // MARK: State

    /// Shows `combo` (the store changed it: restore, or moved to another command).
    func setCombo(_ new: KeyCombo?, change: Change = .plain, animated: Bool = true) {
        let was = combo
        combo = new
        guard was != new || change == .accepted else { return }
        render(animated: animated, change: change)
    }

    func beginRecording() {
        guard !isRecording else { return }
        // Keys and modifier changes must reach this view, or the ring would breathe at nothing.
        if let window, window.firstResponder !== self, !window.makeFirstResponder(self) { return }
        isRecording = true
        liveMods = []
        clearMessage()
        render(animated: true)
    }

    func cancelRecording() {
        guard isRecording else { return }
        isRecording = false
        liveMods = []
        clearMessage()
        render(animated: true)
    }

    /// Offers `c` (nil: no shortcut) to the store: taken → shown with a bounce; refused → shake + reason.
    func submit(_ c: KeyCombo?) {
        let answer = onRecord?(c) ?? .taken(c)
        if case .refused(let reason) = answer {
            refuse(reason)
            return
        }
        isRecording = false
        liveMods = []
        clearMessage()
        if case .taken(let now) = answer { combo = now }
        render(animated: true, change: c == nil ? .plain : .accepted)
    }

    /// Shakes the field and shows `reason` for a moment (also used when a reset is refused).
    func refuse(_ reason: String) {
        message = reason
        render(animated: true)
        shake()
        messageWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.message == reason else { return }
            self.message = nil
            self.render(animated: true)
        }
        messageWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.messageDuration, execute: work)
    }

    private func clearMessage() {
        messageWork?.cancel()
        messageWork = nil
        message = nil
    }

    func setLiveMods(_ mods: NSEvent.ModifierFlags) {
        let m = mods.intersection(KeyCombo.modifierMask)
        guard isRecording, m != liveMods else { return }
        liveMods = m
        // Holding a modifier again hides a refusal: the next attempt is under way.
        if !m.isEmpty { clearMessage() }
        render(animated: true)
    }

    /// Caps on show: the combo, or while recording the modifiers held so far.
    var tokens: [String] {
        if message != nil { return [] }
        if isRecording { return KeyHint.modifierGlyphs(liveMods) }
        guard let combo else { return [] }
        return KeyHint.modifierGlyphs(combo.mods) + [keyLabel ?? KeyHint.keyName(combo.key)]
    }

    var promptText: String {
        if let message { return message }
        if isRecording { return liveMods.isEmpty ? Self.recordingPrompt : "" }
        return combo == nil ? Self.nonePrompt : ""
    }

    /// What VoiceOver reads and tests check: "⇧⌘K", "None", "Recording".
    var displayText: String {
        if isRecording { return "Recording" }
        return combo == nil ? Self.nonePrompt : tokens.joined()
    }

    // MARK: Events

    override var acceptsFirstResponder: Bool { true }

    override var focusRingMaskBounds: NSRect { bounds }

    override func drawFocusRingMask() {
        NSBezierPath(roundedRect: bounds, xRadius: body.cornerRadius, yRadius: body.cornerRadius).fill()
    }

    override func mouseDown(with event: NSEvent) {
        if isRecording { cancelRecording() } else { beginRecording() }
    }

    override func keyDown(with event: NSEvent) {
        if isRecording {
            record(event)
        } else if [kVK_Space, kVK_Return].contains(Int(event.keyCode)) {
            beginRecording()
        } else {
            super.keyDown(with: event)
        }
    }

    /// While recording, every ⌘ combo is ours (else ⌘Q would quit, ⌘W close the window).
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard isRecording, event.type == .keyDown else { return super.performKeyEquivalent(with: event) }
        record(event)
        return true
    }

    override func flagsChanged(with event: NSEvent) {
        guard isRecording else { return super.flagsChanged(with: event) }
        setLiveMods(event.modifierFlags)
    }

    func record(_ event: NSEvent) {
        guard !event.isARepeat else { return }
        let mods = event.modifierFlags.intersection(KeyCombo.modifierMask)
        let code = Int(event.keyCode)
        switch code {
        case kVK_Escape:
            cancelRecording()
        case _ where (code == kVK_Delete || code == kVK_ForwardDelete) && mods.isEmpty:
            submit(nil)
        default:
            guard let c = KeyCombo(event: event) else { return refuse("Not a key Corral can use") }
            submit(c)
        }
    }

    override func resignFirstResponder() -> Bool {
        cancelRecording()
        return super.resignFirstResponder()
    }

    override func viewWillMove(toWindow newWindow: NSWindow?) {
        NotificationCenter.default.removeObserver(self, name: NSWindow.didResignKeyNotification, object: window)
        super.viewWillMove(toWindow: newWindow)
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard let window else { return }
        NotificationCenter.default.addObserver(self, selector: #selector(windowResignedKey),
                                               name: NSWindow.didResignKeyNotification, object: window)
    }

    @objc private func windowResignedKey() { MainActor.assumeIsolated { cancelRecording() } }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let t = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self)
        addTrackingArea(t)
        tracking = t
    }

    override func mouseEntered(with event: NSEvent) { hovered = true; needsDisplay = true }
    override func mouseExited(with event: NSEvent) { hovered = false; needsDisplay = true }

    // MARK: Accessibility

    override func isAccessibilityElement() -> Bool { true }
    override func accessibilityRole() -> NSAccessibility.Role? { .button }
    override func accessibilityLabel() -> String? { "\(name) shortcut" }
    override func accessibilityValue() -> Any? { message ?? displayText }
    override func accessibilityPerformPress() -> Bool {
        if isRecording { cancelRecording() } else { beginRecording() }
        return true
    }

    // MARK: Drawing

    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        Motion.quiet { applyColors() }
    }

    private var scale: CGFloat { window?.backingScaleFactor ?? 2 }

    private func applyColors() {
        let t = Theme.tokens, r = t.ramp(surface)
        body.backgroundColor = r.sunken.cgColor
        body.borderColor = (isRecording ? t.accent : hovered ? r.hairlineStrong : r.hairline).cgColor
        body.borderWidth = isRecording ? 1.5 : 1
        body.shadowColor = t.accent.cgColor
        prompt.foregroundColor = (message != nil ? t.status.error.fill : isRecording ? r.secondary : r.tertiary).cgColor
        prompt.contentsScale = scale
        for cap in caps { cap.applyColors(r, scale: scale) }
    }

    override func layout() {
        super.layout()
        Motion.quiet {
            body.bounds = bounds
            body.position = CGPoint(x: bounds.midX, y: bounds.midY)
            placeContent(animated: false)
        }
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        needsDisplay = true
    }

    /// Brings caps, prompt and ring to the current state. Caps are diffed by glyph, so a held ⌘ stays put
    /// while ⇧ joins it, and only what changed pops in or out.
    private func render(animated: Bool, change: Change = .plain) {
        let motion = animated && Motion.full && Motion.shouldAnimate(self)
        let fades = animated && Motion.shouldAnimate(self)
        let wanted = tokens
        var keep: [CapLayer] = []
        var pool = caps
        var added: [CapLayer] = []
        for token in wanted {
            if let i = pool.firstIndex(where: { $0.token == token }) {
                keep.append(pool.remove(at: i))
            } else {
                let cap = CapLayer(token: token)
                body.addSublayer(cap)
                keep.append(cap)
                added.append(cap)
            }
        }
        caps = keep
        Motion.quiet {
            applyColors()
            for cap in added { cap.applyColors(Theme.ramp(surface), scale: scale) }
            prompt.string = promptText
            for cap in pool { cap.opacity = 0 }
        }
        for cap in pool {
            if fades {
                CATransaction.begin()
                CATransaction.setCompletionBlock { cap.removeFromSuperlayer() }
                cap.add(Motion.basic("opacity", from: 1, to: 0, duration: Motion.fast, timing: Motion.exit), forKey: "out")
                if motion {
                    cap.add(Motion.basic("transform.scale", from: 1, to: 0.6, duration: Motion.fast, timing: Motion.exit), forKey: "shrink")
                }
                CATransaction.commit()
            } else {
                cap.removeFromSuperlayer()
            }
        }
        Motion.quiet { placeContent(animated: motion) }
        guard fades else {
            breathe(false)
            return
        }
        for (i, cap) in added.enumerated() {
            cap.add(Motion.basic("opacity", from: 0, to: 1, duration: Motion.fast, delay: Double(i) * 0.03), forKey: "in")
            if motion {
                let pop = Motion.spring("transform.scale", from: 0.4, to: 1, duration: 0.3, bounce: 0.45)
                if i > 0 { pop.beginTime = CACurrentMediaTime() + Double(i) * 0.03; pop.fillMode = .backwards }
                cap.add(pop, forKey: "pop")
            }
        }
        prompt.add(Motion.basic("opacity", from: 0, to: 1, duration: Motion.base), forKey: "in")
        breathe(isRecording)
        let t = Theme.tokens, r = t.ramp(surface)
        switch change {
        case .plain: break
        case .accepted:
            if motion { body.add(Motion.spring("transform.scale", from: 1.08, to: 1, duration: 0.35, bounce: 0.5), forKey: "settle") }
            body.add(Motion.basic("backgroundColor", from: t.accent.withAlphaComponent(0.35).cgColor, to: r.sunken.cgColor,
                                  duration: 0.6, timing: Motion.out), forKey: "flash")
        case .displaced:
            body.add(Motion.basic("backgroundColor", from: t.status.needsInput.fill.withAlphaComponent(0.4).cgColor,
                                  to: r.sunken.cgColor, duration: 0.9, timing: Motion.out), forKey: "flash")
            body.add(Motion.basic("borderColor", from: t.status.needsInput.fill.cgColor, to: r.hairline.cgColor,
                                  duration: 0.9, timing: Motion.out), forKey: "ring")
        }
    }

    /// Centers the caps (or the prompt) in the field. Caps that stay slide to their new place.
    private func placeContent(animated: Bool) {
        let h = Self.capHeight
        let widths = caps.map(\.width)
        let total = widths.reduce(0, +) + Self.capSpacing * CGFloat(max(0, caps.count - 1))
        var x = (bounds.width - total) / 2
        for (cap, w) in zip(caps, widths) {
            let target = CGPoint(x: x + w / 2, y: bounds.midY)
            if animated, cap.animation(forKey: "pop") == nil, cap.position != target, cap.position != .zero {
                // From where it is on screen, so a quick ⇧ on/off doesn't make ⌘ jump.
                let from = cap.presentation()?.position ?? cap.position
                cap.add(Motion.spring("position", from: NSValue(point: from), to: NSValue(point: target), duration: 0.25), forKey: "slide")
            }
            cap.bounds = CGRect(x: 0, y: 0, width: w, height: h)
            cap.position = target
            x += w + Self.capSpacing
        }
        let line = ceil(Self.font.ascender - Self.font.descender)
        prompt.frame = CGRect(x: 6, y: (bounds.height - line) / 2, width: max(0, bounds.width - 12), height: line)
    }

    /// The recording ring's glow, rising and falling until the shortcut is typed.
    private func breathe(_ on: Bool) {
        if !on {
            body.removeAnimation(forKey: "breathe")
            return
        }
        guard body.animation(forKey: "breathe") == nil else { return }
        let a = CABasicAnimation(keyPath: "shadowOpacity")
        a.fromValue = 0.15
        a.toValue = Motion.full ? 0.6 : 0.4
        a.duration = 0.9
        a.autoreverses = true
        a.repeatCount = .infinity
        a.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        body.add(a, forKey: "breathe")
    }

    /// Side-to-side shake with a red ring, for a refused combo.
    private func shake() {
        guard Motion.shouldAnimate(self) else { return }
        let t = Theme.tokens
        if Motion.full {
            let s = CAKeyframeAnimation(keyPath: "position.x")
            s.values = [0, -7, 6, -4, 3, -1, 0]
            s.keyTimes = [0, 0.15, 0.32, 0.5, 0.68, 0.85, 1]
            s.duration = 0.42
            s.isAdditive = true
            s.timingFunction = CAMediaTimingFunction(name: .easeOut)
            body.add(s, forKey: "shake")
        }
        let to = (isRecording ? t.accent : t.ramp(surface).hairline).cgColor
        body.add(Motion.basic("borderColor", from: t.status.error.fill.cgColor, to: to, duration: 0.8, timing: Motion.out),
                 forKey: "ring")
    }
}

/// One key cap inside the recorder.
final class CapLayer: CALayer {
    let token: String
    let text = CATextLayer()

    init(token: String) {
        self.token = token
        super.init()
        cornerRadius = 4
        cornerCurve = .continuous
        borderWidth = 0.5
        actions = ["position": NSNull(), "bounds": NSNull(), "opacity": NSNull(), "backgroundColor": NSNull(),
                   "borderColor": NSNull(), "transform": NSNull()]
        text.string = token
        text.font = ShortcutRecorderView.capFont
        text.fontSize = ShortcutRecorderView.capFont.pointSize
        text.alignmentMode = .center
        text.actions = ["position": NSNull(), "bounds": NSNull(), "contents": NSNull(), "foregroundColor": NSNull()]
        addSublayer(text)
    }

    override init(layer: Any) {
        token = (layer as? CapLayer)?.token ?? ""
        super.init(layer: layer)
    }

    required init?(coder: NSCoder) { fatalError() }

    /// Single glyphs are square; words (F5, Space, 1–9) fit their text.
    var width: CGFloat {
        let h = ShortcutRecorderView.capHeight
        guard token.count > 1 else { return h }
        let w = (token as NSString).size(withAttributes: [.font: ShortcutRecorderView.capFont]).width
        return max(h, ceil(w) + 10)
    }

    func applyColors(_ r: Ramp, scale: CGFloat) {
        backgroundColor = SettingsTileView.fill(r).cgColor
        borderColor = r.hairlineStrong.cgColor
        text.foregroundColor = r.primary.cgColor
        text.contentsScale = scale
        contentsScale = scale
    }

    override func layoutSublayers() {
        super.layoutSublayers()
        let font = ShortcutRecorderView.capFont
        let line = ceil(font.ascender - font.descender)
        text.frame = CGRect(x: 0, y: (bounds.height - line) / 2, width: bounds.width, height: line)
    }
}
