import AppKit
import CorralCore

/// → on a search result: the session in depth, in place of the result list. Title, where it lives
/// and when it ran, then every matching message in order with room around the match, so the right
/// session is easy to tell apart. All text can be selected and copied. ← or esc goes back.
final class SearchPreviewView: NSView {
    let scroll = NSScrollView()
    private let content = FlippedStack()
    let titleLabel = NSTextField(wrappingLabelWithString: "")
    let placeTag = PlaceTagView()
    /// "Claude Code · ~/Documents/Code · <session id>", selectable (copy the id).
    let contextLabel = NSTextField(labelWithString: "")
    let matchesHeader = NSTextField(labelWithString: "")
    let loadingLabel = NSTextField(labelWithString: "Loading…")
    let moreLabel = NSTextField(labelWithString: "")
    private(set) var factRows: [(String, String)] = []
    private(set) var messageViews: [MessageView] = []
    private(set) var hitKey: String?
    private var tagWidth: NSLayoutConstraint!

    override init(frame: NSRect) {
        super.init(frame: frame)
        content.orientation = .vertical
        content.alignment = .leading
        content.spacing = 6
        content.edgeInsets = NSEdgeInsets(top: 12, left: 14, bottom: 14, right: 14)
        content.translatesAutoresizingMaskIntoConstraints = false
        scroll.documentView = content
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.scrollerStyle = .overlay
        scroll.translatesAutoresizingMaskIntoConstraints = false
        addSubview(scroll)
        NSLayoutConstraint.activate([
            scroll.topAnchor.constraint(equalTo: topAnchor),
            scroll.leadingAnchor.constraint(equalTo: leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: bottomAnchor),
            // Pinned on three sides (not just its width): an ambiguous document view keeps AppKit
            // re-laying out the panel, and a window fade's completion never fires.
            content.topAnchor.constraint(equalTo: scroll.contentView.topAnchor),
            content.leadingAnchor.constraint(equalTo: scroll.contentView.leadingAnchor),
            content.trailingAnchor.constraint(equalTo: scroll.contentView.trailingAnchor),
        ])
        titleLabel.font = Fonts.hitTitle
        titleLabel.maximumNumberOfLines = 3
        titleLabel.isSelectable = true
        contextLabel.font = Fonts.hitCode
        contextLabel.lineBreakMode = .byTruncatingMiddle
        contextLabel.isSelectable = true
        contextLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        tagWidth = placeTag.widthAnchor.constraint(equalToConstant: 0)
        NSLayoutConstraint.activate([tagWidth, placeTag.heightAnchor.constraint(equalToConstant: 14)])
        for l in [matchesHeader, loadingLabel, moreLabel] { l.font = Fonts.caption }
        setAccessibilityLabel("Session details")
    }

    required init?(coder: NSCoder) { fatalError() }

    /// Fills the view for `hit`; `detail` nil shows the header and "Loading…" (the index answers
    /// right after). `searched`: a query is typed (matches), else the latest messages.
    func show(_ hit: SearchHit, place: SearchPlace, detail: SearchDetail?, searched: Bool, now: Date = Date()) {
        let r = Theme.ramp(.elevated)
        let scrolledToTop = hitKey != hit.key
        hitKey = hit.key
        content.arrangedSubviews.forEach { $0.removeFromSuperview() }
        messageViews = []

        titleLabel.stringValue = hit.title.isEmpty ? "Untitled" : hit.title
        titleLabel.textColor = r.primary
        placeTag.place = place
        let titleRow = NSStackView(views: [titleLabel] + (placeTag.isHidden ? [] : [placeTag]))
        titleRow.orientation = .horizontal
        titleRow.alignment = .firstBaseline
        titleRow.spacing = 8
        tagWidth.constant = placeTag.preferredWidth
        content.addArrangedSubview(titleRow)
        titleRow.widthAnchor.constraint(equalTo: content.widthAnchor, constant: -28).isActive = true

        // One context line (the list row already says when it ran): what, where, which session.
        factRows = Self.factList(hit, detail: detail, now: now)
        contextLabel.stringValue = factRows.map(\.1).joined(separator: "  ·  ")
        contextLabel.textColor = r.tertiary
        content.addArrangedSubview(contextLabel)
        contextLabel.widthAnchor.constraint(lessThanOrEqualTo: content.widthAnchor, constant: -28).isActive = true
        content.setCustomSpacing(14, after: contextLabel)

        if let detail {
            let title = searched ? (detail.total > 0 ? "Matches · \(detail.total)" : "Matches") : "Latest messages"
            matchesHeader.attributedStringValue = Fonts.sectionString(title, color: r.tertiary)
            content.addArrangedSubview(matchesHeader)
            for m in detail.matches {
                let v = MessageView(m, agent: hit.agent)
                content.addArrangedSubview(v)
                v.widthAnchor.constraint(equalTo: content.widthAnchor, constant: -28).isActive = true
                messageViews.append(v)
                content.setCustomSpacing(10, after: v)
            }
            if detail.total > detail.matches.count {
                moreLabel.stringValue = "Showing the first \(detail.matches.count) of \(detail.total) matches"
                moreLabel.textColor = r.tertiary
                content.addArrangedSubview(moreLabel)
            } else if detail.matches.isEmpty {
                moreLabel.stringValue = searched ? "Only the title matches" : "Nothing indexed for this session yet"
                moreLabel.textColor = r.tertiary
                content.addArrangedSubview(moreLabel)
            }
        } else {
            loadingLabel.textColor = r.tertiary
            content.addArrangedSubview(loadingLabel)
        }
        content.layoutSubtreeIfNeeded()
        if scrolledToTop { scroll.contentView.scroll(to: .zero) }
        setAccessibilityLabel("Details: \(titleLabel.stringValue)")
    }

    private static let dateTime: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .short
        f.doesRelativeDateFormatting = true
        return f
    }()

    static func date(_ d: Date) -> String { dateTime.string(from: d) }

    /// What the context line shows, as (key, value): agent, directory, session id.
    static func factList(_ hit: SearchHit, detail: SearchDetail?, now: Date) -> [(String, String)] {
        var rows: [(String, String)] = [("Agent", hit.agent.displayName)]
        if !hit.cwd.isEmpty { rows.append(("Directory", SearchHitCell.abbreviateHome(hit.cwd))) }
        if !hit.sessionId.isEmpty { rows.append(("Session", hit.sessionId)) }
        return rows
    }

    /// Role, as the preview names it.
    static func roleName(_ role: String, agent: AgentKind) -> String {
        switch role {
        case "user": return "You"
        case "assistant": return agent == .shell ? "Output" : agent.displayName
        case "command": return "Command"
        case "terminal": return "Terminal"
        case "title", "name": return "Title"
        default: return role.capitalized
        }
    }

    /// One message: "You · Today at 17:16", then the text with the matches highlighted.
    final class MessageView: NSView {
        let header = NSTextField(labelWithString: "")
        let body = NSTextField(wrappingLabelWithString: "")

        init(_ m: SearchSnippet, agent: AgentKind) {
            super.init(frame: .zero)
            let r = Theme.ramp(.elevated)
            translatesAutoresizingMaskIntoConstraints = false
            header.font = Fonts.caption
            header.textColor = r.tertiary
            header.stringValue = [SearchPreviewView.roleName(m.role, agent: agent),
                                  m.date.map(SearchPreviewView.date) ?? ""].filter { !$0.isEmpty }.joined(separator: " · ")
            body.attributedStringValue = SearchPreviewView.highlighted(m.text, code: m.role == "command" || m.role == "terminal")
            body.maximumNumberOfLines = 10
            body.cell?.truncatesLastVisibleLine = true
            body.isSelectable = true
            body.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            for v in [header, body] {
                v.translatesAutoresizingMaskIntoConstraints = false
                addSubview(v)
            }
            NSLayoutConstraint.activate([
                header.topAnchor.constraint(equalTo: topAnchor),
                header.leadingAnchor.constraint(equalTo: leadingAnchor),
                header.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor),
                body.topAnchor.constraint(equalTo: header.bottomAnchor, constant: 2),
                body.leadingAnchor.constraint(equalTo: leadingAnchor),
                body.trailingAnchor.constraint(equalTo: trailingAnchor),
                body.bottomAnchor.constraint(equalTo: bottomAnchor),
            ])
        }

        required init?(coder: NSCoder) { fatalError() }
    }

    /// Snippet text (matches between \u{1}…\u{2}) as wrapping text with the matches emphasized.
    static func highlighted(_ text: String, code: Bool) -> NSAttributedString {
        let t = Theme.tokens
        let r = t.ramp(.elevated)
        let base: [NSAttributedString.Key: Any] = [.font: code ? Fonts.hitCode : Fonts.hitSnippet, .foregroundColor: r.secondary]
        let strong: [NSAttributedString.Key: Any] = [
            .font: code ? NSFont.monospacedSystemFont(ofSize: 11.5, weight: .semibold) : Fonts.hitSnippetStrong,
            .foregroundColor: r.primary,
            .backgroundColor: t.accent.withAlphaComponent(t.isChromeDark ? 0.28 : 0.18),
        ]
        let out = NSMutableAttributedString()
        SearchMarkup.append(text, to: out, base: base, strong: strong)
        return out
    }
}

/// Snippet text marks matches as \u{1}…\u{2} (SearchIndex.snippet); this styles them.
enum SearchMarkup {
    static func append(_ text: String, to out: NSMutableAttributedString,
                       base: [NSAttributedString.Key: Any], strong: [NSAttributedString.Key: Any]) {
        var inMatch = false
        var buf = ""
        func flush() {
            if !buf.isEmpty { out.append(NSAttributedString(string: buf, attributes: inMatch ? strong : base)) }
            buf = ""
        }
        for ch in text {
            switch ch {
            case "\u{1}": flush(); inMatch = true
            case "\u{2}": flush(); inMatch = false
            case "\n": buf.append(" ")
            default: buf.append(ch)
            }
        }
        flush()
    }
}

/// Stack that lays out top-down inside a scroll view.
final class FlippedStack: NSStackView {
    override var isFlipped: Bool { true }
}
