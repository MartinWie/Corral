import AppKit
import CorralCore

/// Covers the selected terminal while its agent launches directly (spec: launch cover). One shared
/// instance in the card, sized to the terminal stack and filled with the card color, so the terminal
/// underneath keeps rendering and its first agent frame is ready when the cover dissolves.
/// Never takes keyboard focus: typing goes to the terminal (and reveals it).
///
///     [ 56 tile: agent glyph ]
///     (◌) Starting Claude Code
///         ~/…/Code/corral
final class LaunchCoverView: NSView {
    let tile = PageTileView(side: 56)
    /// L1 working ring: phase-synced, ≤ 30 fps, paused while hidden or occluded, static under Reduce Motion.
    let spinner = StatusIconView(slot: 14)
    let titleLabel = NSTextField(labelWithString: "")
    let pathLabel = NSTextField(labelWithString: "")
    let content = NSStackView()
    private let titleRow = NSStackView()

    /// Click on the cover: reveal the terminal now.
    var onClick: (() -> Void)?
    private(set) var session: UUID?
    private(set) var kind: AgentLaunch.Kind?
    private(set) var agent: AgentKind = .claude
    /// Fading out; hidden when the fade completes (unless shown again first).
    private(set) var dismissing = false
    /// Bumped by every show/dismiss so a stale fade completion leaves newer state alone.
    private(set) var generation = 0

    static let fadeKey = "launch.reveal"

    /// Visible and not on its way out.
    var isShowing: Bool { !isHidden && !dismissing }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layerContentsRedrawPolicy = .onSetNeedsDisplay
        translatesAutoresizingMaskIntoConstraints = false
        isHidden = true

        spinner.surface = .card
        spinner.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            spinner.widthAnchor.constraint(equalToConstant: 14),
            spinner.heightAnchor.constraint(equalToConstant: 14),
        ])
        titleLabel.font = Fonts.coverTitle
        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        pathLabel.font = Fonts.pageMono
        pathLabel.lineBreakMode = .byTruncatingHead
        pathLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        titleRow.orientation = .horizontal
        titleRow.alignment = .centerY
        titleRow.spacing = 8
        titleRow.addArrangedSubview(spinner)
        titleRow.addArrangedSubview(titleLabel)

        content.orientation = .vertical
        content.alignment = .centerX
        content.spacing = 0
        for v in [tile, titleRow, pathLabel] as [NSView] { content.addArrangedSubview(v) }
        content.setCustomSpacing(16, after: tile)
        content.setCustomSpacing(6, after: titleRow)
        content.translatesAutoresizingMaskIntoConstraints = false
        content.wantsLayer = true
        content.setClippingResistancePriority(PlaceholderView.marginPriority, for: .horizontal)
        addSubview(content)

        // Optical center like the empty state: 44% from the top.
        let guide = NSLayoutGuide()
        addLayoutGuide(guide)
        let leading = content.leadingAnchor.constraint(greaterThanOrEqualTo: leadingAnchor, constant: 16)
        leading.priority = PlaceholderView.marginPriority
        NSLayoutConstraint.activate([
            guide.topAnchor.constraint(equalTo: topAnchor),
            guide.heightAnchor.constraint(equalTo: heightAnchor, multiplier: 0.44),
            content.centerYAnchor.constraint(equalTo: guide.bottomAnchor),
            content.centerXAnchor.constraint(equalTo: centerXAnchor),
            content.widthAnchor.constraint(lessThanOrEqualToConstant: 420),
            leading,
            titleRow.widthAnchor.constraint(lessThanOrEqualTo: content.widthAnchor),
            pathLabel.widthAnchor.constraint(lessThanOrEqualTo: content.widthAnchor),
        ])

        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        applyTheme()
        NotificationCenter.default.addObserver(self, selector: #selector(themeChanged), name: .corralThemeDidChange, object: nil)
    }

    required init?(coder: NSCoder) { fatalError() }

    deinit { NotificationCenter.default.removeObserver(self) }

    // MARK: Input: clicks reveal, focus never moves here

    override var acceptsFirstResponder: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func mouseDown(with event: NSEvent) { onClick?() }
    override func accessibilityPerformPress() -> Bool {
        onClick?()
        return onClick != nil
    }

    // MARK: Theme

    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        layer?.backgroundColor = Theme.tokens.card.cgColor
    }

    @objc private func themeChanged() { MainActor.assumeIsolated { applyTheme() } }

    func applyTheme() {
        let t = Theme.tokens
        let r = t.ramp(.card)
        appearance = t.cardAppearance
        tile.setSymbol(GlyphCache.agentSymbol(agent), size: 24, weight: .light, color: r.secondary)
        titleLabel.textColor = r.primary
        pathLabel.textColor = r.tertiary
        needsDisplay = true
        tile.needsDisplay = true
    }

    // MARK: Show / dismiss

    /// Shows the cover for `session` at once (no fade in: it must hide the terminal from its first
    /// frame). `entrance` lets the content rise in with the new session's switch.
    func show(session id: UUID, kind: AgentLaunch.Kind, agent: AgentKind, cwd: String, entrance: Bool) {
        generation += 1
        dismissing = false
        layer?.removeAnimation(forKey: Self.fadeKey)
        Motion.quiet { layer?.opacity = 1 }
        let agentChanged = agent != self.agent
        session = id
        self.kind = kind
        self.agent = agent
        let title = kind.title(agent: agent)
        if titleLabel.stringValue != title { titleLabel.stringValue = title }
        let path = RelativeTime.compactPath(cwd)
        if pathLabel.stringValue != path {
            pathLabel.stringValue = path
            pathLabel.toolTip = cwd
        }
        if agentChanged {
            tile.setSymbol(GlyphCache.agentSymbol(agent), size: 24, weight: .light, color: Theme.ramp(.card).secondary)
        }
        if spinner.look != .working {
            spinner.apply(StatusVisual(activity: .working, unread: false, agent: agent), session: nil, animated: false)
        }
        setAccessibilityLabel(title)
        if isHidden { isHidden = false }
        if entrance { Motion.pageEntrance(content.layer) }
    }

    /// Reveals the terminal: a Motion.base crossfade when animated, else instantly.
    func dismiss(animated: Bool) {
        guard !isHidden, !dismissing else {
            if !animated, dismissing { finishDismiss(generation) }
            return
        }
        generation += 1
        session = nil
        guard animated, let layer else {
            isHidden = true
            return
        }
        dismissing = true
        let gen = generation
        let from = layer.presentation()?.opacity ?? layer.opacity
        CATransaction.begin()
        CATransaction.setCompletionBlock { [weak self] in
            MainActor.assumeIsolated { self?.finishDismiss(gen) }
        }
        Motion.quiet { layer.opacity = 0 }
        layer.add(Motion.basic("opacity", from: from, to: 0, duration: Motion.base, timing: Motion.std), forKey: Self.fadeKey)
        CATransaction.commit()
    }

    /// End of the fade: hide and reset opacity, unless a newer show/dismiss took over.
    func finishDismiss(_ gen: Int) {
        guard gen == generation, dismissing else { return }
        dismissing = false
        isHidden = true
        layer?.removeAnimation(forKey: Self.fadeKey)
        Motion.quiet { layer?.opacity = 1 }
    }
}

extension Fonts {
    /// 15 pt semibold: launch cover title.
    static let coverTitle = NSFont.systemFont(ofSize: 15, weight: .semibold)
}
