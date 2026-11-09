import AppKit
import CorralCore

/// Card content when no terminal is shown (spec §3.13): the empty state, the closed-session preview
/// and the background-agent preview. Clear background (the card shows the terminal background),
/// `cardAppearance`, every color from the card ramp.
final class PlaceholderView: NSView {
    enum Page: Equatable {
        case empty
        case closed(UUID)
        case background(String)
    }

    /// Primary action of a preview page (Reopen / Attach); ↩ triggers it.
    let button = ProminentButton(title: "")
    private(set) var action: (() -> Void)?
    private(set) var page: Page?
    /// The job the background page shows, to refresh it in place only when it changed.
    private(set) var shownBackground: BackgroundAgent?
    /// Most rows any page shows (background: directory, agent, job, session, changed).
    static let maxGridRows = 5
    /// Clock for "Closed · 2h ago" (tests pin it).
    var now: () -> Date = { Date() }

    // Empty state
    let emptyPage = NSStackView()
    let emptyTile = PageTileView(side: 56)
    let emptyTitle = NSTextField(labelWithString: "No open sessions")
    let emptySubtitle = NSTextField(labelWithString: "Start an agent, or search everything you’ve run.")
    let tiles: [ActionTile] = [
        ActionTile(title: "New Shell", symbol: GlyphCache.agentSymbol(.shell), action: #selector(MainWindowController.newShell(_:))),
        ActionTile(title: "Claude Code", symbol: GlyphCache.agentSymbol(.claude), action: #selector(MainWindowController.newClaude(_:))),
        ActionTile(title: "OpenCode", symbol: GlyphCache.agentSymbol(.opencode), action: #selector(MainWindowController.newOpenCode(_:))),
        ActionTile(title: "PI", symbol: GlyphCache.agentSymbol(.pi), action: #selector(MainWindowController.newPi(_:))),
    ]
    let searchKey = KeyCap("", surface: .card)
    let attentionKey = KeyCap("", surface: .card)
    private let hintSearch = NSTextField(labelWithString: "Search all sessions")
    private let hintDot = NSTextField(labelWithString: "·")
    private let hintAttention = NSTextField(labelWithString: "Next needing input")
    let hintRow = NSStackView()
    /// "· ⌘I Next needing input": dropped when the card is too narrow for the whole hint row.
    let attentionHint = NSStackView()

    // Previews
    let previewPage = NSStackView()
    let previewTile = PageTileView(side: 44)
    let statusIcon = StatusIconView(slot: 28)
    let chip = PageChipView()
    let titleLabel = NSTextField(wrappingLabelWithString: "")
    let detailLabel = NSTextField(wrappingLabelWithString: "")
    let callout = PageCalloutView()
    let grid = NSGridView(numberOfColumns: 2, rows: 0)
    private(set) var gridKeys: [NSTextField] = []
    private(set) var gridValues: [NSTextField] = []
    let command = CommandBlockView()
    private var chipAttention = false
    private var previewAgent: AgentKind = .shell

    private var emptyCenter: NSLayoutConstraint!

    /// Content-to-edge margins and stack clipping resistance: below `dragThatCanResizeWindow` (510),
    /// so the (usually hidden) placeholder never sets a minimum card or window width.
    static let marginPriority = NSLayoutConstraint.Priority(500)
    /// Preferred widths (tiles 200, preview column 480) give way to the margins.
    static let preferredWidthPriority = NSLayoutConstraint.Priority(490)
    /// Text truncates before the margins break.
    static let textCompression = NSLayoutConstraint.Priority(495)
    /// Below this card width the hint row keeps only "Search all sessions".
    static let fullHintMinWidth: CGFloat = 400

    /// Relative for recent days ("Today at 17:17"), else the user's medium date and short time.
    static let dateTime: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .short
        f.doesRelativeDateFormatting = true
        return f
    }()

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        clipsToBounds = false
        buildEmptyPage()
        buildPreviewPage()
        applyTheme()
        NotificationCenter.default.addObserver(self, selector: #selector(themeChanged), name: .corralThemeDidChange, object: nil)
    }

    required init?(coder: NSCoder) { fatalError() }

    deinit { NotificationCenter.default.removeObserver(self) }

    @objc private func themeChanged() { MainActor.assumeIsolated { applyTheme() } }

    @objc func tapped() { action?() }

    // MARK: Build

    private func buildEmptyPage() {
        for l in [emptyTitle, emptySubtitle, hintSearch, hintDot, hintAttention] { l.lineBreakMode = .byTruncatingTail }
        emptyTitle.font = Fonts.pageTitle
        emptySubtitle.font = Fonts.pageBody
        emptySubtitle.alignment = .center
        for l in [hintSearch, hintDot, hintAttention] { l.font = Fonts.hint }
        // Wraps to a second line on a narrow card (width from `preferredMaxLayoutWidth` in layout()).
        emptySubtitle.lineBreakMode = .byWordWrapping
        emptySubtitle.cell?.wraps = true
        emptySubtitle.maximumNumberOfLines = 2
        emptySubtitle.cell?.truncatesLastVisibleLine = true

        for l in [emptyTitle, emptySubtitle, hintSearch, hintAttention] {
            l.setContentCompressionResistancePriority(Self.textCompression, for: .horizontal)
        }

        let tileGrid = NSGridView(views: [[tiles[0], tiles[1]], [tiles[2], tiles[3]]])
        tileGrid.rowSpacing = 10
        tileGrid.columnSpacing = 10
        // Tiles shrink together on a narrow card (each prefers 200 at a priority below the margins).
        for tile in tiles.dropFirst() { tile.widthAnchor.constraint(equalTo: tiles[0].widthAnchor).isActive = true }
        // Hovered tiles cast a shadow past the grid's edges.
        tileGrid.clipsToBounds = false
        emptyPage.clipsToBounds = false

        attentionHint.orientation = .horizontal
        attentionHint.alignment = .centerY
        attentionHint.spacing = 6
        for v in [attentionKey, hintAttention] { attentionHint.addArrangedSubview(v) }
        hintRow.orientation = .horizontal
        hintRow.alignment = .centerY
        hintRow.spacing = 6
        for v in [searchKey, hintSearch, hintDot, attentionHint] { hintRow.addArrangedSubview(v) }
        hintRow.setCustomSpacing(10, after: hintSearch)
        hintRow.setCustomSpacing(10, after: hintDot)
        for stack in [attentionHint, hintRow, emptyPage] {
            stack.setClippingResistancePriority(Self.marginPriority, for: .horizontal)
        }

        emptyPage.orientation = .vertical
        emptyPage.alignment = .centerX
        emptyPage.spacing = 0
        for v in [emptyTile, emptyTitle, emptySubtitle, tileGrid, hintRow] { emptyPage.addArrangedSubview(v) }
        emptyPage.setCustomSpacing(14, after: emptyTile)
        emptyPage.setCustomSpacing(6, after: emptyTitle)
        emptyPage.setCustomSpacing(20, after: emptySubtitle)
        emptyPage.setCustomSpacing(16, after: tileGrid)
        emptyPage.translatesAutoresizingMaskIntoConstraints = false
        emptyPage.wantsLayer = true
        addSubview(emptyPage)

        // Optical center: 6% above the geometric center.
        let guide = NSLayoutGuide()
        addLayoutGuide(guide)
        emptyCenter = emptyPage.centerYAnchor.constraint(equalTo: guide.bottomAnchor)
        NSLayoutConstraint.activate([
            guide.topAnchor.constraint(equalTo: topAnchor),
            guide.heightAnchor.constraint(equalTo: heightAnchor, multiplier: 0.44),
            emptyCenter,
            emptyPage.centerXAnchor.constraint(equalTo: centerXAnchor),
            emptyPage.widthAnchor.constraint(lessThanOrEqualToConstant: 420),
            emptyPage.leadingAnchor.constraint(greaterThanOrEqualTo: leadingAnchor, constant: 16).withPriority(Self.marginPriority),
            emptySubtitle.widthAnchor.constraint(lessThanOrEqualTo: emptyPage.widthAnchor),
        ])
    }

    private func buildPreviewPage() {
        previewTile.addCentered(statusIcon, side: 28)
        titleLabel.font = Fonts.pageTitle
        titleLabel.maximumNumberOfLines = 2
        titleLabel.lineBreakMode = .byWordWrapping
        titleLabel.cell?.truncatesLastVisibleLine = true
        // Everything on the page can be selected and copied (titles often carry ticket links).
        titleLabel.isSelectable = true
        titleLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        detailLabel.font = Fonts.pageBody
        detailLabel.maximumNumberOfLines = 3
        detailLabel.lineBreakMode = .byWordWrapping
        detailLabel.cell?.truncatesLastVisibleLine = true
        detailLabel.isSelectable = true
        detailLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        grid.rowSpacing = 6
        grid.columnSpacing = 12
        grid.rowAlignment = .firstBaseline
        for _ in 0..<Self.maxGridRows {
            let k = NSTextField(labelWithString: "")
            k.font = Fonts.hint
            k.alignment = .right
            let v = NSTextField(labelWithString: "")
            v.font = Fonts.pageMono
            v.lineBreakMode = .byTruncatingMiddle
            v.isSelectable = true
            v.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            v.setContentHuggingPriority(.defaultLow, for: .horizontal)
            grid.addRow(with: [k, v])
            gridKeys.append(k)
            gridValues.append(v)
        }
        grid.column(at: 0).xPlacement = .trailing
        grid.column(at: 1).xPlacement = .leading
        for k in gridKeys { k.setContentHuggingPriority(.required, for: .horizontal) }

        button.target = self
        button.action = #selector(tapped)
        button.keyEquivalent = "\r"
        button.imagePosition = .imageTrailing
        button.imageHugsTitle = true

        previewPage.orientation = .vertical
        previewPage.alignment = .leading
        previewPage.spacing = 0
        for v in [previewTile, chip, titleLabel, detailLabel, callout, grid, command, button] {
            previewPage.addArrangedSubview(v)
        }
        previewPage.setCustomSpacing(12, after: previewTile)
        previewPage.setCustomSpacing(8, after: chip)
        previewPage.setCustomSpacing(10, after: titleLabel)
        previewPage.setCustomSpacing(12, after: detailLabel)
        previewPage.setCustomSpacing(12, after: callout)
        previewPage.setCustomSpacing(14, after: grid)
        previewPage.setCustomSpacing(16, after: command)
        previewPage.translatesAutoresizingMaskIntoConstraints = false
        previewPage.wantsLayer = true
        previewPage.setClippingResistancePriority(Self.marginPriority, for: .horizontal)
        addSubview(previewPage)

        // Optically centered (46% of the height), its top never below 38%; pushed up when it would not fit.
        let center = NSLayoutGuide(), cap = NSLayoutGuide()
        addLayoutGuide(center)
        addLayoutGuide(cap)
        let wide = previewPage.widthAnchor.constraint(equalToConstant: 480)
        wide.priority = Self.preferredWidthPriority
        NSLayoutConstraint.activate([
            center.topAnchor.constraint(equalTo: topAnchor),
            center.heightAnchor.constraint(equalTo: heightAnchor, multiplier: 0.46),
            cap.topAnchor.constraint(equalTo: topAnchor),
            cap.heightAnchor.constraint(equalTo: heightAnchor, multiplier: 0.38),
            previewPage.centerYAnchor.constraint(equalTo: center.bottomAnchor).withPriority(.defaultLow),
            previewPage.topAnchor.constraint(lessThanOrEqualTo: cap.bottomAnchor).withPriority(.init(740)),
            previewPage.topAnchor.constraint(greaterThanOrEqualTo: topAnchor, constant: 24),
            previewPage.bottomAnchor.constraint(lessThanOrEqualTo: bottomAnchor, constant: -24).withPriority(.init(750)),
            previewPage.centerXAnchor.constraint(equalTo: centerXAnchor),
            previewPage.widthAnchor.constraint(lessThanOrEqualToConstant: 480),
            previewPage.leadingAnchor.constraint(greaterThanOrEqualTo: leadingAnchor, constant: 24).withPriority(Self.marginPriority),
            wide,
            titleLabel.widthAnchor.constraint(lessThanOrEqualTo: previewPage.widthAnchor),
            detailLabel.widthAnchor.constraint(lessThanOrEqualTo: previewPage.widthAnchor),
            callout.widthAnchor.constraint(equalTo: previewPage.widthAnchor),
            grid.widthAnchor.constraint(equalTo: previewPage.widthAnchor),
            command.widthAnchor.constraint(equalTo: previewPage.widthAnchor),
        ])
    }

    override func layout() {
        let w = previewPage.frame.width
        if w > 0 {
            if titleLabel.preferredMaxLayoutWidth != w { titleLabel.preferredMaxLayoutWidth = w }
            if detailLabel.preferredMaxLayoutWidth != w { detailLabel.preferredMaxLayoutWidth = w }
        }
        let ew = min(420, max(0, bounds.width - 32))
        if emptySubtitle.preferredMaxLayoutWidth != ew { emptySubtitle.preferredMaxLayoutWidth = ew }
        let fullHint = bounds.width >= Self.fullHintMinWidth
        if attentionHint.isHidden == fullHint {
            attentionHint.isHidden = !fullHint
            hintDot.isHidden = !fullHint
        }
        // Keycaps show on all four tiles or on none, so the grid never mixes styles.
        let tileWidth = min(ActionTile.size.width, (ew - 10) / 2)
        let caps = tileWidth >= tiles.map(\.keycapNeed).max() ?? 0
        for tile in tiles where tile.keycapAllowed != caps { tile.keycapAllowed = caps }
        super.layout()
    }

    // MARK: Theme

    func applyTheme() {
        let t = Theme.tokens
        let r = t.ramp(.card)
        appearance = t.cardAppearance
        emptyTile.setSymbol("terminal", size: 24, weight: .light, color: r.secondary)
        emptyTitle.textColor = r.primary
        emptySubtitle.textColor = r.secondary
        for l in [hintSearch, hintDot, hintAttention] { l.textColor = r.tertiary }
        for tile in tiles { tile.applyTheme() }
        if !isBackgroundPage {
            previewTile.setSymbol(GlyphCache.agentSymbol(previewAgent), size: 20, weight: .regular, color: r.secondary)
        }
        titleLabel.textColor = r.primary
        detailLabel.textColor = r.secondary
        for k in gridKeys { k.textColor = r.tertiary }
        for v in gridValues { v.textColor = r.secondary }
        callout.applyTheme()
        command.applyTheme()
        styleChip()
        button.image = Self.returnKeyImage(color: t.onAccent)
        for v in [emptyTile, previewTile, chip, callout, command] as [NSView] { v.needsDisplay = true }
    }

    private func styleChip() {
        let t = Theme.tokens
        let r = t.ramp(.card)
        if chipAttention {
            let wash = Self.amberWash(t)
            chip.fill = wash
            chip.textColor = ColorMath.guarded(RGB(t.status.needsInput.text), on: RGB(wash), target: 4.5).color
        } else {
            chip.fill = r.sunken
            chip.textColor = isBackgroundPage ? r.secondary : r.tertiary
        }
    }

    private var isBackgroundPage: Bool {
        if case .background = page { return true }
        return false
    }

    /// Amber wash composited over the card (the palette's wash is over chrome).
    static func amberWash(_ t: ThemeTokens) -> NSColor {
        ColorMath.over(RGB(t.status.needsInput.fill), RGB(t.card), t.isCardDark ? 0.16 : 0.14).color
    }

    /// Transparent leading gutter between the button title and the inline ↩ keycap.
    static let returnKeyGutter: CGFloat = 6

    /// Inline ↩ keycap inside the prominent button, drawn in the on-accent color, with a transparent
    /// leading gutter so it does not crowd the title (the button cell draws the image flush).
    static func returnKeyImage(color: NSColor) -> NSImage {
        let text = NSAttributedString(string: "↩", attributes: [.font: Fonts.returnKey, .foregroundColor: color.withAlphaComponent(0.85)])
        let s = text.size()
        let plate = NSSize(width: max(18, ceil(s.width) + 8), height: 17)
        let g = returnKeyGutter
        let img = NSImage(size: NSSize(width: plate.width + g, height: plate.height), flipped: false) { _ in
            let rect = NSRect(x: g, y: 0, width: plate.width, height: plate.height)
            color.withAlphaComponent(0.18).setFill()
            NSBezierPath(roundedRect: rect, xRadius: 4, yRadius: 4).fill()
            text.draw(at: NSPoint(x: rect.minX + (rect.width - s.width) / 2, y: (rect.height - s.height) / 2))
            return true
        }
        img.isTemplate = false
        return img
    }

    // MARK: Pages

    func showEmpty() {
        page = .empty
        shownBackground = nil
        action = nil
        previewPage.isHidden = true
        emptyPage.isHidden = false
        refreshHints()
    }

    /// Re-reads shortcuts from the main menu (it is built after the window).
    func refreshHints() {
        for tile in tiles { tile.refreshHint() }
        searchKey.stringValue = KeyHint.string(for: #selector(MainWindowController.searchSessions(_:))) ?? ""
        attentionKey.stringValue = KeyHint.string(for: #selector(MainWindowController.nextAttention(_:))) ?? ""
    }

    func showClosed(_ r: SessionRecord, reopen: @escaping () -> Void) {
        page = .closed(r.id)
        shownBackground = nil
        previewAgent = r.agent
        let t = Theme.tokens
        statusIcon.isHidden = true
        previewTile.setSymbol(GlyphCache.agentSymbol(r.agent), size: 20, weight: .regular, color: t.ramp(.card).secondary)
        chip.stringValue = Self.closedChip(r.closedAt, now: now())
        chipAttention = false
        Self.assign(titleLabel, r.displayTitle)
        detailLabel.isHidden = true
        callout.isHidden = true
        var rows: [(String, String)] = [("Directory", RelativeTime.abbreviatePath(r.cwd)), ("Agent", r.agent.displayName)]
        if let sid = r.agentSessionId { rows.append(("Session", sid)) }
        if let c = r.closedAt { rows.append(("Closed", Self.dateTime.string(from: c))) }
        setGrid(rows)
        command.setCommand(r.reopenInput)
        setButton("Reopen")
        action = reopen
        showPreview()
    }

    /// Also refills the page in place when the job changes; text writes are skipped when unchanged so
    /// a selection the user is copying survives.
    func showBackground(_ a: BackgroundAgent, attach: @escaping () -> Void) {
        page = .background(a.id)
        shownBackground = a
        previewAgent = .claude
        statusIcon.isHidden = false
        previewTile.setSymbol(nil, size: 20, weight: .regular, color: .clear)
        statusIcon.haloSuppressed = true
        statusIcon.apply(StatusVisual(activity: a.activity, unread: false, agent: .claude), session: nil, animated: false)
        chip.stringValue = a.state.replacingOccurrences(of: "_", with: " ").capitalized
        chipAttention = a.activity == .needsInput
        Self.assign(titleLabel, a.name)
        Self.assign(detailLabel, a.detail ?? "")
        detailLabel.isHidden = (a.detail ?? "").isEmpty
        if let needs = a.needs, !needs.isEmpty {
            if callout.needs != needs { callout.setNeeds(needs) }
            callout.isHidden = false
        } else {
            callout.isHidden = true
        }
        var rows = [("Directory", RelativeTime.abbreviatePath(a.cwd)), ("Agent", "Claude Code · background"),
                    ("Job", a.id), ("Session", a.sessionId)]
        if let t = a.updatedAt { rows.append(("Changed", Self.dateTime.string(from: t))) }
        setGrid(rows)
        command.setCommand(a.attachCommand)
        setButton("Attach")
        action = attach
        showPreview()
    }

    private func showPreview() {
        styleChip()
        emptyPage.isHidden = true
        previewPage.isHidden = false
    }

    private func setButton(_ title: String) {
        button.title = title
        let img = button.image ?? Self.returnKeyImage(color: Theme.tokens.onAccent)
        button.image = img
        // 14 pt padding on both sides; the image carries its own gutter to the title.
        let w = ceil(button.attributedTitle.size().width) + 28 + img.size.width
        if let c = buttonWidth { c.constant = w } else {
            buttonWidth = button.widthAnchor.constraint(equalToConstant: w)
            buttonWidth?.isActive = true
        }
    }

    private var buttonWidth: NSLayoutConstraint?

    private func setGrid(_ rows: [(String, String)]) {
        assert(rows.count <= gridKeys.count, "grid has \(gridKeys.count) rows, page wants \(rows.count)")
        for i in 0..<gridKeys.count {
            let row = grid.row(at: i)
            if i < rows.count {
                Self.assign(gridKeys[i], rows[i].0)
                Self.assign(gridValues[i], rows[i].1)
                gridValues[i].toolTip = rows[i].1
                row.isHidden = false
            } else {
                row.isHidden = true
            }
        }
    }

    /// Writes only real changes: re-assigning a selectable label drops the user's selection.
    static func assign(_ field: NSTextField, _ text: String) {
        if field.stringValue != text { field.stringValue = text }
    }

    static func closedChip(_ closedAt: Date?, now: Date) -> String {
        guard let closedAt else { return "Closed" }
        let ago = RelativeTime.short(since: closedAt, now: now)
        return ago == "now" ? "Closed · just now" : "Closed · \(ago) ago"
    }

    /// Visible rows of the facts grid, as (key, value).
    var gridRows: [(String, String)] {
        (0..<gridKeys.count).filter { !grid.row(at: $0).isHidden }.map { (gridKeys[$0].stringValue, gridValues[$0].stringValue) }
    }

    // MARK: Entrance (M2)

    /// Content fades in and rises 8 pt; empty-state tiles stagger. Presentation only.
    func playEntrance() {
        guard Motion.shouldAnimate(self) else { return }
        addEntranceAnimations()
    }

    func addEntranceAnimations() {
        let full = Motion.full
        let duration = Motion.pageEntrance(full: full).duration
        let content = page == .empty ? emptyPage : previewPage
        Motion.pageEntrance(content.layer)
        guard page == .empty, full else { return }
        for (i, tile) in tiles.enumerated() {
            Motion.entrance(tile.layer, duration: duration, delay: 0.04 + 0.03 * Double(i))
        }
    }
}

extension Fonts {
    /// 12 pt regular: hint row, grid keys, callouts.
    static let hint = NSFont.systemFont(ofSize: 12, weight: .regular)
}

private extension NSLayoutConstraint {
    func withPriority(_ p: NSLayoutConstraint.Priority) -> NSLayoutConstraint {
        priority = p
        return self
    }
}

// MARK: - Action tile

/// Empty-state shortcut (spec §3.13): sunken tile with an agent glyph, a title and the real keycap.
/// Hover lifts it (fill, border, float shadow; M29); a click sends the menu action up the responder chain.
final class ActionTile: NSView {
    static let size = NSSize(width: 200, height: 56)
    static let radius: CGFloat = 10

    let title: String
    let symbol: String
    let selector: Selector
    let glyph = NSImageView()
    let label: NSTextField
    let keycap = TileKeyCap()
    private(set) var hovered = false
    private(set) var pressed = false
    private var tracking: NSTrackingArea?
    /// Active only while the keycap shows; a hidden keycap gives its room to the title.
    private var labelBeforeKeycap: NSLayoutConstraint!
    static let labelX: CGFloat = 44
    static let keycapTrailing: CGFloat = 12

    init(title: String, symbol: String, action: Selector) {
        self.title = title
        self.symbol = symbol
        self.selector = action
        label = NSTextField(labelWithString: title)
        super.init(frame: NSRect(origin: .zero, size: Self.size))
        wantsLayer = true
        layerContentsRedrawPolicy = .onSetNeedsDisplay
        translatesAutoresizingMaskIntoConstraints = false
        glyph.imageScaling = .scaleNone
        label.font = Fonts.body13Medium
        label.lineBreakMode = .byTruncatingTail
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        for v in [glyph, label, keycap] as [NSView] {
            v.translatesAutoresizingMaskIntoConstraints = false
            addSubview(v)
        }
        labelBeforeKeycap = label.trailingAnchor.constraint(lessThanOrEqualTo: keycap.leadingAnchor, constant: -8)
        // 200 wide by preference; narrower (never wider) when the card is too narrow for the grid.
        let preferred = widthAnchor.constraint(equalToConstant: Self.size.width)
        preferred.priority = PlaceholderView.preferredWidthPriority
        NSLayoutConstraint.activate([
            preferred,
            widthAnchor.constraint(lessThanOrEqualToConstant: Self.size.width),
            heightAnchor.constraint(equalToConstant: Self.size.height),
            glyph.centerXAnchor.constraint(equalTo: leadingAnchor, constant: 14 + 10),
            glyph.centerYAnchor.constraint(equalTo: centerYAnchor),
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Self.labelX),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
            label.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -Self.keycapTrailing),
            labelBeforeKeycap,
            keycap.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -Self.keycapTrailing),
            keycap.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        setAccessibilityLabel(title)
        applyTheme()
    }

    required init?(coder: NSCoder) { fatalError() }

    func refreshHint() {
        let hint = KeyHint.string(for: selector) ?? ""
        if keycap.stringValue != hint {
            keycap.stringValue = hint
            fitKeycap()
        }
        toolTip = hint.isEmpty ? title : "\(title) (\(hint))"
    }

    /// Set by the grid: false hides the keycap on every tile when any one of them can't fit it.
    var keycapAllowed = true {
        didSet { if keycapAllowed != oldValue { needsLayout = true } }
    }

    /// Width the tile needs to show the untruncated title and the keycap side by side.
    var keycapNeed: CGFloat {
        guard !keycap.stringValue.isEmpty else { return 0 }
        return Self.labelX + ceil(label.intrinsicContentSize.width) + 8 + keycap.fittingSize.width + Self.keycapTrailing
    }

    /// Shows the keycap only when it fits next to the untruncated title (narrow cards shrink the
    /// tiles; the shortcut stays in the tooltip). Never truncates the title for the keycap.
    func fitKeycap() {
        let show = !keycap.stringValue.isEmpty && keycapAllowed && bounds.width >= keycapNeed
        if keycap.isHidden == show { keycap.isHidden = !show }
        if labelBeforeKeycap.isActive != show { labelBeforeKeycap.isActive = show }
    }

    func applyTheme() {
        let r = Theme.ramp(.card)
        glyph.image = GlyphCache.image(symbol, size: 15, weight: .regular, colors: [r.secondary])
        label.textColor = r.primary
        needsDisplay = true
    }

    /// Sends the tile's menu action to the first responder that handles it.
    @discardableResult
    func perform() -> Bool { NSApp.sendAction(selector, to: nil, from: self) }

    override func accessibilityPerformPress() -> Bool { perform() }

    // MARK: Look

    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() { applyStyle(animated: false) }

    override func layout() {
        fitKeycap()
        super.layout()
        let path = CGPath(roundedRect: bounds, cornerWidth: Self.radius, cornerHeight: Self.radius, transform: nil)
        Motion.quiet { layer?.shadowPath = path }
    }

    /// Tile fill for the current state: sunken at rest, selected on hover, pressed while down.
    var fillColor: NSColor {
        let r = Theme.ramp(.card)
        return pressed ? r.pressed : hovered ? r.selected : r.sunken
    }

    /// Keycap plate: one overlay step above the tile fill in every state, so the plate always reads
    /// (the shared `KeyCap` uses `sunken`, which is exactly the resting tile fill).
    static func keycapColors(on fill: NSColor) -> (plate: NSColor, edge: NSColor) {
        let t = Theme.tokens
        let p = RGB(t.ramp(.card).primary)
        let plate = ColorMath.over(p, RGB(fill), t.isCardDark ? 0.06 : 0.05)
        let edge = ColorMath.over(p, plate, t.isCardDark ? 0.10 : 0.12)
        return (plate.color, edge.color)
    }

    private func applyStyle(animated: Bool, duration: Double = 0.14) {
        guard let l = layer else { return }
        let t = Theme.tokens
        let r = t.ramp(.card)
        let fillColor = fillColor
        let fill = fillColor.cgColor
        let border = (hovered || pressed ? r.hairlineStrong : r.hairline).cgColor
        let shadow: Float = hovered ? 1 : 0
        let cap = Self.keycapColors(on: fillColor)
        keycap.setColors(plate: cap.plate, edge: cap.edge, animated: animated, duration: duration)
        if animated {
            let p = l.presentation() ?? l
            l.add(Motion.basic("backgroundColor", from: p.backgroundColor, to: fill, duration: duration), forKey: "tile.fill")
            l.add(Motion.basic("borderColor", from: p.borderColor, to: border, duration: duration), forKey: "tile.border")
            l.add(Motion.basic("shadowOpacity", from: p.shadowOpacity, to: shadow, duration: duration), forKey: "tile.shadow")
        }
        l.cornerRadius = Self.radius
        l.cornerCurve = .continuous
        l.masksToBounds = false   // after the radius (which turns masking on): the hover shadow must show
        l.backgroundColor = fill
        l.borderWidth = 1
        l.borderColor = border
        l.shadowColor = NSColor(white: 0, alpha: t.isCardDark ? 0.30 : 0.12).cgColor
        l.shadowRadius = 10
        l.shadowOffset = CGSize(width: 0, height: -3)
        l.shadowOpacity = shadow
    }

    func setHovered(_ h: Bool) {
        guard h != hovered else { return }
        hovered = h
        if !h { pressed = false }
        applyStyle(animated: Motion.shouldAnimate(self), duration: h ? 0.14 : 0.18)
    }

    func setPressed(_ p: Bool) {
        guard p != pressed else { return }
        pressed = p
        applyStyle(animated: Motion.shouldAnimate(self), duration: 0.06)
    }

    // MARK: Mouse

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
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) { setPressed(true) }

    override func mouseDragged(with event: NSEvent) {
        setPressed(bounds.contains(convert(event.locationInWindow, from: nil)))
    }

    override func mouseUp(with event: NSEvent) {
        let inside = bounds.contains(convert(event.locationInWindow, from: nil))
        setPressed(false)
        if inside { perform() }
    }
}

/// Keycap inside an `ActionTile`. Same metrics as the shared `KeyCap` (keycap font, padding 5×2, r4,
/// 1 px bottom edge), but the tile sets its plate so it stays one step above the tile fill.
final class TileKeyCap: NSView {
    private let label = NSTextField(labelWithString: "")
    let edge = CALayer()
    private(set) var plate: NSColor = .clear
    private(set) var edgeColor: NSColor = .clear

    var stringValue: String {
        get { label.stringValue }
        set { label.stringValue = newValue; isHidden = newValue.isEmpty }
    }

    init() {
        super.init(frame: .zero)
        wantsLayer = true
        layerContentsRedrawPolicy = .onSetNeedsDisplay
        layer?.cornerRadius = 4
        layer?.cornerCurve = .continuous
        edge.actions = ["backgroundColor": NSNull(), "frame": NSNull(), "position": NSNull(), "bounds": NSNull()]
        layer?.addSublayer(edge)
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
        isHidden = true
    }

    required init?(coder: NSCoder) { fatalError() }

    /// Sets the plate and bottom-edge colors; crossfades them with the tile's hover/press (M29).
    func setColors(plate: NSColor, edge edgeColor: NSColor, animated: Bool, duration: Double) {
        guard plate != self.plate || edgeColor != self.edgeColor else { return }
        if animated, let l = layer {
            let from = (l.presentation() ?? l).backgroundColor
            l.add(Motion.basic("backgroundColor", from: from, to: plate.cgColor, duration: duration), forKey: "cap.plate")
            let edgeFrom = (edge.presentation() ?? edge).backgroundColor
            edge.add(Motion.basic("backgroundColor", from: edgeFrom, to: edgeColor.cgColor, duration: duration), forKey: "cap.edge")
        }
        self.plate = plate
        self.edgeColor = edgeColor
        Motion.quiet {
            layer?.backgroundColor = plate.cgColor
            edge.backgroundColor = edgeColor.cgColor
        }
    }

    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        layer?.backgroundColor = plate.cgColor
        edge.backgroundColor = edgeColor.cgColor
        label.textColor = Theme.ramp(.card).secondary
    }

    override func layout() {
        super.layout()
        // Inset by the corner so the edge stays inside the rounded plate.
        Motion.quiet { edge.frame = CGRect(x: 2, y: 0, width: max(0, bounds.width - 4), height: 1) }
    }
}

// MARK: - Page parts

/// Sunken rounded tile holding a glyph (or another view, e.g. a status icon).
final class PageTileView: NSView {
    let side: CGFloat
    let glyph = NSImageView()

    init(side: CGFloat) {
        self.side = side
        super.init(frame: NSRect(x: 0, y: 0, width: side, height: side))
        wantsLayer = true
        layerContentsRedrawPolicy = .onSetNeedsDisplay
        translatesAutoresizingMaskIntoConstraints = false
        glyph.imageScaling = .scaleNone
        addCentered(glyph, side: nil)
        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: side),
            heightAnchor.constraint(equalToConstant: side),
        ])
    }

    required init?(coder: NSCoder) { fatalError() }

    func addCentered(_ v: NSView, side s: CGFloat?) {
        v.translatesAutoresizingMaskIntoConstraints = false
        addSubview(v)
        v.centerXAnchor.constraint(equalTo: centerXAnchor).isActive = true
        v.centerYAnchor.constraint(equalTo: centerYAnchor).isActive = true
        if let s {
            v.widthAnchor.constraint(equalToConstant: s).isActive = true
            v.heightAnchor.constraint(equalToConstant: s).isActive = true
        }
    }

    func setSymbol(_ name: String?, size: CGFloat, weight: NSFont.Weight, color: NSColor) {
        glyph.image = name.flatMap { GlyphCache.image($0, size: size, weight: weight, colors: [color]) }
        glyph.isHidden = name == nil
    }

    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        guard let l = layer else { return }
        let r = Theme.ramp(.card)
        l.cornerRadius = 10
        l.cornerCurve = .continuous
        l.masksToBounds = false   // the status icon's halo may spill past the tile
        l.backgroundColor = r.sunken.cgColor
        l.borderWidth = 1
        l.borderColor = r.hairline.cgColor
    }
}

/// Small rounded label chip ("Closed · 2h ago", background state).
final class PageChipView: NSView {
    let label = NSTextField(labelWithString: "")
    var fill: NSColor = .clear { didSet { needsDisplay = true } }
    var textColor: NSColor = .clear { didSet { label.textColor = textColor } }

    var stringValue: String {
        get { label.stringValue }
        set { label.stringValue = newValue }
    }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layerContentsRedrawPolicy = .onSetNeedsDisplay
        translatesAutoresizingMaskIntoConstraints = false
        label.font = Fonts.captionMedium
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)
        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: 20),
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError() }

    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        layer?.cornerRadius = 6
        layer?.cornerCurve = .continuous
        layer?.backgroundColor = fill.cgColor
    }
}

/// "Needs: …" callout: amber wash, 2 pt amber bar on the leading edge.
final class PageCalloutView: NSView {
    let label = NSTextField(wrappingLabelWithString: "")
    let bar = CALayer()

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layerContentsRedrawPolicy = .onSetNeedsDisplay
        translatesAutoresizingMaskIntoConstraints = false
        bar.actions = ["backgroundColor": NSNull(), "frame": NSNull(), "bounds": NSNull(), "position": NSNull()]
        layer?.addSublayer(bar)
        label.font = Fonts.hint
        label.maximumNumberOfLines = 3
        label.cell?.truncatesLastVisibleLine = true
        label.isSelectable = true
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            label.topAnchor.constraint(equalTo: topAnchor, constant: 8),
            label.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -8),
        ])
    }

    required init?(coder: NSCoder) { fatalError() }

    private(set) var needs: String?

    func setNeeds(_ needs: String) {
        self.needs = needs
        let r = Theme.ramp(.card)
        let s = NSMutableAttributedString(string: "Needs: ", attributes: [.font: Fonts.hintStrong, .foregroundColor: r.primary])
        s.append(NSAttributedString(string: needs, attributes: [.font: Fonts.hint, .foregroundColor: r.primary]))
        label.attributedStringValue = s
    }

    func applyTheme() {
        if let needs { setNeeds(needs) }
        needsDisplay = true
    }

    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        let t = Theme.tokens
        layer?.cornerRadius = 6
        layer?.cornerCurve = .continuous
        layer?.backgroundColor = PlaceholderView.amberWash(t).cgColor
        bar.backgroundColor = t.status.needsInput.fill.cgColor
    }

    override func layout() {
        super.layout()
        Motion.quiet { bar.frame = CGRect(x: 0, y: 0, width: 2, height: bounds.height) }
    }

}

/// Reopen / attach command: sunken block, `$` prompt, selectable mono command, copy button.
final class CommandBlockView: NSView {
    let prompt = NSTextField(labelWithString: "$")
    let label = NSTextField(labelWithString: "")
    let copyButton = GhostButton(symbol: "doc.on.doc", size: 10, frame: NSRect(x: 0, y: 0, width: 16, height: 16))
    /// Tests use a private pasteboard.
    var pasteboard: NSPasteboard = .general
    private(set) var commandText: String?

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layerContentsRedrawPolicy = .onSetNeedsDisplay
        translatesAutoresizingMaskIntoConstraints = false
        prompt.font = Fonts.pageMono
        prompt.setContentHuggingPriority(.required, for: .horizontal)
        label.font = Fonts.pageMono
        label.lineBreakMode = .byTruncatingMiddle
        label.isSelectable = true
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        copyButton.surface = .card
        copyButton.target = self
        copyButton.action = #selector(copyCommand)
        copyButton.toolTip = "Copy command"
        copyButton.setAccessibilityLabel("Copy command")
        for v in [prompt, label] as [NSView] {
            v.translatesAutoresizingMaskIntoConstraints = false
            addSubview(v)
        }
        addSubview(copyButton)
        NSLayoutConstraint.activate([
            prompt.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            prompt.firstBaselineAnchor.constraint(equalTo: label.firstBaselineAnchor),
            label.leadingAnchor.constraint(equalTo: prompt.trailingAnchor, constant: 4),
            label.topAnchor.constraint(equalTo: topAnchor, constant: 8),
            label.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -8),
            label.trailingAnchor.constraint(lessThanOrEqualTo: copyButton.leadingAnchor, constant: -8),
            copyButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            copyButton.centerYAnchor.constraint(equalTo: label.centerYAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError() }

    func setCommand(_ text: String?) {
        // Same command (an in-place refresh): keep the selection and the "copied" state.
        if text == commandText, isHidden == (text == nil) { return }
        commandText = text
        label.stringValue = text ?? ""
        label.toolTip = text
        isHidden = text == nil
        resetCopied()
    }

    /// True between a copy and the pointer leaving the block.
    private(set) var copied = false
    private var tracking: NSTrackingArea?

    @objc func copyCommand() {
        guard let commandText else { return }
        pasteboard.clearContents()
        pasteboard.setString(commandText, forType: .string)
        copied = true
        copyButton.symbol = "checkmark"
        copyButton.toolTip = "Copied"
        copyButton.setAccessibilityLabel("Copied")
    }

    /// Back to the copy glyph, so a stale "Copied" never lingers (no timers: the pointer leaving
    /// the block, or a new command, ends the confirmation).
    func resetCopied() {
        copied = false
        if copyButton.symbol != "doc.on.doc" { copyButton.symbol = "doc.on.doc" }
        copyButton.toolTip = "Copy command"
        copyButton.setAccessibilityLabel("Copy command")
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let t = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
                               owner: self, userInfo: nil)
        addTrackingArea(t)
        tracking = t
    }

    override func mouseExited(with event: NSEvent) {
        if copied { resetCopied() }
    }

    func applyTheme() {
        let r = Theme.ramp(.card)
        prompt.textColor = r.tertiary
        label.textColor = r.primary
        needsDisplay = true
    }

    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        let r = Theme.ramp(.card)
        layer?.cornerRadius = 6
        layer?.cornerCurve = .continuous
        layer?.backgroundColor = r.sunken.cgColor
    }
}

extension Fonts {
    static let returnKey = NSFont.systemFont(ofSize: 11, weight: .semibold)
    static let hintStrong = NSFont.systemFont(ofSize: 12, weight: .semibold)
}
