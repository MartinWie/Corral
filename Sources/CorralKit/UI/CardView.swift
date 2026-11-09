import AppKit
import CorralCore

/// Floating terminal card (spec §3.2): terminal background, rounded continuous corners, 1 px edge
/// and a soft shadow. Never masks: terminal layers inside it are not clipped or rounded (the
/// 4 pt inset keeps them clear of the corners and the border).
final class CardView: NSView {
    static let radius: CGFloat = 10

    /// Who takes drags over the card (the terminal card: sessions dropped beside the shown one);
    /// the owner registers the pasteboard types.
    weak var dropTarget: CardDropTarget?

    /// Full screen: radius, border and shadow go to 0.
    var flat = false {
        didSet {
            guard flat != oldValue else { return }
            needsDisplay = true
            needsLayout = true
        }
    }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        // Never masks: an implicit clip would round and clip the terminal layers.
        clipsToBounds = false
        layerContentsRedrawPolicy = .onSetNeedsDisplay
        translatesAutoresizingMaskIntoConstraints = false
    }

    required init?(coder: NSCoder) { fatalError() }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation { dropTarget?.cardDrag(sender) ?? [] }
    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation { dropTarget?.cardDrag(sender) ?? [] }
    override func draggingExited(_ sender: NSDraggingInfo?) { dropTarget?.cardDragEnded() }
    override func draggingEnded(_ sender: NSDraggingInfo) { dropTarget?.cardDragEnded() }
    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool { dropTarget?.cardDrop(sender) ?? false }

    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        guard let l = layer else { return }
        let t = Theme.tokens
        l.backgroundColor = t.card.cgColor
        l.cornerCurve = .continuous
        l.cornerRadius = flat ? 0 : Self.radius
        // A new corner radius turns masking on for backing layers (macOS 26); the card must never mask.
        l.masksToBounds = false
        l.borderWidth = flat ? 0 : 1
        l.borderColor = t.cardEdge.cgColor
        l.shadowColor = NSColor.black.cgColor
        l.shadowOpacity = flat ? 0 : Float(t.isChromeDark ? 0.28 : 0.10)
        l.shadowRadius = 12
        l.shadowOffset = CGSize(width: 0, height: -2)
        updateShadowPath()
    }

    override func layout() {
        super.layout()
        updateShadowPath()
    }

    private func updateShadowPath() {
        let r = flat ? 0 : Self.radius
        let path = flat ? nil : CGPath(roundedRect: bounds, cornerWidth: r, cornerHeight: r, transform: nil)
        Motion.quiet { layer?.shadowPath = path }
    }
}

/// Takes drags that land on a `CardView`.
protocol CardDropTarget: AnyObject {
    func cardDrag(_ info: NSDraggingInfo) -> NSDragOperation
    func cardDragEnded()
    func cardDrop(_ info: NSDraggingInfo) -> Bool
}

/// Where a session dragged onto the terminal card will go: the half it would take, tinted, with the
/// session's name.
final class SplitDropPreview: NSView {
    let label = NSTextField(labelWithString: "")
    private(set) var side: SplitDirection?

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.cornerRadius = 8
        layer?.cornerCurve = .continuous
        layer?.borderWidth = 1.5
        isHidden = true
        label.font = NSFont.systemFont(ofSize: 13, weight: .semibold)
        label.alignment = .center
        label.lineBreakMode = .byTruncatingTail
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)
        NSLayoutConstraint.activate([
            label.centerXAnchor.constraint(equalTo: centerXAnchor),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
            label.widthAnchor.constraint(lessThanOrEqualTo: widthAnchor, constant: -24),
        ])
        setAccessibilityElement(false)
    }

    required init?(coder: NSCoder) { fatalError() }

    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        let t = Theme.tokens
        layer?.backgroundColor = t.accent.withAlphaComponent(0.14).cgColor
        layer?.borderColor = t.accent.withAlphaComponent(0.6).cgColor
        label.textColor = t.accent
    }

    /// Hit-testing passes through: the card below takes the drag.
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    func show(_ side: SplitDirection, frame target: NSRect, title: String) {
        label.stringValue = title
        let appearing = isHidden
        self.side = side
        if appearing {
            frame = target
            isHidden = false
            if Motion.shouldAnimate(self), let layer {
                layer.add(Motion.basic("opacity", from: 0, to: 1, duration: Motion.base), forKey: "in")
            }
        } else if frame != target {
            if Motion.shouldAnimate(self) {
                NSAnimationContext.runAnimationGroup { ctx in
                    ctx.duration = Motion.base
                    ctx.timingFunction = Motion.std
                    animator().frame = target
                }
            } else {
                frame = target
            }
        }
    }

    func hide() {
        side = nil
        isHidden = true
    }
}

/// Opaque chrome surface behind the card.
final class ContainerBackdropView: NSView {
    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        clipsToBounds = false
        layerContentsRedrawPolicy = .onSetNeedsDisplay
    }

    required init?(coder: NSCoder) { fatalError() }

    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        layer?.backgroundColor = Theme.tokens.chrome.cgColor
    }
}
