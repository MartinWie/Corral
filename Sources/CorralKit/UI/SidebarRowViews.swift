import AppKit
import CorralCore

// MARK: - Shared bits

/// Label that skips no-op writes (each NSTextField write invalidates layout and display). Compares
/// against the last value it wrote, not `stringValue`: reading that back yields a bridged NSString,
/// and comparing two bridged strings takes Swift's slow normalizing path (most of a sidebar refresh).
final class RowLabel: NSTextField {
    private var lastText: String?
    private var lastFont: NSFont?
    private var lastColor: NSColor?

    func setIfChanged(_ s: String) {
        guard lastText != s else { return }
        lastText = s
        stringValue = s
    }

    func setIfChanged(font f: NSFont) {
        guard lastFont !== f else { return }
        lastFont = f
        font = f
    }

    func setIfChanged(color c: NSColor) {
        guard lastColor !== c, lastColor != c else { lastColor = c; return }
        lastColor = c
        textColor = c
    }
}

private extension NSLayoutConstraint {
    func set(active: Bool) { if isActive != active { isActive = active } }
}

@MainActor
private func label(_ font: NSFont) -> RowLabel {
    let l = RowLabel(labelWithString: "")
    l.font = font
    l.translatesAutoresizingMaskIntoConstraints = false
    l.lineBreakMode = .byTruncatingTail
    return l
}

/// Disclosure chevron: an owned `chevron.right` layer, rotated to point down when expanded.
final class ChevronView: NSView {
    let chevron = SidebarFX.ownedLayer()
    private(set) var expanded = false

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        chevron.contentsGravity = .center
        layer?.addSublayer(chevron)
        NotificationCenter.default.addObserver(self, selector: #selector(themeChanged), name: .corralThemeDidChange, object: nil)
    }

    required init?(coder: NSCoder) { fatalError() }
    deinit { NotificationCenter.default.removeObserver(self) }

    @objc private func themeChanged() { needsDisplay = true }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override var wantsUpdateLayer: Bool { true }

    private var scale: CGFloat { window?.backingScaleFactor ?? 2 }

    /// Down = −π/2 in a y-up layer space; CA reports when the host draws top-down.
    private func angle(_ expanded: Bool) -> CGFloat {
        guard expanded else { return 0 }
        return chevron.contentsAreFlipped() ? .pi / 2 : -.pi / 2
    }

    func setExpanded(_ value: Bool, animated: Bool) {
        let target = angle(value)
        let current = (chevron.presentation()?.value(forKeyPath: "transform.rotation.z") as? NSNumber)
            .map { CGFloat($0.doubleValue) } ?? angle(expanded)
        let changed = value != expanded
        expanded = value
        Motion.quiet { chevron.transform = CATransform3DMakeRotation(target, 0, 0, 1) }
        if changed, animated, Motion.full, SidebarFX.canAnimate(self) {
            chevron.add(Motion.spring("transform.rotation.z", from: current, to: target), forKey: "sidebar.rotate")
        } else if changed {
            chevron.removeAnimation(forKey: "sidebar.rotate")
        }
    }

    override func updateLayer() {
        let img = GlyphCache.cgImage("chevron.right", size: 9, weight: .bold, colors: [Theme.ramp(.chrome).tertiary],
                                     scale: scale)
        Motion.quiet {
            chevron.contents = img
            chevron.contentsScale = scale
        }
    }

    override func layout() {
        super.layout()
        Motion.quiet {
            chevron.bounds = CGRect(x: 0, y: 0, width: 12, height: 12)
            chevron.position = CGPoint(x: bounds.midX, y: bounds.midY)
            chevron.transform = CATransform3DMakeRotation(angle(expanded), 0, 0, 1)
        }
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        needsDisplay = true
    }
}

// MARK: - Session row (38 pt)

/// What a session row shows; built from the live status (content-by-state table, §3.6).
struct SessionRowModel: Equatable {
    var title: String
    var subtitle: String
    var agent: AgentKind
    var activity: Activity
    var unread: Bool
    /// Start of the current state; nil hides the time.
    var since: Date?
    /// Direct agent launch still waiting for the agent's first frame ("Starting…"); idle rows only.
    var launch: AgentLaunch.Kind?

    static func make(title: String, status s: LiveStatus, agent: AgentKind, cwd: String,
                     launching: AgentLaunch.Kind? = nil) -> SessionRowModel {
        let sub: String
        switch s.activity {
        case .needsInput: sub = s.detail ?? "Waiting for your input"
        case .working: sub = s.detail.map { "Working · \($0)" } ?? "Working"
        case .done where s.unread: sub = "Done"
        case .error: sub = s.detail ?? "Error"
        case .exited: sub = "Exited"
        case .idle: sub = launching?.rowSubtitle ?? RelativeTime.compactPath(cwd)
        default: sub = RelativeTime.compactPath(cwd)
        }
        return SessionRowModel(title: title, subtitle: sub, agent: agent, activity: s.activity, unread: s.unread,
                               since: showsTime(s.activity, unread: s.unread) ? s.since : nil,
                               launch: s.activity == .idle ? launching : nil)
    }

    static func showsTime(_ a: Activity, unread: Bool) -> Bool {
        switch a {
        case .needsInput, .working, .error: return true
        case .done: return unread
        case .idle, .exited: return false
        }
    }

    /// The subtitle is a path (idle, done seen): truncate the head so the leaf survives.
    var subtitleIsPath: Bool { launch == nil && (activity == .idle || (activity == .done && !unread)) }

    /// VoiceOver state: the launch ("Starting") while it shows in the subtitle, else the activity.
    var accessibilityState: String { launch?.accessibilityState ?? Self.stateLabel(activity, unread: unread) }

    static func stateLabel(_ a: Activity, unread: Bool) -> String {
        switch a {
        case .needsInput: return "Needs input"
        case .working: return "Working"
        case .done: return unread ? "Done, unread" : "Done"
        case .error: return "Error"
        case .exited: return "Exited"
        case .idle: return "Idle"
        }
    }
}

/// [icon]─8─[title …………………]─6─[time]
///          [subtitle mono ……]─6─[agent]
final class SessionRowView: NSTableCellView, SidebarCell {
    let icon = StatusIconView(slot: 16)
    let title = label(Fonts.rowTitle)
    let subtitle = label(Fonts.rowSub)
    let time = label(Fonts.rowTime)
    let agentGlyph = GlyphView(frame: NSRect(x: 0, y: 0, width: 11, height: 11))
    let closeButton = GhostButton(symbol: "xmark", size: 8, frame: NSRect(x: 0, y: 0, width: 16, height: 16))
    /// ⌘N hint while Command is held (replaces the time).
    let hint = KeyCap("", surface: .elevated)

    private(set) var model: SessionRowModel?
    private(set) var session: UUID?
    private(set) var hovered = false
    private(set) var hintText: String?
    private(set) var loopsPaused = false

    /// Trailing slot: as wide as whatever accessory shows (time, ×, ⌘N), so the title never runs under it.
    private let slot = NSLayoutGuide()
    private var slotTime: NSLayoutConstraint!
    private var slotClose: NSLayoutConstraint!
    private var slotHint: NSLayoutConstraint!
    private var subToGlyph: NSLayoutConstraint!
    /// Height stays 11; wide symbols (OpenCode's `</>`) get their aspect width instead of shrinking.
    private var agentGlyphWidth: NSLayoutConstraint!
    private var glyphSymbol: String?

    override init(frame: NSRect) {
        super.init(frame: frame)
        icon.translatesAutoresizingMaskIntoConstraints = false
        agentGlyph.translatesAutoresizingMaskIntoConstraints = false
        // Icon first: its halo renders under the labels.
        for v in [icon, title, subtitle, time, agentGlyph, closeButton, hint] as [NSView] { addSubview(v) }
        addLayoutGuide(slot)
        textField = title

        title.setContentCompressionResistancePriority(.init(250), for: .horizontal)
        title.setContentHuggingPriority(.init(200), for: .horizontal)
        subtitle.setContentCompressionResistancePriority(.init(249), for: .horizontal)
        subtitle.setContentHuggingPriority(.init(200), for: .horizontal)
        time.alignment = .right
        time.setContentHuggingPriority(.required, for: .horizontal)
        time.setContentCompressionResistancePriority(.required, for: .horizontal)
        agentGlyph.size = 11
        closeButton.symbolWeight = .bold
        // Row buttons are pointer affordances (⌘W and the menus are the keyboard paths). Out of the
        // key-view loop, so hiding a terminal doesn't have to sort them all as key-view candidates.
        closeButton.refusesFirstResponder = true
        closeButton.setAccessibilityLabel("Close Session")
        closeButton.alphaValue = 0
        hint.alphaValue = 0

        slotTime = slot.leadingAnchor.constraint(lessThanOrEqualTo: time.leadingAnchor)
        slotClose = slot.widthAnchor.constraint(greaterThanOrEqualToConstant: 16)
        slotHint = slot.leadingAnchor.constraint(lessThanOrEqualTo: hint.leadingAnchor)
        subToGlyph = subtitle.trailingAnchor.constraint(lessThanOrEqualTo: agentGlyph.leadingAnchor, constant: -6)
        agentGlyphWidth = agentGlyph.widthAnchor.constraint(equalToConstant: 11)
        let slotMin = slot.widthAnchor.constraint(equalToConstant: 0)
        slotMin.priority = .init(250)

        NSLayoutConstraint.activate([
            icon.leadingAnchor.constraint(equalTo: leadingAnchor),
            icon.centerYAnchor.constraint(equalTo: title.centerYAnchor),
            icon.widthAnchor.constraint(equalToConstant: 16),
            icon.heightAnchor.constraint(equalToConstant: 16),

            title.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 24),
            title.topAnchor.constraint(equalTo: topAnchor, constant: 3),
            title.trailingAnchor.constraint(lessThanOrEqualTo: slot.leadingAnchor, constant: -6),

            slot.trailingAnchor.constraint(equalTo: trailingAnchor),
            slot.topAnchor.constraint(equalTo: topAnchor),
            slot.heightAnchor.constraint(equalToConstant: 1),
            slotMin,

            time.trailingAnchor.constraint(equalTo: trailingAnchor),
            time.firstBaselineAnchor.constraint(equalTo: title.firstBaselineAnchor),

            subtitle.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 24),
            subtitle.topAnchor.constraint(equalTo: title.bottomAnchor, constant: 1),
            subtitle.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor),

            agentGlyph.trailingAnchor.constraint(equalTo: trailingAnchor),
            agentGlyph.centerYAnchor.constraint(equalTo: subtitle.centerYAnchor),
            agentGlyphWidth,
            agentGlyph.heightAnchor.constraint(equalToConstant: 11),

            closeButton.trailingAnchor.constraint(equalTo: trailingAnchor),
            closeButton.centerYAnchor.constraint(equalTo: title.centerYAnchor),

            hint.trailingAnchor.constraint(equalTo: trailingAnchor),
            hint.centerYAnchor.constraint(equalTo: title.centerYAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError() }

    /// Unanimated convenience (tests, previews).
    func configure(title text: String, subtitle sub: String, agent: AgentKind, activity: Activity,
                   unread: Bool, detailIsAlert: Bool) {
        configure(SessionRowModel(title: text, subtitle: sub, agent: agent, activity: activity, unread: unread, since: nil),
                  session: nil, animated: false)
        if detailIsAlert { subtitle.setIfChanged(color: Theme.tokens.status.needsInput.text) }
    }

    func configure(_ m: SessionRowModel, session id: UUID?, animated: Bool) {
        let t = Theme.tokens
        let r = t.ramp(.chrome)
        let sameSession = id != nil && id == session
        session = id
        model = m

        title.setIfChanged(m.title)
        title.setIfChanged(font: m.activity == .needsInput ? Fonts.rowTitleStrong : (m.unread ? Fonts.rowTitleMedium : Fonts.rowTitle))
        title.setIfChanged(color: m.activity == .exited ? r.secondary : r.primary)

        subtitle.setIfChanged(m.subtitle)
        subtitle.setIfChanged(font: m.activity == .needsInput ? Fonts.rowSubStrong : Fonts.rowSub)
        let mode: NSLineBreakMode = m.subtitleIsPath ? .byTruncatingHead : .byTruncatingTail
        if subtitle.lineBreakMode != mode { subtitle.lineBreakMode = mode }
        let subColor: NSColor
        let timeColor: NSColor
        switch m.activity {
        case .needsInput: (subColor, timeColor) = (t.status.needsInput.text, t.status.needsInput.text)
        case .working: (subColor, timeColor) = (r.secondary, r.tertiary)
        case .done: (subColor, timeColor) = (r.secondary, t.status.done.text)
        case .error: (subColor, timeColor) = (t.status.error.text, t.status.error.text)
        case .exited: (subColor, timeColor) = (r.tertiary, r.tertiary)
        case .idle: (subColor, timeColor) = (r.secondary, r.tertiary)
        }
        subtitle.setIfChanged(color: subColor)
        time.setIfChanged(color: timeColor)
        refreshTime(now: Date())

        let showGlyph = m.agent != .shell && m.activity != .idle
        let tag = Self.agentTag(m.agent)
        agentGlyph.toolTip = tag.isEmpty ? nil : tag
        if agentGlyph.isHidden == showGlyph { agentGlyph.isHidden = !showGlyph }
        if showGlyph {
            let symbol = Self.agentSymbol(m.agent)
            if glyphSymbol != symbol {
                glyphSymbol = symbol
                agentGlyph.symbol = symbol
                let w = Self.glyphWidth(symbol)
                if agentGlyphWidth.constant != w { agentGlyphWidth.constant = w }
            }
            if agentGlyph.color != r.tertiary { agentGlyph.color = r.tertiary }
        }
        subToGlyph.set(active: showGlyph)

        icon.apply(StatusVisual(activity: m.activity, unread: m.unread, agent: m.agent), session: id,
                   animated: animated && sameSession)
        applyAccessory(animated: animated && sameSession)
        setAccessibilityLabel("\(m.title), \(m.accessibilityState)")
    }

    func refreshTime(now: Date) {
        time.setIfChanged(model?.since.map { RelativeTime.short(since: $0, now: now) } ?? "")
    }

    func setHovered(_ h: Bool, animated: Bool) {
        guard h != hovered else { return }
        hovered = h
        applyAccessory(animated: animated)
    }

    /// Shows "⌘N" in place of the time (nil hides it).
    func setHint(_ text: String?, animated: Bool) {
        guard text != hintText else { return }
        hintText = text
        applyAccessory(animated: animated)
    }

    /// Exactly one trailing accessory is visible: ⌘N hint > × (hover) > time.
    private func applyAccessory(animated: Bool) {
        let anim = animated && SidebarFX.canAnimate(self)
        let showHint = hintText != nil
        let showClose = hovered && !showHint
        hint.stringValue = hintText ?? ""
        SidebarFX.fade(time, to: showHint || showClose ? 0 : 1, animated: anim)
        SidebarFX.fade(closeButton, to: showClose ? 1 : 0, animated: anim)
        SidebarFX.fade(hint, to: showHint ? 1 : 0, animated: anim)
        slotTime.set(active: model?.since != nil)
        slotClose.set(active: showClose)
        slotHint.set(active: showHint)
    }

    func rowStateChanged(selected: Bool, keyWindow: Bool) {
        let suppressed = selected && keyWindow
        if icon.haloSuppressed != suppressed { icon.haloSuppressed = suppressed }
    }

    func setLoopsPaused(_ paused: Bool) {
        guard paused != loopsPaused else { return }
        loopsPaused = paused
        icon.setLoopsPaused(paused)
    }

    /// The × only takes clicks while it is shown.
    override func hitTest(_ point: NSPoint) -> NSView? {
        let hit = super.hitTest(point)
        if let hit, hit === closeButton || hit.isDescendant(of: closeButton), closeButton.alphaValue < 0.5 { return self }
        return hit
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        icon.prepareForReuse()
        // The pause flag outlives reuse; the icon must agree with it whatever its reset did.
        icon.setLoopsPaused(loopsPaused)
        session = nil
        hovered = false
        hintText = nil
        applyAccessory(animated: false)
    }

    /// `GlyphCache.agentSymbol` once per agent: it probes `NSImage(systemSymbolName:)`, which never runs in
    /// configure paths (§5.11).
    private static var agentSymbols: [AgentKind: String] = [:]

    static func agentSymbol(_ agent: AgentKind) -> String {
        if let hit = agentSymbols[agent] { return hit }
        let s = GlyphCache.agentSymbol(agent)
        agentSymbols[agent] = s
        return s
    }

    private static var glyphWidths: [String: CGFloat] = [:]

    /// Width of an 11 pt high glyph box that keeps the symbol's aspect ratio (cached per symbol).
    static func glyphWidth(_ symbol: String) -> CGFloat {
        if let hit = glyphWidths[symbol] { return hit }
        var w: CGFloat = 11
        if let img = GlyphCache.image(symbol, size: 11, weight: .medium, colors: [Theme.ramp(.chrome).tertiary]),
           img.size.height > 0 {
            w = max(11, ceil(11 * img.size.width / img.size.height))
        }
        glyphWidths[symbol] = w
        return w
    }

    static func agentTag(_ agent: AgentKind) -> String {
        switch agent {
        case .shell: return ""
        case .claude: return "Claude"
        case .opencode: return "OpenCode"
        case .pi: return "PI"
        }
    }
}

// MARK: - Folder row (28 pt)

struct FolderRowModel: Equatable {
    var name: String
    var hasDirectory: Bool
    var needsInput = 0
    var working = 0
    var doneUnread = 0
    var errors = 0
    var sessions = 0
    var expanded = true

    /// e.g. "1 error · 2 working · 6 sessions".
    var summary: String {
        var parts: [String] = []
        if needsInput > 0 { parts.append("\(needsInput) waiting") }
        if errors > 0 { parts.append(errors == 1 ? "1 error" : "\(errors) errors") }
        if working > 0 { parts.append("\(working) working") }
        if doneUnread > 0 { parts.append("\(doneUnread) done") }
        parts.append(sessions == 1 ? "1 session" : "\(sessions) sessions")
        return parts.joined(separator: " · ")
    }
}

/// Up to three static status dots (error, done, working) shown on collapsed folders.
final class PipsView: NSView {
    private let dots = (0..<3).map { _ in SidebarFX.ownedLayer() }
    private(set) var colors: [NSColor] = []

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        translatesAutoresizingMaskIntoConstraints = false
        for d in dots {
            d.cornerRadius = 2.5
            layer?.addSublayer(d)
        }
    }

    required init?(coder: NSCoder) { fatalError() }

    func set(_ next: [NSColor]) {
        let c = Array(next.prefix(3))
        guard c != colors else { return }
        colors = c
        invalidateIntrinsicContentSize()
        needsLayout = true
    }

    override var intrinsicContentSize: NSSize {
        let n = CGFloat(colors.count)
        return NSSize(width: n == 0 ? 0 : n * 5 + (n - 1) * 4, height: 5)
    }

    override func layout() {
        super.layout()
        Motion.quiet {
            for (i, d) in dots.enumerated() {
                d.isHidden = i >= colors.count
                guard i < colors.count else { continue }
                d.backgroundColor = colors[i].cgColor
                d.frame = CGRect(x: CGFloat(i) * 9, y: (bounds.height - 5) / 2, width: 5, height: 5)
            }
        }
    }
}

/// Transparent hit target that hosts the chevron (wider than the glyph, per §3.7).
final class DisclosureButton: NSButton {
    let chevron = ChevronView(frame: NSRect(x: 0, y: 0, width: 18, height: 28))

    init() {
        super.init(frame: NSRect(x: 0, y: 0, width: 18, height: 28))
        title = ""
        isBordered = false
        isTransparent = true
        setButtonType(.momentaryChange)
        refusesFirstResponder = true
        translatesAutoresizingMaskIntoConstraints = false
        chevron.autoresizingMask = [.width, .height]
        addSubview(chevron)
        setAccessibilityLabel("Expand or collapse")
    }

    required init?(coder: NSCoder) { fatalError() }
}

/// [chevron]─[folder glyph]─[name …………]…[pips][count]─[badge]
final class FolderRowView: NSTableCellView, SidebarCell {
    let disclosure = DisclosureButton()
    let glyph = GlyphView(frame: NSRect(x: 0, y: 0, width: 16, height: 16))
    let title = label(Fonts.folder)
    let pips = PipsView()
    let countLabel = label(Fonts.monoSmall)
    let badge = BadgeView(frame: .zero)
    private let trailingStack = NSStackView()

    private(set) var model: FolderRowModel?
    private(set) var hovered = false
    private(set) var selected = false
    private(set) var loopsPaused = false
    private(set) var pulsing = false
    private var shownCount = 0
    private var badgeGeneration = 0

    override init(frame: NSRect) {
        super.init(frame: frame)
        glyph.translatesAutoresizingMaskIntoConstraints = false
        badge.translatesAutoresizingMaskIntoConstraints = false
        glyph.size = 12
        glyph.weight = .regular
        glyph.setAccessibilityLabel("Folder")
        for v in [disclosure, glyph, title, trailingStack] as [NSView] { addSubview(v) }
        textField = title
        title.setContentCompressionResistancePriority(.init(250), for: .horizontal)
        countLabel.setContentCompressionResistancePriority(.required, for: .horizontal)

        trailingStack.orientation = .horizontal
        trailingStack.alignment = .centerY
        trailingStack.spacing = 6
        trailingStack.translatesAutoresizingMaskIntoConstraints = false
        trailingStack.setHuggingPriority(.required, for: .horizontal)
        for v in [pips, countLabel, badge] as [NSView] { trailingStack.addArrangedSubview(v) }
        trailingStack.setCustomSpacing(4, after: pips)
        pips.isHidden = true
        countLabel.isHidden = true
        badge.isHidden = true

        NSLayoutConstraint.activate([
            // The chevron's hit target reaches 6 pt left of the cell (hitTest below covers it).
            disclosure.leadingAnchor.constraint(equalTo: leadingAnchor, constant: -6),
            disclosure.widthAnchor.constraint(equalToConstant: 18),
            disclosure.topAnchor.constraint(equalTo: topAnchor),
            disclosure.bottomAnchor.constraint(equalTo: bottomAnchor),

            glyph.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14),
            glyph.centerYAnchor.constraint(equalTo: centerYAnchor),
            glyph.widthAnchor.constraint(equalToConstant: 16),
            glyph.heightAnchor.constraint(equalToConstant: 16),

            // Lines up with the child titles one level down.
            title.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 38),
            title.centerYAnchor.constraint(equalTo: centerYAnchor),
            title.trailingAnchor.constraint(lessThanOrEqualTo: trailingStack.leadingAnchor, constant: -6),

            trailingStack.trailingAnchor.constraint(equalTo: trailingAnchor),
            trailingStack.centerYAnchor.constraint(equalTo: centerYAnchor),
            badge.heightAnchor.constraint(equalToConstant: 16),
            pips.heightAnchor.constraint(equalToConstant: 5),
        ])
    }

    required init?(coder: NSCoder) { fatalError() }

    /// Unanimated convenience (tests).
    func configure(name: String, needsInput: Int, hasDirectory: Bool) {
        configure(FolderRowModel(name: name, hasDirectory: hasDirectory, needsInput: needsInput), animated: false)
    }

    func configure(_ m: FolderRowModel, animated: Bool) {
        let t = Theme.tokens
        let r = t.ramp(.chrome)
        let anim = animated && SidebarFX.canAnimate(self)
        model = m
        title.setIfChanged(m.name)
        title.setIfChanged(color: hovered || selected ? r.primary : r.secondary)
        glyph.symbol = m.hasDirectory ? "folder.fill" : "folder"
        if glyph.color != r.tertiary { glyph.color = r.tertiary }
        disclosure.chevron.setExpanded(m.expanded, animated: anim)
        if badge.fill != t.status.needsInput.fill { badge.fill = t.status.needsInput.fill }
        if badge.textColor != t.status.needsInput.onFill { badge.textColor = t.status.needsInput.onFill }

        let collapsed = !m.expanded
        var dots: [NSColor] = []
        if m.errors > 0 { dots.append(t.status.error.fill) }
        if m.doneUnread > 0 { dots.append(t.status.done.fill) }
        if m.working > 0 { dots.append(t.status.working.fill) }
        pips.set(collapsed ? dots : [])
        if pips.isHidden != pips.colors.isEmpty { pips.isHidden = pips.colors.isEmpty }
        countLabel.setIfChanged(collapsed && m.sessions > 0 ? "\(m.sessions)" : "")
        countLabel.setIfChanged(color: r.quaternary)
        let hideCount = countLabel.stringValue.isEmpty
        if countLabel.isHidden != hideCount { countLabel.isHidden = hideCount }
        toolTip = collapsed ? m.summary : nil

        updateBadge(m.needsInput, animated: anim)
        updatePulse()
        setAccessibilityLabel(m.needsInput > 0 ? "\(m.name), \(m.needsInput) waiting" : m.name)
    }

    /// M17: appear pops, increments push up and bump, decrements push down, disappear shrinks out.
    private func updateBadge(_ n: Int, animated: Bool) {
        let old = shownCount
        shownCount = n
        guard let layer = badge.layer else { return }
        if n > 0 {
            badgeGeneration += 1
            let appearing = badge.isHidden || layer.animation(forKey: "sidebar.badge.out") != nil
            layer.removeAnimation(forKey: "sidebar.badge.out")
            layer.removeAnimation(forKey: "sidebar.badge.fade")
            if badge.stringValue != "\(n)" { badge.stringValue = "\(n)" }
            if badge.isHidden { badge.isHidden = false }
            guard animated, old != n || appearing else { return }
            layoutSubtreeIfNeeded()
            if appearing {
                layer.add(Motion.basic("opacity", from: 0, to: 1, duration: Motion.fast, timing: Motion.out), forKey: "sidebar.badge.fade")
                if Motion.full {
                    let pop = Motion.spring("transform", from: SidebarFX.centered(layer, 0.5), to: SidebarFX.centered(layer, 1),
                                            duration: 0.30, bounce: 0.30)
                    layer.add(pop, forKey: "sidebar.badge.pop")
                }
            } else {
                SidebarFX.push(badge.text, up: n > old)
                if n > old, Motion.full { SidebarFX.bump(layer, peak: 1.2) }
            }
        } else if !badge.isHidden {
            guard animated else {
                badge.isHidden = true
                badge.stringValue = ""
                return
            }
            let generation = badgeGeneration
            let group = CAAnimationGroup()
            var parts: [CAAnimation] = [Motion.basic("opacity", from: 1, to: 0, duration: Motion.fast, timing: Motion.exit)]
            if Motion.full {
                parts.append(Motion.basic("transform", from: SidebarFX.centered(layer, 1), to: SidebarFX.centered(layer, 0.6),
                                          duration: Motion.fast, timing: Motion.exit))
            }
            group.animations = parts
            group.duration = Motion.fast
            group.fillMode = .forwards
            group.isRemovedOnCompletion = false
            CATransaction.begin()
            CATransaction.setCompletionBlock { [weak self] in
                MainActor.assumeIsolated {
                    guard let self, self.badgeGeneration == generation, self.shownCount == 0 else { return }
                    self.badge.isHidden = true
                    self.badge.stringValue = ""
                    self.badge.layer?.removeAnimation(forKey: "sidebar.badge.out")
                }
            }
            layer.add(group, forKey: "sidebar.badge.out")
            CATransaction.commit()
        }
    }

    /// L2 on the badge halo while the folder is collapsed over waiting sessions: the pulse moves to
    /// the nearest visible ancestor, so one pulse per waiting thing.
    private func updatePulse() {
        let want = !(model?.expanded ?? true) && (model?.needsInput ?? 0) > 0 && !loopsPaused
        pulsing = want
        let halo = badge.halo
        guard want else {
            halo.removeAnimation(forKey: "sidebar.l2")
            halo.removeAnimation(forKey: "sidebar.l2static")
            return
        }
        if Motion.full {
            halo.removeAnimation(forKey: "sidebar.l2static")
            if halo.animation(forKey: "sidebar.l2") == nil { halo.add(Self.ping(), forKey: "sidebar.l2") }
        } else {
            halo.removeAnimation(forKey: "sidebar.l2")
            if halo.animation(forKey: "sidebar.l2static") == nil { halo.add(Self.staticHalo(), forKey: "sidebar.l2static") }
        }
    }

    /// Scale 1 → 1.6 and fade over the first 1.1 s of each 1.6 s period, phase-synced.
    static func ping() -> CAAnimation {
        let scale = Motion.basic("transform.scale", from: 1, to: 1.6, duration: 1.1, timing: Motion.out)
        let fade = Motion.basic("opacity", from: 1, to: 0, duration: 1.1, timing: Motion.out)
        let g = CAAnimationGroup()
        g.animations = [scale, fade]
        return Motion.loop(g, period: 1.6)
    }

    /// Reduce Motion: a resting halo (scale 1.25, ≈30 % amber), held by a finished animation so the
    /// model (laid out by BadgeView) stays untouched.
    static func staticHalo() -> CAAnimation {
        let scale = Motion.basic("transform.scale", from: 1.25, to: 1.25, duration: 0.01)
        let fade = Motion.basic("opacity", from: 0.75, to: 0.75, duration: 0.01)
        let g = CAAnimationGroup()
        g.animations = [scale, fade]
        g.duration = 0.01
        g.fillMode = .forwards
        g.isRemovedOnCompletion = false
        return g
    }

    func setExpanded(_ expanded: Bool, animated: Bool) {
        guard var m = model else { return }
        m.expanded = expanded
        configure(m, animated: animated)
    }

    func setHovered(_ h: Bool, animated: Bool) {
        guard h != hovered else { return }
        hovered = h
        recolorTitle()
    }

    func rowStateChanged(selected s: Bool, keyWindow: Bool) {
        guard s != selected else { return }
        selected = s
        recolorTitle()
    }

    private func recolorTitle() {
        let r = Theme.ramp(.chrome)
        title.setIfChanged(color: hovered || selected ? r.primary : r.secondary)
    }

    func setLoopsPaused(_ paused: Bool) {
        guard paused != loopsPaused else { return }
        loopsPaused = paused
        updatePulse()
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        if let sv = superview, disclosure.frame.contains(convert(point, from: sv)) { return disclosure }
        return super.hitTest(point)
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        badge.layer?.removeAllAnimations()
        badge.text.removeAllAnimations()
        badge.halo.removeAllAnimations()
        badge.isHidden = true
        badge.stringValue = ""
        shownCount = 0
        hovered = false
        selected = false
        model = nil
    }
}

// MARK: - Section header (30 pt)

/// BACKGROUND / CLOSED label with a count; a chevron fades in on hover. Never selectable.
final class SectionHeaderView: NSTableCellView, SidebarCell {
    let title = label(Fonts.section)
    let countLabel = label(Fonts.section)
    let chevron = ChevronView(frame: NSRect(x: 0, y: 0, width: 12, height: 12))
    private(set) var hovered = false

    override init(frame: NSRect) {
        super.init(frame: frame)
        chevron.translatesAutoresizingMaskIntoConstraints = false
        chevron.alphaValue = 0
        // No `textField` outlet: group rows restyle it (system font, label color) over the section style.
        for v in [title, countLabel, chevron] as [NSView] { addSubview(v) }
        title.setContentCompressionResistancePriority(.init(250), for: .horizontal)
        NSLayoutConstraint.activate([
            title.leadingAnchor.constraint(equalTo: leadingAnchor),
            title.lastBaselineAnchor.constraint(equalTo: bottomAnchor, constant: -8),
            countLabel.leadingAnchor.constraint(equalTo: title.trailingAnchor, constant: 6),
            countLabel.lastBaselineAnchor.constraint(equalTo: title.lastBaselineAnchor),
            countLabel.trailingAnchor.constraint(lessThanOrEqualTo: chevron.leadingAnchor, constant: -6),
            chevron.trailingAnchor.constraint(equalTo: trailingAnchor),
            chevron.centerYAnchor.constraint(equalTo: title.centerYAnchor),
            chevron.widthAnchor.constraint(equalToConstant: 12),
            chevron.heightAnchor.constraint(equalToConstant: 12),
        ])
    }

    required init?(coder: NSCoder) { fatalError() }

    func configure(title text: String, count: Int, noun: String, expanded: Bool, animated: Bool) {
        let r = Theme.ramp(.chrome)
        let titleString = Fonts.sectionString(text, color: r.tertiary)
        if title.attributedStringValue != titleString { title.attributedStringValue = titleString }
        let countString = Fonts.sectionString("\(count)", color: r.quaternary)
        if countLabel.attributedStringValue != countString { countLabel.attributedStringValue = countString }
        chevron.setExpanded(expanded, animated: animated)
        setAccessibilityLabel("\(text), \(count) \(noun)\(count == 1 ? "" : "s")")
    }

    func setHovered(_ h: Bool, animated: Bool) {
        guard h != hovered else { return }
        hovered = h
        SidebarFX.fade(chevron, to: h ? 1 : 0, animated: animated && SidebarFX.canAnimate(self))
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        hovered = false
        SidebarFX.fade(chevron, to: 0, animated: false)
    }
}

// MARK: - Background and closed rows (26 pt)

struct CompactRowModel: Equatable {
    enum Style { case background, closed }
    var title: String
    var trailing: String
    var activity: Activity
    var unread: Bool
    var agent: AgentKind
    var style: Style
    /// Closed rows: re-rendered by the clock.
    var closedAt: Date?
}

/// [icon 14]─8─[title …………]……[trailing]  (closed rows: ↺ replaces the time on hover)
final class CompactRowView: NSTableCellView, SidebarCell {
    let icon = StatusIconView(slot: 14)
    let title = label(Fonts.compact)
    let trailing = label(Fonts.rowTime)
    let reopenButton = GhostButton(symbol: "arrow.uturn.backward", size: 10, frame: NSRect(x: 0, y: 0, width: 16, height: 16))

    private(set) var model: CompactRowModel?
    private(set) var session: UUID?
    private(set) var hovered = false
    private(set) var loopsPaused = false
    private var titleToReopen: NSLayoutConstraint!

    override init(frame: NSRect) {
        super.init(frame: frame)
        icon.translatesAutoresizingMaskIntoConstraints = false
        for v in [icon, title, trailing, reopenButton] as [NSView] { addSubview(v) }
        textField = title
        title.setContentCompressionResistancePriority(.init(250), for: .horizontal)
        trailing.setContentCompressionResistancePriority(.required, for: .horizontal)
        trailing.setContentHuggingPriority(.required, for: .horizontal)
        reopenButton.alphaValue = 0
        reopenButton.refusesFirstResponder = true
        reopenButton.setAccessibilityLabel("Reopen")
        reopenButton.toolTip = "Reopen"
        titleToReopen = title.trailingAnchor.constraint(lessThanOrEqualTo: reopenButton.leadingAnchor, constant: -6)
        NSLayoutConstraint.activate([
            icon.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 1),
            icon.centerYAnchor.constraint(equalTo: centerYAnchor),
            icon.widthAnchor.constraint(equalToConstant: 14),
            icon.heightAnchor.constraint(equalToConstant: 14),
            // Same title column as session rows.
            title.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 24),
            title.centerYAnchor.constraint(equalTo: centerYAnchor),
            title.trailingAnchor.constraint(lessThanOrEqualTo: trailing.leadingAnchor, constant: -6),
            trailing.trailingAnchor.constraint(equalTo: trailingAnchor),
            trailing.centerYAnchor.constraint(equalTo: centerYAnchor),
            reopenButton.trailingAnchor.constraint(equalTo: trailingAnchor),
            reopenButton.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError() }

    /// Unanimated convenience (tests).
    func configure(title text: String, trailing t: String, activity: Activity, unread: Bool, agent: AgentKind, dim: Bool) {
        configure(CompactRowModel(title: text, trailing: t, activity: activity, unread: unread, agent: agent,
                                  style: dim ? .closed : .background), session: nil, animated: false)
    }

    func configure(_ m: CompactRowModel, session id: UUID?, animated: Bool) {
        let t = Theme.tokens
        let r = t.ramp(.chrome)
        let sameSession = id != nil && id == session
        session = id
        model = m
        title.setIfChanged(m.title)
        switch m.style {
        case .closed:
            title.setIfChanged(font: Fonts.compact)
            title.setIfChanged(color: r.secondary)
            trailing.setIfChanged(font: Fonts.rowTime)
            trailing.setIfChanged(color: r.quaternary)
            trailing.setIfChanged(m.trailing)
            icon.apply(StatusVisual(activity: .idle, unread: false, agent: m.agent, quiet: true), session: nil, animated: false)
        case .background:
            title.setIfChanged(font: m.activity == .needsInput ? Fonts.compactStrong : Fonts.compact)
            title.setIfChanged(color: r.primary)
            trailing.setIfChanged(font: Fonts.section)
            let color: NSColor
            switch m.activity {
            case .needsInput: color = t.status.needsInput.text
            case .working: color = t.status.working.text
            case .done: color = t.status.done.text
            default: color = r.tertiary
            }
            trailing.setIfChanged(color: color)
            trailing.setIfChanged(m.trailing.uppercased())
            icon.apply(StatusVisual(activity: m.activity, unread: m.unread, agent: m.agent), session: id,
                       animated: animated && sameSession)
        }
        refreshTime(now: Date())
        applyAccessory(animated: animated && sameSession)
        setAccessibilityLabel("\(m.title), \(m.style == .closed ? "Closed" : SessionRowModel.stateLabel(m.activity, unread: m.unread))")
    }

    func refreshTime(now: Date) {
        guard let m = model, m.style == .closed, let at = m.closedAt else { return }
        trailing.setIfChanged(RelativeTime.short(since: at, now: now))
    }

    func setHovered(_ h: Bool, animated: Bool) {
        guard h != hovered else { return }
        hovered = h
        applyAccessory(animated: animated)
    }

    private func applyAccessory(animated: Bool) {
        let anim = animated && SidebarFX.canAnimate(self)
        let reopen = hovered && model?.style == .closed
        SidebarFX.fade(trailing, to: reopen ? 0 : 1, animated: anim)
        SidebarFX.fade(reopenButton, to: reopen ? 1 : 0, animated: anim)
        titleToReopen.set(active: reopen)
    }

    func rowStateChanged(selected: Bool, keyWindow: Bool) {
        let suppressed = selected && keyWindow
        if icon.haloSuppressed != suppressed { icon.haloSuppressed = suppressed }
    }

    func setLoopsPaused(_ paused: Bool) {
        guard paused != loopsPaused else { return }
        loopsPaused = paused
        icon.setLoopsPaused(paused)
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        let hit = super.hitTest(point)
        if let hit, hit === reopenButton || hit.isDescendant(of: reopenButton), reopenButton.alphaValue < 0.5 { return self }
        return hit
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        icon.prepareForReuse()
        icon.setLoopsPaused(loopsPaused)
        session = nil
        hovered = false
        applyAccessory(animated: false)
    }
}

// MARK: - Formatting

enum RelativeTime {
    static func short(since date: Date, now: Date = Date()) -> String {
        let s = Int(now.timeIntervalSince(date))
        if s < 60 { return "now" }
        if s < 3600 { return "\(s / 60)m" }
        if s < 86400 { return "\(s / 3600)h" }
        return "\(s / 86400)d"
    }

    static func abbreviatePath(_ p: String) -> String {
        let home = NSHomeDirectory()
        return p.hasPrefix(home) ? "~" + p.dropFirst(home.count) : p
    }

    private static let tempPrefixes = ["/var/folders/", "/private/var/folders/", "/private/tmp/", "/tmp/"]

    /// `~` for home; temp directories show only their last component. `components` keeps just the
    /// last N components (search meta uses 2).
    static func compactPath(_ p: String, components: Int? = nil) -> String {
        if tempPrefixes.contains(where: { p.hasPrefix($0) }) {
            let leaf = p.pathLeaf
            if !leaf.isEmpty { return leaf }
        }
        let short = abbreviatePath(p)
        guard let n = components, n > 0 else { return short }
        let parts = short.split(separator: "/", omittingEmptySubsequences: true)
        guard parts.count > n else { return short }
        return parts.suffix(n).joined(separator: "/")
    }
}
