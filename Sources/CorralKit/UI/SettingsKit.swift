import AppKit
import CorralCore

// Building blocks of the Settings window: the same chrome / card language as the main window. A nav
// column on chrome, the selected page on a card, rows grouped in sunken rounded lists.

let settingsNoActions: [String: CAAction] = [
    "backgroundColor": NSNull(), "borderColor": NSNull(), "contents": NSNull(), "frame": NSNull(),
    "bounds": NSNull(), "position": NSNull(), "hidden": NSNull(),
]

/// Window content: the chrome color drawn as a layer, so it shows in `cacheDisplay` and crossfades with M31.
final class SettingsRootView: NSView {
    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
    }

    required init?(coder: NSCoder) { fatalError() }

    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        layer?.backgroundColor = Theme.tokens.chrome.cgColor
    }
}

/// Grouped list with fixed-height rows: `sunken` fill, r10, 1 pt `hairline` border, hairlines between
/// rows inset to the name column.
final class SettingsGroupView: NSView {
    let separators: [CALayer]
    let rowHeight: CGFloat
    let separatorInset: CGFloat
    var surface: Surface = .chrome { didSet { needsDisplay = true } }

    init(rows: Int, rowHeight: CGFloat, separatorInset: CGFloat) {
        separators = (1..<max(rows, 1)).map { _ in CALayer() }
        self.rowHeight = rowHeight
        self.separatorInset = separatorInset
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 10
        layer?.cornerCurve = .continuous
        layer?.borderWidth = 1
        for s in separators {
            s.actions = settingsNoActions
            layer?.addSublayer(s)
        }
    }

    required init?(coder: NSCoder) { fatalError() }

    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        let r = Theme.ramp(surface)
        layer?.backgroundColor = r.sunken.cgColor
        layer?.borderColor = r.hairline.cgColor
        for s in separators { s.backgroundColor = r.hairline.cgColor }
    }

    override func layout() {
        super.layout()
        Motion.quiet {
            for (i, s) in separators.enumerated() {
                // Non-flipped: boundary k sits k rows below the top edge.
                let y = bounds.height - CGFloat(i + 1) * rowHeight
                s.frame = CGRect(x: separatorInset, y: y, width: max(0, bounds.width - separatorInset), height: 1)
            }
        }
    }
}

/// Agent tile: r7 at twice the `sunken` overlay, monochrome agent glyph in `secondary`.
final class SettingsTileView: NSView {
    let agent: AgentKind
    let glyph = CALayer()
    var surface: Surface = .chrome { didSet { needsDisplay = true } }
    static let glyphSize: CGFloat = 13

    init(agent: AgentKind, size: CGFloat) {
        self.agent = agent
        super.init(frame: NSRect(x: 0, y: 0, width: size, height: size))
        wantsLayer = true
        layer?.cornerRadius = 7
        layer?.cornerCurve = .continuous
        glyph.actions = settingsNoActions
        glyph.contentsGravity = .center
        layer?.addSublayer(glyph)
        translatesAutoresizingMaskIntoConstraints = false
        widthAnchor.constraint(equalToConstant: size).isActive = true
        heightAnchor.constraint(equalToConstant: size).isActive = true
        setAccessibilityElement(false)
    }

    required init?(coder: NSCoder) { fatalError() }

    /// The `sunken` overlay applied twice: X + 2·(sunken − X), i.e. the overlay alpha doubled.
    static func fill(_ r: Ramp) -> NSColor {
        ColorMath.mix(RGB(r.surface), RGB(r.sunken), 2).clamped.color
    }

    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        let r = Theme.ramp(surface)
        let scale = window?.backingScaleFactor ?? 2
        layer?.backgroundColor = Self.fill(r).cgColor
        glyph.contentsScale = scale
        glyph.contents = GlyphCache.cgImage(GlyphCache.agentSymbol(agent), size: Self.glyphSize, weight: .medium,
                                            colors: [r.secondary], scale: scale)
    }

    override func layout() {
        super.layout()
        Motion.quiet { glyph.frame = bounds }
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        needsDisplay = true
    }
}

/// 1 pt hairline in a surface's `hairline` color.
final class SettingsHairline: NSView {
    var surface: Surface = .chrome { didSet { needsDisplay = true } }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        translatesAutoresizingMaskIntoConstraints = false
        heightAnchor.constraint(equalToConstant: 1).isActive = true
    }

    required init?(coder: NSCoder) { fatalError() }

    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() { layer?.backgroundColor = Theme.ramp(surface).hairline.cgColor }
}

/// One settings row: optional leading view, a title with an optional caption under it, and a trailing
/// accessory (switch, button, popup…). At least 44 pt tall; grows with a wrapping caption.
final class SettingsRow: NSView {
    let titleLabel = NSTextField(labelWithString: "")
    let captionLabel = NSTextField(wrappingLabelWithString: "")
    let leading: NSView?
    let accessory: NSView?
    var surface: Surface = .card { didSet { applyColors() } }
    static let padding: CGFloat = 14
    static let minHeight: CGFloat = 44

    init(title: String, caption: String? = nil, leading: NSView? = nil, accessory: NSView? = nil, titleWidth: CGFloat? = nil) {
        // A caption under a fixed title column would wrap by its own text (the layout loop below).
        precondition(titleWidth == nil || (caption ?? "").isEmpty, "SettingsRow: no caption with a fixed title column")
        self.leading = leading
        self.accessory = accessory
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        titleLabel.stringValue = title
        titleLabel.font = NSFont.systemFont(ofSize: 13)
        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.setContentCompressionResistancePriority(.defaultHigh, for: .horizontal)
        captionLabel.font = NSFont.systemFont(ofSize: 11.5)
        captionLabel.isSelectable = false
        captionLabel.stringValue = caption ?? ""
        captionLabel.isHidden = (caption ?? "").isEmpty
        captionLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let text = NSStackView(views: [titleLabel, captionLabel])
        text.orientation = .vertical
        text.alignment = .leading
        text.spacing = 2
        text.translatesAutoresizingMaskIntoConstraints = false
        addSubview(text)
        var cs: [NSLayoutConstraint] = [
            heightAnchor.constraint(greaterThanOrEqualToConstant: Self.minHeight),
            text.topAnchor.constraint(greaterThanOrEqualTo: topAnchor, constant: 10),
            text.bottomAnchor.constraint(lessThanOrEqualTo: bottomAnchor, constant: -10),
            text.centerYAnchor.constraint(equalTo: centerYAnchor),
        ]
        if let leading {
            leading.translatesAutoresizingMaskIntoConstraints = false
            addSubview(leading)
            cs += [leading.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Self.padding),
                   leading.centerYAnchor.constraint(equalTo: centerYAnchor),
                   text.leadingAnchor.constraint(equalTo: leading.trailingAnchor, constant: 12)]
        } else {
            cs.append(text.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Self.padding))
        }
        if let titleWidth { cs.append(titleLabel.widthAnchor.constraint(equalToConstant: titleWidth)) }
        // The caption's width comes from the row, never from its text: a wrapping label whose width is
        // fully constrained gets its height for that width from AppKit (no preferredMaxLayoutWidth: changing
        // it during layout asks the window for another constraints pass, which loops and throws).
        let textEnd: NSLayoutXAxisAnchor
        if let accessory {
            accessory.translatesAutoresizingMaskIntoConstraints = false
            addSubview(accessory)
            cs += [accessory.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -Self.padding),
                   accessory.centerYAnchor.constraint(equalTo: centerYAnchor),
                   accessory.topAnchor.constraint(greaterThanOrEqualTo: topAnchor, constant: 8)]
            textEnd = accessory.leadingAnchor
        } else {
            textEnd = trailingAnchor
        }
        let gap: CGFloat = accessory == nil ? Self.padding : 16
        if titleWidth != nil {
            // Fixed title column (no caption): the accessory takes the rest (paths, popups).
            cs.append(text.trailingAnchor.constraint(lessThanOrEqualTo: textEnd, constant: -gap))
            if let accessory { cs.append(accessory.leadingAnchor.constraint(greaterThanOrEqualTo: titleLabel.trailingAnchor, constant: 12)) }
        } else {
            cs += [text.trailingAnchor.constraint(equalTo: textEnd, constant: -gap),
                   captionLabel.widthAnchor.constraint(equalTo: text.widthAnchor)]
        }
        NSLayoutConstraint.activate(cs)
        applyColors()
    }

    required init?(coder: NSCoder) { fatalError() }

    var caption: String {
        get { captionLabel.stringValue }
        set {
            guard newValue != captionLabel.stringValue else { return }
            captionLabel.stringValue = newValue
            captionLabel.isHidden = newValue.isEmpty
        }
    }

    func applyColors() {
        let r = Theme.ramp(surface)
        titleLabel.textColor = r.primary
        captionLabel.textColor = r.secondary
    }

}

/// Rows stacked in one rounded `sunken` list, hairlines between them inset past a leading tile.
final class SettingsList: NSView {
    let stack = NSStackView()
    private(set) var rows: [NSView] = []
    private(set) var separators: [SettingsHairline] = []
    var surface: Surface = .card {
        didSet {
            needsDisplay = true
            separators.forEach { $0.surface = surface }
        }
    }

    init(_ rows: [NSView], separatorInset: CGFloat = SettingsRow.padding) {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 10
        layer?.cornerCurve = .continuous
        layer?.borderWidth = 1
        translatesAutoresizingMaskIntoConstraints = false
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 0
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
        ])
        for (i, row) in rows.enumerated() {
            if i > 0 {
                let line = SettingsHairline()
                line.surface = surface
                separators.append(line)
                let holder = NSView()
                holder.translatesAutoresizingMaskIntoConstraints = false
                holder.addSubview(line)
                NSLayoutConstraint.activate([
                    holder.heightAnchor.constraint(equalToConstant: 1),
                    line.leadingAnchor.constraint(equalTo: holder.leadingAnchor, constant: separatorInset),
                    line.trailingAnchor.constraint(equalTo: holder.trailingAnchor),
                    line.centerYAnchor.constraint(equalTo: holder.centerYAnchor),
                ])
                stack.addArrangedSubview(holder)
                holder.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
            }
            stack.addArrangedSubview(row)
            row.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        }
        self.rows = rows
    }

    required init?(coder: NSCoder) { fatalError() }

    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        let r = Theme.ramp(surface)
        layer?.backgroundColor = r.sunken.cgColor
        layer?.borderColor = r.hairline.cgColor
    }
}

/// One scrolling page on the card: big title, a line saying what it is for, then sections.
final class SettingsPage: NSView {
    let scroll = NSScrollView()
    let stack = FlippedStack()
    let titleLabel = NSTextField(labelWithString: "")
    let subtitleLabel = NSTextField(wrappingLabelWithString: "")
    let header = NSStackView()
    private(set) var sectionLabels: [(NSTextField, String)] = []
    private(set) var footnotes: [NSTextField] = []
    private(set) var lists: [SettingsList] = []
    static let inset: CGFloat = 28
    static let maxWidth: CGFloat = 640

    init(title: String, subtitle: String, accessory: NSView? = nil) {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        stack.orientation = .vertical
        // A centered column: every element is as wide as the page allows, at most `maxWidth`.
        stack.alignment = .centerX
        stack.spacing = 0
        stack.edgeInsets = NSEdgeInsets(top: 24, left: 0, bottom: Self.inset, right: 0)
        stack.translatesAutoresizingMaskIntoConstraints = false
        scroll.documentView = stack
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.scrollerStyle = .overlay
        scroll.automaticallyAdjustsContentInsets = false
        scroll.translatesAutoresizingMaskIntoConstraints = false
        addSubview(scroll)

        titleLabel.stringValue = title
        titleLabel.font = NSFont.systemFont(ofSize: 20, weight: .semibold)
        subtitleLabel.stringValue = subtitle
        subtitleLabel.font = NSFont.systemFont(ofSize: 12.5)
        subtitleLabel.isSelectable = false
        header.orientation = .horizontal
        header.alignment = .firstBaseline
        header.addArrangedSubview(titleLabel)
        if let accessory {
            header.addArrangedSubview(NSView())
            header.addArrangedSubview(accessory)
        }
        add(header, after: 4)
        add(subtitleLabel, after: 22)
        NSLayoutConstraint.activate([
            scroll.topAnchor.constraint(equalTo: topAnchor),
            scroll.bottomAnchor.constraint(equalTo: bottomAnchor),
            scroll.leadingAnchor.constraint(equalTo: leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: trailingAnchor),
            // Pinned on three sides: an ambiguous document view keeps AppKit re-laying out the window.
            stack.topAnchor.constraint(equalTo: scroll.contentView.topAnchor),
            stack.leadingAnchor.constraint(equalTo: scroll.contentView.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: scroll.contentView.trailingAnchor),
        ])
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel(title)
        applyColors()
    }

    required init?(coder: NSCoder) { fatalError() }

    /// Adds a full-width element (centered column, at most `maxWidth`).
    func add(_ v: NSView, after spacing: CGFloat) {
        v.translatesAutoresizingMaskIntoConstraints = false
        stack.addArrangedSubview(v)
        stack.setCustomSpacing(spacing, after: v)
        // Fills the column whatever the content (just below required, above any hugging), so a wrapping
        // label's width never depends on its own text.
        let fill = v.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -2 * Self.inset)
        fill.priority = NSLayoutConstraint.Priority(999)
        NSLayoutConstraint.activate([fill, v.widthAnchor.constraint(lessThanOrEqualToConstant: Self.maxWidth)])
    }

    /// "SECTION" label, the list, and an optional footnote under it.
    @discardableResult
    func addSection(_ title: String?, _ list: SettingsList, footnote: String? = nil) -> SettingsList {
        if let title {
            let label = NSTextField(labelWithString: title)
            sectionLabels.append((label, title))
            add(label, after: 8)
        }
        lists.append(list)
        if let footnote {
            add(list, after: 8)
            let note = NSTextField(wrappingLabelWithString: footnote)
            note.font = NSFont.systemFont(ofSize: 11.5)
            note.isSelectable = false
            footnotes.append(note)
            add(note, after: 26)
        } else {
            add(list, after: 26)
        }
        applyColors()
        return list
    }

    func applyColors() {
        let r = Theme.ramp(.card)
        titleLabel.textColor = r.primary
        subtitleLabel.textColor = r.secondary
        for (label, title) in sectionLabels { label.attributedStringValue = Fonts.sectionString(title, color: r.tertiary) }
        for note in footnotes { note.textColor = r.tertiary }
        for list in lists { list.needsDisplay = true }
    }
}

/// The nav column: one row per page, icon + name. Selected: `selected` fill, like a sidebar row.
final class SettingsNavView: NSView {
    final class Item: NSView {
        let pane: SettingsPane
        let icon = NSImageView()
        let label = NSTextField(labelWithString: "")
        var selected = false { didSet { if selected != oldValue { refresh() } } }
        private var hovered = false
        private var tracking: NSTrackingArea?
        var onClick: (() -> Void)?

        init(_ pane: SettingsPane) {
            self.pane = pane
            super.init(frame: .zero)
            wantsLayer = true
            layer?.cornerRadius = 7
            layer?.cornerCurve = .continuous
            translatesAutoresizingMaskIntoConstraints = false
            icon.image = NSImage(systemSymbolName: pane.symbol, accessibilityDescription: nil)?
                .withSymbolConfiguration(.init(pointSize: 13, weight: .medium))
            icon.translatesAutoresizingMaskIntoConstraints = false
            label.stringValue = pane.title
            label.font = NSFont.systemFont(ofSize: 13, weight: .medium)
            label.translatesAutoresizingMaskIntoConstraints = false
            addSubview(icon)
            addSubview(label)
            NSLayoutConstraint.activate([
                heightAnchor.constraint(equalToConstant: 30),
                icon.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
                icon.centerYAnchor.constraint(equalTo: centerYAnchor),
                icon.widthAnchor.constraint(equalToConstant: 18),
                label.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 8),
                label.centerYAnchor.constraint(equalTo: centerYAnchor),
                label.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -8),
            ])
            setAccessibilityElement(true)
            setAccessibilityRole(.button)
            setAccessibilityLabel(pane.title)
            refresh()
        }

        required init?(coder: NSCoder) { fatalError() }

        override func accessibilityPerformPress() -> Bool { onClick?(); return true }
        override func mouseDown(with event: NSEvent) { onClick?() }

        override func updateTrackingAreas() {
            super.updateTrackingAreas()
            if let tracking { removeTrackingArea(tracking) }
            let t = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self)
            addTrackingArea(t)
            tracking = t
        }

        override func mouseEntered(with event: NSEvent) { hovered = true; refresh() }
        override func mouseExited(with event: NSEvent) { hovered = false; refresh() }

        override var wantsUpdateLayer: Bool { true }
        override func updateLayer() { refresh() }

        func refresh() {
            let r = Theme.ramp(.chrome)
            Motion.quiet {
                layer?.backgroundColor = (selected ? r.selected : hovered ? r.hover : .clear).cgColor
            }
            label.textColor = selected ? r.primary : r.secondary
            icon.contentTintColor = selected ? Theme.tokens.accent : r.secondary
            setAccessibilityValue(selected ? "selected" : nil)
        }
    }

    private(set) var items: [Item] = []
    var onSelect: ((SettingsPane) -> Void)?

    init(panes: [SettingsPane]) {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 2
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.bottomAnchor.constraint(lessThanOrEqualTo: bottomAnchor),
        ])
        for pane in panes {
            let item = Item(pane)
            item.onClick = { [weak self] in self?.onSelect?(pane) }
            stack.addArrangedSubview(item)
            item.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
            items.append(item)
        }
        setAccessibilityElement(true)
        setAccessibilityRole(.list)
        setAccessibilityLabel("Settings sections")
    }

    required init?(coder: NSCoder) { fatalError() }

    func select(_ pane: SettingsPane) {
        for item in items { item.selected = item.pane == pane }
    }
}
