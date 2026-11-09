import AppKit
@testable import CorralCore
import Testing
@testable import CorralKit

@MainActor
@Suite(.serialized)
struct SearchPanelTests {
    static let snapshotDir = ProcessInfo.processInfo.environment["CORRAL_SNAPSHOTS"]

    static func hit(_ key: String, agent: AgentKind = .claude, sessionId: String = "s", cwd: String = "/r",
                    title: String = "T", updated: Date? = Date(), snippets: [SearchSnippet] = []) -> SearchHit {
        SearchHit(key: key, agent: agent, sessionId: sessionId, cwd: cwd, title: title, updated: updated, snippets: snippets)
    }

    static func snippet(_ role: String, _ text: String) -> SearchSnippet { SearchSnippet(role: role, text: text, date: nil) }

    /// A panel with one open, one closed and one outside hit (in that order).
    static func placed(_ f: Fixture) -> (SearchPanelController, open: UUID, closed: UUID) {
        // Agent sessions: only those land in Closed when closed.
        f.manager.newSession(agent: .claude, cwd: f.dir.path)
        let open = f.selected!
        f.manager.newSession(agent: .claude, cwd: f.dir.path)
        let closed = f.selected!
        f.manager.close(closed)
        let p = SearchPanelController(manager: f.manager)
        p.hits = [hit("corral:\(open.uuidString)", agent: .shell, sessionId: open.uuidString),
                  hit("corral:\(closed.uuidString)", agent: .shell, sessionId: closed.uuidString),
                  hit("claude:x", sessionId: "x")]
        p.applyFilter()
        return (p, open, closed)
    }

    @Test func searchesFiltersAndOpens() async throws {
        let f = Fixture(start: true)
        defer { f.cleanup() }
        f.manager.newSession(agent: .shell, cwd: f.dir.path)
        let open = f.selected!
        f.manager.index.addScrollback(session: UUID(), title: "gradle", cwd: "/r", text: "BUILD FAILED zebra", created: Date(), closed: Date())
        f.manager.index.addScrollback(session: open, title: "open one", cwd: "/r", text: "zebra open", created: Date(), closed: Date())
        f.manager.index.queue.sync {}
        let p = SearchPanelController(manager: f.manager)
        p.field.stringValue = "zebra"
        p.runQuery()
        await waitUntil { p.shown.count == 2 }
        #expect(p.shown.count == 2)
        #expect(p.status.stringValue == "2 sessions")
        for row in 0..<p.numberOfRows(in: p.table) { _ = p.tableView(p.table, viewFor: nil, row: row) }
        p.filter.selectedSegment = 1
        p.filterChanged()
        #expect(p.shown.map(\.corralSessionId) == [open])
        p.filter.selectedSegment = 3
        p.filterChanged()
        #expect(p.shown.count == 1)
        p.filter.selectedSegment = 2
        p.filterChanged()
        #expect(p.shown.isEmpty)
        p.filter.selectedSegment = 0
        p.filterChanged()
        let tv = NSTextView()
        #expect(p.control(p.field, textView: tv, doCommandBy: #selector(NSResponder.moveDown(_:))))
        #expect(p.control(p.field, textView: tv, doCommandBy: #selector(NSResponder.moveUp(_:))))
        #expect(!p.control(p.field, textView: tv, doCommandBy: #selector(NSResponder.moveLeft(_:))))
        p.table.selectRowIndexes([p.shown.firstIndex { $0.corralSessionId == open }!], byExtendingSelection: false)
        #expect(p.control(p.field, textView: tv, doCommandBy: #selector(NSResponder.insertNewline(_:))))
        #expect(f.selected == open)
        #expect(p.control(p.field, textView: tv, doCommandBy: #selector(NSResponder.cancelOperation(_:))))
        p.field.stringValue = ""
        p.queryChanged()
        await waitUntil { p.status.stringValue == "Recent sessions" }
        #expect(p.status.stringValue == "Recent sessions")
    }

    /// → at the end of the query shows the selected session's details and matching messages;
    /// ↑↓ browse, ← / esc go back, a new query drops them. The list says how often a session matched.
    @Test func detailsOnRightArrow() async throws {
        let f = Fixture(start: true)
        defer { f.cleanup() }
        for (title, text) in [("first zebra", "zebra one\nmore zebra here"), ("second zebra", "zebra two")] {
            f.manager.index.addScrollback(session: UUID(), title: title, cwd: f.dir.path, text: text,
                                          created: Date(timeIntervalSince1970: 1_000_000), closed: Date())
        }
        f.manager.index.queue.sync {}
        let p = SearchPanelController(manager: f.manager)
        p.field.stringValue = "zebra"
        p.runQuery()
        await waitUntil { p.shown.count == 2 }
        // Messages only: the title doc matches too but isn't counted (the row shows the title).
        #expect(p.shown.allSatisfy { $0.matchCount == 1 })
        #expect(SearchHitCell.meta(p.shown[0]).contains("· 1 match · "))
        #expect(p.footerLabels.first?.stringValue == "Details")

        let tv = NSTextView()
        tv.string = "zebra"
        tv.setSelectedRange(NSRange(location: 2, length: 0))
        #expect(!p.control(p.field, textView: tv, doCommandBy: #selector(NSResponder.moveRight(_:))))  // caret mid-query
        #expect(!p.previewShown)
        tv.setSelectedRange(NSRange(location: 5, length: 0))
        #expect(p.control(p.field, textView: tv, doCommandBy: #selector(NSResponder.moveRight(_:))))
        #expect(p.previewShown && !p.preview.isHidden)
        #expect(p.preview.titleLabel.stringValue == p.shown[0].title)
        #expect(p.preview.factRows.map(\.0).contains("Directory"))
        #expect(p.footerLabels.first?.stringValue == "Back")
        await waitUntil { !p.preview.messageViews.isEmpty }
        #expect(p.preview.matchesHeader.attributedStringValue.string.uppercased() == "MATCHES · 1")
        #expect(p.preview.messageViews.allSatisfy { $0.body.attributedStringValue.string.lowercased().contains("zebra") })
        #expect(p.preview.messageViews.allSatisfy { $0.body.isSelectable })
        // ↓ shows the next result's details.
        let firstKey = p.preview.hitKey
        #expect(p.control(p.field, textView: tv, doCommandBy: #selector(NSResponder.moveDown(_:))))
        #expect(p.preview.hitKey != firstKey && p.previewShown)
        // ← back to the list; esc closes the details before anything else.
        #expect(p.control(p.field, textView: tv, doCommandBy: #selector(NSResponder.moveLeft(_:))))
        #expect(!p.previewShown && p.preview.isHidden)
        #expect(!p.control(p.field, textView: tv, doCommandBy: #selector(NSResponder.moveLeft(_:))))
        p.showPreview()
        #expect(p.control(p.field, textView: tv, doCommandBy: #selector(NSResponder.cancelOperation(_:))))
        #expect(!p.previewShown && p.field.stringValue == "zebra")
        // New results that still hold the session keep its details (→ pressed right after typing);
        // results without it bring the list back.
        p.showPreview()
        let kept = try #require(p.preview.hitKey)
        let keptTitle = try #require(p.shown.first { $0.key == kept }?.title)
        p.field.stringValue = keptTitle.components(separatedBy: " ")[0]
        p.runQuery()
        await waitUntil { p.shown.count == 1 }
        #expect(p.previewShown && p.preview.hitKey == kept)
        #expect(p.table.selectedRow == 0)
        p.field.stringValue = keptTitle.hasPrefix("first") ? "second" : "first"
        p.runQuery()
        await waitUntil { p.shown.first?.key != kept }
        #expect(!p.previewShown && p.preview.isHidden)
        // Recent list (no query): the details show the latest messages.
        p.field.stringValue = ""
        p.runQuery()
        await waitUntil { p.status.stringValue == "Recent sessions" && !p.shown.isEmpty }
        p.showPreview()
        await waitUntil { !p.preview.messageViews.isEmpty }
        #expect(p.preview.matchesHeader.attributedStringValue.string.uppercased() == "LATEST MESSAGES")
        // After a click into the details' text (to copy), typing keys go back to the query field.
        if let panel = p.window as? SearchPanel {
            p.showPreview()
            panel.makeFirstResponder(p.preview.titleLabel)
            #expect(panel.firstResponder !== p.field.currentEditor())
            let key = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: panel.windowNumber,
                                       context: nil, characters: "x", charactersIgnoringModifiers: "x", isARepeat: false, keyCode: 7)!
            panel.sendEvent(key)
            #expect(p.field.currentEditor() != nil && panel.firstResponder === p.field.currentEditor())
        }
        #expect(SearchPreviewView.roleName("user", agent: .claude) == "You")
        #expect(SearchPreviewView.roleName("assistant", agent: .claude) == "Claude Code")
        #expect(SearchPreviewView.roleName("command", agent: .claude) == "Command")
    }

    @Test func snippetHighlighting() {
        let s = SearchHitCell.highlight([SearchSnippet(role: "user", text: "fix \u{1}thumb\u{2} sizes", date: nil),
                                         SearchSnippet(role: "command", text: "rg \u{1}thumb\u{2}", date: nil)])
        #expect(s.string == "› fix thumb sizes\n$ rg thumb")
        let cell = SearchHitCell()
        cell.configure(SearchHit(key: "claude:x", agent: .claude, sessionId: "x", cwd: NSHomeDirectory() + "/r",
                                 title: "T", updated: Date(), snippets: []), badge: "")
    }

    @Test func snippetStylesAndMatches() {
        let lines = SearchHitCell.lines([Self.snippet("user", "fix \u{1}thumb\u{2} sizes"),
                                         Self.snippet("command", "rg \u{1}thumb\u{2}\nnext"),
                                         Self.snippet("assistant", "\u{1}thumb\u{2} done"),
                                         Self.snippet("assistant", "fourth")], limit: 3)
        #expect(lines.count == 3)
        #expect(lines[1].string == "$ rg thumb next")
        let t = Theme.tokens
        #expect(lines[0].attribute(.foregroundColor, at: 0, effectiveRange: nil) as? NSColor == t.accent)
        #expect(lines[1].attribute(.foregroundColor, at: 0, effectiveRange: nil) as? NSColor == t.ramp(.elevated).tertiary)
        #expect((lines[1].attribute(.font, at: 3, effectiveRange: nil) as? NSFont)?.isFixedPitch == true)
        #expect(lines[2].attribute(.foregroundColor, at: 6, effectiveRange: nil) as? NSColor == t.ramp(.elevated).secondary)
        // Matches: semibold primary, tagged for the wash; never a background color (no yellow/amber).
        var range = NSRange()
        #expect(lines[0].attribute(.searchMatch, at: 6, effectiveRange: &range) != nil)
        #expect(range == NSRange(location: 6, length: 5))
        #expect(lines[0].attribute(.foregroundColor, at: 6, effectiveRange: nil) as? NSColor == t.ramp(.elevated).primary)
        #expect(lines[0].attribute(.backgroundColor, at: 6, effectiveRange: nil) == nil)
        #expect(lines[2].attribute(.searchMatch, at: 0, effectiveRange: nil) != nil)

        let view = SnippetView(frame: NSRect(x: 0, y: 0, width: 400, height: 48))
        view.lines = lines
        let rects = view.matchRects()
        #expect(rects.count == 3)
        #expect(rects.allSatisfy { $0.minX >= 0 && $0.height == 15 })
        #expect(rects[1].minY == 17)
        // A match past the truncation point gets no wash; one cut by it is clamped.
        let narrow = SnippetView(frame: NSRect(x: 0, y: 0, width: 40, height: 16))
        narrow.lines = SearchHitCell.lines([Self.snippet("assistant", "a long lead in before \u{1}far\u{2}")])
        #expect(narrow.matchRects().isEmpty)
        narrow.lines = SearchHitCell.lines([Self.snippet("assistant", "\u{1}averyveryverylongmatch\u{2}")])
        #expect(narrow.matchRects().first.map { $0.maxX <= 40 + 2 } == true)
        let bitmap = narrow.bitmapImageRepForCachingDisplay(in: narrow.bounds)!
        narrow.cacheDisplay(in: narrow.bounds, to: bitmap)
        #expect(!view.isAccessibilityElement())
    }

    @Test func scopeCyclesWithTab() {
        let f = Fixture()
        defer { f.cleanup() }
        let (p, open, _) = Self.placed(f)
        let tv = NSTextView()
        #expect(p.shownPlaces == [.open, .closed, .outside])
        #expect(p.control(p.field, textView: tv, doCommandBy: #selector(NSResponder.insertTab(_:))))
        #expect(p.filter.selectedSegment == 1)
        #expect(p.shown.map(\.corralSessionId) == [open])
        #expect(p.control(p.field, textView: tv, doCommandBy: #selector(NSResponder.insertBacktab(_:))))
        #expect(p.filter.selectedSegment == 0)
        #expect(p.shown.count == 3)
        #expect(p.control(p.field, textView: tv, doCommandBy: #selector(NSResponder.insertBacktab(_:))))
        #expect(p.filter.selectedSegment == 3)
        #expect(p.shown.map(\.key) == ["claude:x"])
        #expect(p.control(p.field, textView: tv, doCommandBy: #selector(NSResponder.insertTab(_:))))
        #expect(p.filter.selectedSegment == 0)
        #expect(p.status.stringValue == "Recent sessions")
    }

    @Test func doubleEscapeClearsThenCloses() {
        let f = Fixture(start: true)
        defer { f.cleanup() }
        let p = SearchPanelController(manager: f.manager)
        let panel = p.window!
        panel.alphaValue = 0
        panel.ignoresMouseEvents = true
        panel.orderFrontRegardless()
        defer { panel.orderOut(nil) }
        let was = Motion.enabled
        Motion.enabled = false
        defer { Motion.enabled = was }
        let tv = NSTextView()
        p.field.stringValue = "zebra"
        p.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification))
        #expect(!p.clearButton.isHidden)
        #expect(p.control(p.field, textView: tv, doCommandBy: #selector(NSResponder.cancelOperation(_:))))
        #expect(p.field.stringValue.isEmpty)
        #expect(p.clearButton.isHidden)
        #expect(panel.isVisible)
        // The panel's own Esc (focus outside the field) takes the same path.
        p.field.stringValue = "again"
        (panel as? SearchPanel)?.cancelOperation(nil)
        #expect(p.field.stringValue.isEmpty)
        #expect(panel.isVisible)
        let before = p.presentation
        #expect(p.control(p.field, textView: tv, doCommandBy: #selector(NSResponder.cancelOperation(_:))))
        #expect(!panel.isVisible)
        #expect(p.presentation == before + 1)
        #expect(panel.alphaValue == 1)
        p.dismiss(animated: true)   // already hidden: no-op
        #expect(p.presentation == before + 1)
    }

    @Test func clickAwayAndAnimatedDismiss() async throws {
        let f = Fixture()
        defer { f.cleanup() }
        let p = SearchPanelController(manager: f.manager)
        let panel = p.window!
        panel.alphaValue = 0
        panel.ignoresMouseEvents = true
        defer { panel.orderOut(nil) }
        let was = Motion.enabled
        // Resigning key (click-away) dismisses.
        Motion.enabled = false
        panel.orderFrontRegardless()
        p.windowDidResignKey(Notification(name: NSWindow.didResignKeyNotification))
        Motion.enabled = was
        #expect(!panel.isVisible)

        // A re-present during the fade cancels the stale orderOut. (Completions arrive on the main
        // queue, so the test yields instead of spinning the run loop.)
        panel.alphaValue = 0
        panel.orderFrontRegardless()
        Motion.enabled = true
        p.dismiss(animated: true)
        Motion.enabled = was
        let presented = p.presentation
        p.invalidatePendingDismiss()
        #expect(p.presentation == presented + 1)
        try await Task.sleep(for: .milliseconds(400))
        #expect(panel.isVisible)

        // Otherwise the fade ends in orderOut.
        Motion.enabled = true
        p.dismiss(animated: true)
        Motion.enabled = was
        await waitUntil { !panel.isVisible }
        #expect(!panel.isVisible)
        #expect(panel.alphaValue == 1)
    }

    @Test func emptyStates() {
        let f = Fixture()
        defer { f.cleanup() }
        let p = SearchPanelController(manager: f.manager)
        #expect(p.emptyView.isHidden)   // nothing searched yet
        p.applyFilter()
        #expect(!p.emptyView.isHidden)
        #expect(p.emptyTitle.stringValue == "No recent sessions")
        p.field.stringValue = "kafka"
        p.applyFilter()
        #expect(!p.emptyView.isHidden)
        #expect(p.emptyTitle.stringValue == "No matches for “kafka”")
        #expect(p.emptyHint.stringValue == "Try fewer or different words")
        #expect(p.status.stringValue == "0 sessions")
        #expect(p.footerAction.stringValue.isEmpty)
        #expect(p.footerKey.isHidden)
        // Matches exist, just not in this scope.
        p.hits = [Self.hit("claude:a"), Self.hit("claude:b")]
        p.filter.selectedSegment = 1
        p.applyFilter()
        #expect(!p.emptyView.isHidden)
        #expect(p.emptyHint.stringValue == "Try All · 2 matches")
        p.hits = [Self.hit("claude:a")]
        p.applyFilter()
        #expect(p.emptyHint.stringValue == "Try All · 1 match")
        p.filter.selectedSegment = 0
        p.applyFilter()
        #expect(p.emptyView.isHidden)
        #expect(p.status.stringValue == "1 session")

        // Empty query: recents exist, just not in this scope; never "No recent sessions".
        p.field.stringValue = ""
        p.filter.selectedSegment = 1
        p.applyFilter()
        #expect(!p.emptyView.isHidden)
        #expect(p.status.stringValue == "Recent sessions")
        #expect(p.emptyTitle.stringValue == "No recent open sessions")
        #expect(p.emptyHint.stringValue == "Try All · 1 session")
        p.filter.selectedSegment = 2
        p.applyFilter()
        #expect(p.emptyTitle.stringValue == "No recent closed sessions")
        let (q, _, _) = Self.placed(f)
        q.hits.removeLast()   // only Corral sessions left
        q.filter.selectedSegment = 3
        q.applyFilter()
        #expect(!q.emptyView.isHidden)
        #expect(q.emptyTitle.stringValue == "No recent sessions outside Corral")
        #expect(q.emptyHint.stringValue == "Try All · 2 sessions")
        q.hits = []
        q.applyFilter()
        #expect(q.emptyTitle.stringValue == "No recent sessions")
        #expect(q.emptyHint.stringValue == "Sessions you run show up here")
    }

    @Test func liveStateRefreshesUnchangedResults() {
        let f = Fixture()
        defer { f.cleanup() }
        let (p, open, _) = Self.placed(f)
        p.surface.layoutSubtreeIfNeeded()
        let cell = p.table.view(atColumn: 0, row: 0, makeIfNecessary: false) as? SearchHitCell
        #expect(cell?.placeTag.text == "open")

        // Same rows and places: no reload; selection, row views and cells stay, cells reconfigure in place.
        p.table.selectRowIndexes([2], byExtendingSelection: false)
        cell?.titleLabel.stringValue = "stale"
        p.applyFilter()
        #expect(p.table.selectedRow == 2)
        #expect(p.table.view(atColumn: 0, row: 0, makeIfNecessary: false) === cell)
        #expect(cell?.titleLabel.stringValue == "T")
        #expect(p.footerAction.stringValue == "Resume in new session")

        // The open session closed while the results stayed byte-identical: tag, scope and footer follow.
        f.manager.close(open)
        p.table.selectRowIndexes([0], byExtendingSelection: false)
        p.applyFilter()
        #expect(p.shownPlaces == [.closed, .closed, .outside])
        #expect(p.footerAction.stringValue == "Reopen session")
        p.surface.layoutSubtreeIfNeeded()
        #expect((p.table.view(atColumn: 0, row: 0, makeIfNecessary: false) as? SearchHitCell)?.placeTag.text == "closed")
        p.filter.selectedSegment = 1
        p.filterChanged()
        #expect(p.shown.isEmpty)
    }

    @Test func agentTranscriptsResolveTheirCorralSession() {
        let f = Fixture()
        defer { f.cleanup() }
        f.transcripts("t1", "t2", "t3")
        f.manager.newSession(agent: .claude, cwd: f.dir.path, agentSessionId: "t1")
        f.manager.newSession(agent: .claude, cwd: f.dir.path, agentSessionId: "t2")
        let closed = f.selected!
        f.manager.close(closed)
        // A closed and an open Corral session for the same transcript: open wins.
        f.manager.newSession(agent: .claude, cwd: f.dir.path, agentSessionId: "t3")
        f.manager.close(f.selected!)
        f.manager.newSession(agent: .claude, cwd: f.dir.path, agentSessionId: "t3")
        let p = SearchPanelController(manager: f.manager)
        p.hits = [Self.hit("claude:t1", sessionId: "t1"), Self.hit("claude:t2", sessionId: "t2"),
                  Self.hit("claude:t3", sessionId: "t3"), Self.hit("opencode:t1", agent: .opencode, sessionId: "t1"),
                  Self.hit("claude:x", sessionId: "x")]
        p.applyFilter()
        #expect(p.shownPlaces == [.open, .closed, .open, .outside, .outside])
    }

    @Test func freshPresentRefreshesBeforeTheFirstFrame() {
        let f = Fixture()
        defer { f.cleanup() }
        let blank = SearchPanelController(manager: f.manager)
        blank.prepareFreshPresent()   // nothing searched yet: no empty state flash
        #expect(!blank.searched && blank.emptyView.isHidden)
        let (p, open, _) = Self.placed(f)
        p.table.selectRowIndexes([2], byExtendingSelection: false)
        f.manager.close(open)
        p.prepareFreshPresent()
        #expect(p.table.selectedRow == 0)
        #expect(p.shownPlaces.first == .closed)
        #expect(p.footerAction.stringValue == "Reopen session")
        p.hits = []
        p.applyFilter()
        p.prepareFreshPresent()
        #expect(p.table.selectedRow == -1)
    }

    @Test func queryEditorAndSurfaceFollowTheTheme() {
        let f = Fixture()
        defer { f.cleanup() }
        let p = SearchPanelController(manager: f.manager)
        let panel = p.window!
        p.refreshShadow()   // not on screen: no-op
        panel.alphaValue = 0
        panel.ignoresMouseEvents = true
        panel.orderFrontRegardless()
        defer { panel.orderOut(nil) }
        let was = Motion.enabled
        Motion.enabled = false
        defer { Motion.enabled = was }
        #expect(panel.makeFirstResponder(p.field))
        p.styleFieldEditor()
        let editor = panel.fieldEditor(false, for: p.field) as? NSTextView
        let t = Theme.tokens
        #expect(editor?.insertionPointColor == t.accent)
        let bg = editor?.selectedTextAttributes[.backgroundColor] as? NSColor
        #expect(bg.map { abs($0.alphaComponent - (t.isChromeDark ? 0.30 : 0.22)) < 0.001 } == true)
        #expect(editor?.selectedTextAttributes[.foregroundColor] as? NSColor == t.ramp(.elevated).primary)

        // 1 device pixel, whatever the backing scale.
        p.refreshShadow()
        #expect(p.surface.layer?.borderWidth == 1 / panel.backingScaleFactor)
        #expect(p.surface.layer?.borderColor == t.ramp(.elevated).hairlineStrong.cgColor)
        #expect(p.surface.layer?.masksToBounds == false)
        p.surface.viewDidChangeBackingProperties()
        let detached = PanelSurfaceView()
        detached.updateLayer()
        #expect(detached.layer?.borderWidth == 0.5)
    }

    @Test func footerNamesTheActionPerPlace() {
        let f = Fixture()
        defer { f.cleanup() }
        let (p, _, _) = Self.placed(f)
        #expect(p.table.selectedRow == 0)
        #expect(p.footerAction.stringValue == "Focus session")
        #expect(!p.footerKey.isHidden)
        p.table.selectRowIndexes([1], byExtendingSelection: false)
        #expect(p.footerAction.stringValue == "Reopen session")
        p.table.selectRowIndexes([2], byExtendingSelection: false)
        #expect(p.footerAction.stringValue == "Resume in new session")
        p.table.deselectAll(nil)
        #expect(p.footerAction.stringValue.isEmpty)
        #expect(p.footerKey.isHidden)
        #expect(p.footerKey.stringValue == "↩")
        #expect(p.escKey.stringValue == "esc")
        // AppKit's highlight is off; the existing row views and cells still follow the selection.
        p.table.selectRowIndexes([0], byExtendingSelection: false)
        p.surface.layoutSubtreeIfNeeded()
        let rows = (0..<2).map { p.table.rowView(atRow: $0, makeIfNecessary: true) as? SearchRowView }
        let cells = (0..<2).map { p.table.view(atColumn: 0, row: $0, makeIfNecessary: true) as? SearchHitCell }
        #expect(rows[0]?.isSelected == true && cells[0]?.selected == true)
        p.table.selectRowIndexes([1], byExtendingSelection: false)
        #expect(p.table.selectionHighlightStyle == .none)
        #expect(rows[1]?.isSelected == true && rows[0]?.isSelected == false)
        #expect(cells[1]?.selected == true && cells[0]?.selected == false)
        #expect(cells[1]?.returnKey.isHidden == false && cells[0]?.returnKey.isHidden == true)
    }

    @Test func rowHeightsAreComputed() {
        let f = Fixture()
        defer { f.cleanup() }
        // Title + info line, plus one snippet line when there is one.
        #expect(SearchPanelController.rowHeight(snippetLines: 0) == 50)
        #expect(SearchPanelController.rowHeight(snippetLines: 1) == 66)
        #expect(SearchPanelController.rowHeight(snippetLines: 7) == 66)
        let p = SearchPanelController(manager: f.manager)
        let s = Self.snippet("user", "x")
        p.hits = [Self.hit("claude:a"), Self.hit("claude:b", snippets: [s, s]), Self.hit("claude:c", snippets: [s, s, s, s])]
        p.applyFilter()
        #expect(!p.table.usesAutomaticRowHeights)
        #expect(p.table.intercellSpacing == NSSize(width: 0, height: 2))
        #expect(p.table.style == .plain)
        #expect((0..<3).map { p.tableView(p.table, heightOfRow: $0) } == [50, 66, 66])
        #expect(p.tableView(p.table, heightOfRow: 9) == 44)
    }

    @Test func hitCellLayoutAndSelection() {
        let now = Date()
        let s = Self.snippet("assistant", "the \u{1}kafka\u{2} lag")
        let hit = Self.hit("claude:a", cwd: NSHomeDirectory() + "/Documents/Code/corral", title: "Kafka lag",
                           updated: now.addingTimeInterval(-7200), snippets: [s, s, s])
        let cell = SearchHitCell()
        cell.frame = NSRect(x: 0, y: 0, width: 640, height: 82)
        cell.configure(hit, place: .open, now: now)
        #expect(cell.metaLabel.stringValue == "Active 2h ago · Code/corral")
        #expect(cell.metaLabel.toolTip?.hasPrefix("~/Documents/Code/corral\n") == true)
        #expect(cell.placeTag.text == "open")
        #expect(!cell.placeTag.isHidden)
        #expect(cell.snippetCount == 1)  // the best passage; → shows every match
        cell.layoutSubtreeIfNeeded()
        #expect(cell.tile.frame == NSRect(x: 8, y: 8, width: 26, height: 26))
        let title = cell.titleLabel.alignmentRect(forFrame: cell.titleLabel.frame)
        #expect(title.minX == 42 && title.minY == 8)
        #expect(title.width >= ceil(("Kafka lag" as NSString).size(withAttributes: [.font: Fonts.hitTitle]).width))
        #expect(cell.placeTag.frame.minX == title.maxX + 6)
        // Info line under the title, the snippet under that.
        let meta = cell.metaLabel.alignmentRect(forFrame: cell.metaLabel.frame)
        #expect(meta.minX == 42 && meta.minY == 26)
        #expect(cell.snippetView.frame.minY == 42 && cell.snippetView.frame.height == 16)
        #expect(cell.returnKey.isHidden && !cell.metaLabel.isHidden)
        cell.selected = true
        cell.layoutSubtreeIfNeeded()
        #expect(!cell.metaLabel.isHidden && !cell.returnKey.isHidden)
        #expect(cell.tile.emphasized)
        #expect(cell.returnKey.frame.maxX == 628)
        #expect(cell.returnKey.frame.size == cell.returnKey.intrinsicContentSize)
        #expect(cell.returnKey.stringValue == "↩")
        // One overlay step above the selected pill (never the sunken keycap fill, which reads as a hole).
        cell.returnKey.updateLayer()
        cell.returnKey.layout()
        let r = Theme.ramp(.elevated)
        #expect(cell.returnKey.layer?.backgroundColor == r.pressed.cgColor)
        #expect(cell.returnKey.label.textColor == r.secondary)
        #expect(cell.returnKey.layer?.cornerRadius == 4)
        #expect(cell.returnKey.label.frame == cell.returnKey.bounds.insetBy(dx: 5, dy: 2))
        cell.selected = false

        // Closed: ring + "closed"; no snippets, nothing known: an empty info line.
        cell.configure(Self.hit("claude:b", cwd: "", updated: nil), badge: "CLOSED")
        #expect(cell.place == .closed && cell.placeTag.text == "closed")
        #expect(cell.metaLabel.stringValue.isEmpty)
        cell.layoutSubtreeIfNeeded()
        #expect(cell.snippetView.isHidden)
        cell.configure(Self.hit("claude:c"), badge: "OPEN")
        #expect(cell.place == .open)
        cell.configure(Self.hit("claude:d", title: ""), badge: "")
        #expect(cell.place == .outside && cell.placeTag.isHidden && cell.placeTag.preferredWidth == 0)
        #expect(cell.titleLabel.stringValue == "Untitled")

        let tag = PlaceTagView()
        tag.frame = NSRect(x: 0, y: 0, width: 50, height: 14)
        for place in [SearchPlace.open, .closed] {
            tag.place = place
            tag.updateLayer()
            tag.layout()
            #expect(tag.dot.frame.size == CGSize(width: 6, height: 6))
            #expect((tag.dot.borderWidth == 0) == (place == .open))
        }
        let tile = HitTileView()
        tile.updateLayer()
        #expect(tile.layer?.contents != nil)
    }

    @Test func metaTextHelpers() {
        let home = NSHomeDirectory()
        #expect(SearchHitCell.compactPath("") == "")
        #expect(SearchHitCell.compactPath(home) == "~")
        #expect(SearchHitCell.compactPath(home + "/r") == "~/r")
        #expect(SearchHitCell.compactPath(home + "/Documents/Code/corral/") == "Code/corral")
        #expect(SearchHitCell.compactPath("/repo") == "/repo")
        #expect(SearchHitCell.compactPath("/a/b/c") == "b/c")
        #expect(SearchHitCell.compactPath("/private/tmp/x/build-42") == "build-42")
        #expect(SearchHitCell.compactPath("/var/folders/ab/T/corralkit-1") == "corralkit-1")
        #expect(SearchHitCell.abbreviateHome(home + "x/y") == home + "x/y")
        let now = Date()
        let old = now.addingTimeInterval(-10 * 86_400)
        let f = DateFormatter()
        f.setLocalizedDateFormatFromTemplate("MMMd")
        #expect(SearchHitCell.when(old, now: now) == f.string(from: old))
        #expect(SearchHitCell.when(now, now: now) == RelativeTime.short(since: now, now: now))
        var hit = Self.hit("claude:a", cwd: "/tmp/x", updated: old)
        #expect(SearchHitCell.meta(hit, now: now) == "Active on \(f.string(from: old)) · x")
        hit.created = old.addingTimeInterval(-3 * 86_400)
        hit.matchCount = 18
        #expect(SearchHitCell.meta(hit, now: now)
                == "Active on \(f.string(from: old)) · Started \(f.string(from: hit.created!)) · 18 matches · x")
        // Started the same hour it was last active: not worth a second date.
        hit.created = old.addingTimeInterval(-600)
        hit.matchCount = 1
        #expect(SearchHitCell.meta(hit, now: now) == "Active on \(f.string(from: old)) · 1 match · x")
        hit.updated = now.addingTimeInterval(-120)
        hit.created = now.addingTimeInterval(-7200)
        #expect(SearchHitCell.meta(hit, now: now).hasPrefix("Active 2m ago · Started "))
        #expect(SearchHitCell.ago(now, now: now) == "now")
        #expect(SearchHitCell.tooltip(Self.hit("claude:a", cwd: "", updated: nil)).isEmpty)
        #expect(SearchPlace.open.action == "Focus session")
    }

    @Test func scopeChipsControl() {
        let f = Fixture()
        defer { f.cleanup() }
        let p = SearchPanelController(manager: f.manager)
        let chips = p.filter
        #expect(chips.segmentCount == 4)
        #expect(chips.label(forSegment: 3) == "Not in Corral")
        #expect(chips.label(forSegment: 9) == nil)
        #expect(chips.intrinsicContentSize.height == 22)
        #expect(chips.target === p)
        #expect(chips.action == #selector(SearchPanelController.filterChanged))
        p.surface.layoutSubtreeIfNeeded()
        let frame1 = chips.chipFrame(1)
        #expect(frame1.minX == chips.chipFrame(0).maxX + 2)
        #expect(chips.indicator.frame == chips.chipFrame(0))
        chips.selectedSegment = 99
        #expect(chips.selectedSegment == 3)
        #expect(chips.indicator.frame == chips.chipFrame(3))
        #expect(chips.chips[3].accessibilityValue() as? NSNumber == 1)
        chips.selectedSegment = 0

        // Clicks, hover and VoiceOver presses go through choose(), which sends the action.
        let panel = p.window!
        func event(_ type: NSEvent.EventType, at point: NSPoint) -> NSEvent {
            NSEvent.mouseEvent(with: type, location: chips.convert(point, to: nil), modifierFlags: [], timestamp: 0,
                               windowNumber: panel.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
        }
        let mid2 = NSPoint(x: chips.chipFrame(2).midX, y: chips.chipFrame(2).midY)
        chips.mouseMoved(with: event(.mouseMoved, at: mid2))
        #expect(chips.hoveredSegment == 2)
        #expect(!chips.hoverPlate.isHidden)
        chips.mouseDown(with: event(.leftMouseDown, at: mid2))
        #expect(chips.selectedSegment == 2)
        #expect(chips.hoverPlate.isHidden)   // no hover plate under the selected chip
        chips.mouseExited(with: event(.mouseMoved, at: .zero))
        #expect(chips.hoveredSegment == nil)
        chips.mouseEntered(with: event(.mouseMoved, at: NSPoint(x: -50, y: -50)))
        #expect(chips.hoveredSegment == nil)
        p.hits = [Self.hit("claude:a")]
        #expect(chips.chips[3].accessibilityPerformPress())
        #expect(chips.selectedSegment == 3)
        #expect(p.shown.count == 1)   // the action ran applyFilter
        #expect(chips.chips[3].accessibilityRole() == .radioButton)
        #expect(chips.chips[3].accessibilityLabel() == "Not in Corral")
        #expect(chips.chips[3].isAccessibilityElement())
        #expect(chips.accessibilityChildren()?.count == 4)
        #expect(chips.chips[0].hitTest(.zero) == nil)
        #expect(chips.acceptsFirstMouse(for: nil) && !chips.acceptsFirstResponder)
        chips.cycle(1)
        #expect(chips.selectedSegment == 0)
        chips.updateTrackingAreas()
        chips.updateTrackingAreas()
    }

    @Test func clearButtonKnocksOutTheMark() {
        let b = ClearButton()
        let before = b.image
        #expect(before != nil)
        b.setHovered(true)
        #expect(b.hovered && b.image !== before)
        b.mouseExited(with: NSEvent())
        #expect(!b.hovered)
        b.mouseEntered(with: NSEvent())
        #expect(b.hovered)
        b.updateTrackingAreas()
        b.updateTrackingAreas()
        #expect(b.acceptsFirstMouse(for: nil) && b.refusesFirstResponder)
    }

    @Test func rowViewPillStates() {
        let row = SearchRowView()
        row.frame = NSRect(x: 0, y: 0, width: 600, height: 52)
        row.layout()
        #expect(row.fill.frame == CGRect(x: 0, y: 1, width: 600, height: 50))
        #expect(row.bar.frame.width == 2.5 && row.bar.frame.minX == 0 && row.bar.frame.height == 30)
        let r = Theme.ramp(.elevated)
        row.updateLayer()
        #expect(row.fill.backgroundColor?.alpha == 0)
        #expect(row.bar.isHidden)
        row.hovered = true
        row.updateLayer()
        #expect(row.fill.backgroundColor == r.hover.cgColor)
        row.isSelected = true
        row.updateLayer()
        #expect(row.fill.backgroundColor == r.selected.cgColor)
        #expect(!row.bar.isHidden)
        #expect(row.bar.backgroundColor == Theme.tokens.accent.cgColor)
        #expect(row.interiorBackgroundStyle == .normal)
        row.drawSelection(in: row.bounds)
        row.drawBackground(in: row.bounds)
    }

    @Test func tableHoverTracking() {
        let f = Fixture()
        defer { f.cleanup() }
        let p = SearchPanelController(manager: f.manager)
        p.hits = [Self.hit("claude:a"), Self.hit("claude:b")]
        p.applyFilter()
        p.surface.layoutSubtreeIfNeeded()
        let rows = (0..<2).map { p.table.rowView(atRow: $0, makeIfNecessary: true) as? SearchRowView }
        p.table.setHovered(1)
        #expect(p.table.hoveredRow == 1)
        #expect(rows[1]?.hovered == true)
        p.table.setHovered(0)
        #expect(rows[1]?.hovered == false && rows[0]?.hovered == true)
        p.table.setHovered(7)
        #expect(p.table.hoveredRow == -1)
        p.table.refreshHover()
        #expect(p.table.hoveredRow == -1)
        let panel = p.window!
        let inside = p.table.convert(NSPoint(x: 20, y: p.table.rect(ofRow: 1).midY), to: nil)
        let e = NSEvent.mouseEvent(with: .mouseMoved, location: inside, modifierFlags: [], timestamp: 0,
                                   windowNumber: panel.windowNumber, context: nil, eventNumber: 0, clickCount: 0, pressure: 0)!
        p.table.mouseEntered(with: e)
        #expect(p.table.hoveredRow == 1)
        p.table.mouseExited(with: e)
        #expect(p.table.hoveredRow == -1)
        p.table.updateTrackingAreas()
        p.table.updateTrackingAreas()
        p.table.setHovered(1)
        let rv = p.tableView(p.table, rowViewForRow: 1) as? SearchRowView
        #expect(rv?.hovered == true)
        p.table.reloadData()
        #expect(p.table.hoveredRow == -1)
        NotificationCenter.default.post(name: NSView.boundsDidChangeNotification, object: p.table.enclosingScrollView?.contentView)
    }

    @Test func presentAnimationsRespectMotion() {
        let f = Fixture()
        defer { f.cleanup() }
        let p = SearchPanelController(manager: f.manager)
        // Never ordered in: animating the window alpha cannot put anything on screen.
        p.hits = (0..<8).map { Self.hit("claude:\($0)") }
        p.applyFilter()
        p.surface.layoutSubtreeIfNeeded()
        let was = Motion.enabled, wasReduced = Motion.reduced
        defer {
            Motion.enabled = was
            Motion.setReduced(wasReduced)
        }
        Motion.enabled = true
        Motion.setReduced(false)
        p.animateIn(fresh: true)
        #expect(p.surface.layer?.animation(forKey: "present.transform") != nil)
        #expect(p.staggerPending)
        p.staggerRows()
        let first = p.table.rowView(atRow: 0, makeIfNecessary: false)?.layer
        #expect(first?.animation(forKey: "present.rise") != nil)
        #expect(first?.animation(forKey: "present.fade") != nil)
        #expect(p.table.rowView(atRow: 6, makeIfNecessary: false)?.layer?.animation(forKey: "present.rise") == nil)
        let a = SearchPanelController.presentTransform(for: p.surface.layer!) as? CABasicAnimation
        #expect((a?.toValue as? NSValue).map { CATransform3DIsIdentity($0.caTransform3DValue) } == true)
        #expect((a?.fromValue as? NSValue).map { $0.caTransform3DValue.m11 } == 0.98)

        // The first results after a fresh present run the stagger once.
        first?.removeAllAnimations()
        #expect(p.staggerPending)
        p.runStaggerIfPending()
        #expect(!p.staggerPending)
        #expect(first?.animation(forKey: "present.rise") != nil)
        p.runStaggerIfPending()
        // Hover fades in (owned fill layer); selection never animates.
        let row = p.table.rowView(atRow: 1, makeIfNecessary: false) as? SearchRowView
        row?.hovered = true
        row?.updateLayer()
        #expect(row?.fill.animation(forKey: "hover") != nil)
        row?.isSelected = true
        row?.updateLayer()
        #expect(row?.fill.animation(forKey: "hover") == nil)
        row?.prepareForReuse()
        #expect(row?.hovered == false && row?.layer?.animation(forKey: "present.rise") == nil)
        // Scope glide (M27): spring on the owned indicator, model already at the target.
        p.filter.select(2, animated: true)
        #expect(p.filter.indicator.animation(forKey: "glide.position") != nil)
        #expect(p.filter.indicator.frame == p.filter.chipFrame(2))
        p.filter.select(2, animated: true)

        p.surface.layer?.removeAllAnimations()
        Motion.setReduced(true)
        p.animateIn(fresh: true)
        #expect(p.surface.layer?.animation(forKey: "present.transform") == nil)
        Motion.enabled = false
        p.animateIn(fresh: true)
        #expect(p.window?.alphaValue == 1)
    }

    @Test func searchingStatusOnlyWhenSlow() async throws {
        let f = Fixture(start: true)
        defer { f.cleanup() }
        f.manager.index.addScrollback(session: UUID(), title: "a", cwd: "/r", text: "zebra", created: Date(), closed: Date())
        f.manager.index.queue.sync {}
        let p = SearchPanelController(manager: f.manager)
        p.field.stringValue = "zebra"
        p.runQuery()
        await waitUntil(timeout: 10) { p.status.stringValue == "1 session" }
        #expect(p.status.stringValue == "1 session")
        p.table.selectRowIndexes([0], byExtendingSelection: false)

        // A slow search shows "Searching…" until the answer lands; identical results keep rows and selection.
        let gate = DispatchSemaphore(value: 0)
        f.manager.index.readQueue.async { gate.wait() }
        p.runQuery()
        await waitUntil(timeout: 10) { p.status.stringValue == "Searching…" }
        #expect(p.status.stringValue == "Searching…")
        gate.signal()
        await waitUntil(timeout: 10) { p.status.stringValue == "1 session" }
        #expect(p.status.stringValue == "1 session")
        #expect(p.table.selectedRow == 0)

        p.field.stringValue = "zeb"
        p.clearQuery()
        #expect(p.field.stringValue.isEmpty && p.clearButton.isHidden)
        await waitUntil(timeout: 10) { p.status.stringValue == "Recent sessions" }
        #expect(p.status.stringValue == "Recent sessions")
    }

    @Test func positionAndTheme() {
        let size = SearchPanelController.size
        let screen = NSRect(x: 0, y: 0, width: 1440, height: 900)
        let o = SearchPanelController.origin(size: size, parent: NSRect(x: 100, y: 100, width: 1100, height: 700), screen: screen)
        #expect(o == NSPoint(x: 310, y: 228))
        // Kept on screen when the parent hangs off its edge.
        let edge = SearchPanelController.origin(size: size, parent: NSRect(x: 1200, y: 0, width: 600, height: 300), screen: screen)
        #expect(edge.x == 1440 - 680 - 8 && edge.y == 8)
        let free = SearchPanelController.origin(size: size, parent: nil, screen: screen)
        #expect(free.x == 380)
        #expect(SearchPanelController.origin(size: size, parent: nil, screen: nil).x == 380)

        let f = Fixture()
        defer { f.cleanup() }
        let p = SearchPanelController(manager: f.manager)
        let panel = p.window!
        #expect(panel.frame.size == size)
        #expect(panel.styleMask.contains(.borderless) && panel.styleMask.contains(.nonactivatingPanel))
        #expect(!panel.styleMask.contains(.resizable))
        #expect(panel.canBecomeKey && !panel.canBecomeMain)
        #expect(!panel.isOpaque && panel.hasShadow && panel.animationBehavior == .none)
        #expect(panel.contentView === p.surface)
        p.hits = [Self.hit("claude:a")]
        p.applyFilter()
        p.table.selectRowIndexes([0], byExtendingSelection: false)
        Theme.update(background: RGB(hex: 0xFDF6E3).color, foreground: RGB(hex: 0x657B83).color, windowTheme: nil)
        defer { Theme.update(background: nil, foreground: nil, windowTheme: nil) }
        let r = Theme.ramp(.elevated)
        #expect(p.field.textColor == r.primary)
        #expect(p.status.textColor == r.tertiary)
        #expect(panel.appearance?.name == .aqua)
        #expect(p.table.selectedRow == 0)
        p.surface.updateLayer()
        #expect(p.surface.layer?.backgroundColor == Theme.tokens.elevated.cgColor)
        #expect(p.surface.layer?.cornerRadius == 14)
    }

    // MARK: Gallery (CORRAL_SNAPSHOTS only)

    static func render(_ view: NSView, to url: URL) {
        view.layoutSubtreeIfNeeded()
        view.displayIfNeeded()
        guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
        view.cacheDisplay(in: view.bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])?.write(to: url)
    }

    @Test(.enabled(if: snapshotDir != nil)) func gallery() throws {
        let out = URL(fileURLWithPath: Self.snapshotDir!)
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        let was = Motion.enabled
        Motion.enabled = false
        defer {
            Motion.enabled = was
            Theme.update(background: nil, foreground: nil, windowTheme: nil)
        }
        let home = NSHomeDirectory()
        for (name, bg, fg) in [("dark", 0x1E1E2E, 0xCDD6F4), ("light", 0xFDF6E3, 0x657B83)] as [(String, UInt32, UInt32)] {
            let f = Fixture()
            defer { f.cleanup() }
            Theme.update(background: RGB(hex: bg).color, foreground: RGB(hex: fg).color, windowTheme: nil)
            f.manager.newSession(agent: .claude, cwd: f.dir.path)
            let open = f.selected!
            f.manager.newSession(agent: .claude, cwd: f.dir.path)
            let closed = f.selected!
            f.manager.close(closed)
            let p = SearchPanelController(manager: f.manager)
            let panel = p.window!
            panel.alphaValue = 0
            panel.ignoresMouseEvents = true
            panel.orderFrontRegardless()
            defer { panel.orderOut(nil) }
            let now = Date()
            p.hits = [
                SearchHit(key: "corral:\(open.uuidString)", agent: .claude, sessionId: open.uuidString,
                          cwd: home + "/Documents/Code/corral", title: "Library Kafka authentication",
                          updated: now.addingTimeInterval(-7200),
                          snippets: [Self.snippet("user", "why does the \u{1}kafka\u{2} consumer lag grow after the rebalance"),
                                     Self.snippet("command", "rg -n \u{1}kafka\u{2} src/ --glob '*.kt'"),
                                     Self.snippet("assistant", "The \u{1}kafka\u{2} consumer commits offsets only after the batch")]),
                SearchHit(key: "corral:\(closed.uuidString)", agent: .shell, sessionId: closed.uuidString,
                          cwd: "/private/tmp/build-42", title: "gradle build", updated: now.addingTimeInterval(-10 * 86_400),
                          snippets: [Self.snippet("command", "./gradlew test --tests '*Kafka*'  # \u{1}kafka\u{2} integration")]),
                SearchHit(key: "opencode:b", agent: .opencode, sessionId: "b", cwd: home + "/Documents/Code/photo-library",
                          title: "Grafana metric for consumer lag", updated: now.addingTimeInterval(-86_400),
                          snippets: [Self.snippet("assistant", String(repeating: "Long context about dashboards and alert routing ", count: 3)
                                         + "until the \u{1}kafka\u{2} metric shows up"),
                                     Self.snippet("user", "add a panel for \u{1}kafka\u{2} lag per partition")]),
                SearchHit(key: "pi:c", agent: .pi, sessionId: "c", cwd: home, title: "websocket refactor",
                          updated: now.addingTimeInterval(-300), snippets: []),
            ]
            p.field.stringValue = "kafka"
            p.applyFilter()   // no debounced query: the index here is empty and would replace these hits
            p.styleFieldEditor()
            RunLoop.main.run(until: Date().addingTimeInterval(0.2))
            p.table.setHovered(2)
            Self.render(panel.contentView!, to: out.appendingPathComponent("search-gallery-\(name).png"))

            p.filter.selectedSegment = 2
            p.filterChanged()
            RunLoop.main.run(until: Date().addingTimeInterval(0.1))
            Self.render(panel.contentView!, to: out.appendingPathComponent("search-scope-\(name).png"))

            // Empty query: recents, placeholder, a different selected row.
            let recents = p.hits.map { h -> SearchHit in
                var r = h
                r.snippets = []
                return r
            }
            p.filter.selectedSegment = 0
            p.field.stringValue = ""
            p.hits = recents
            p.applyFilter()
            p.table.selectRowIndexes([2], byExtendingSelection: false)
            RunLoop.main.run(until: Date().addingTimeInterval(0.1))
            Self.render(panel.contentView!, to: out.appendingPathComponent("search-recent-\(name).png"))

            p.hits = Array(recents.prefix(2))   // only Corral sessions
            p.filter.selectedSegment = 3
            p.filterChanged()
            RunLoop.main.run(until: Date().addingTimeInterval(0.1))
            Self.render(panel.contentView!, to: out.appendingPathComponent("search-recent-scope-\(name).png"))
            p.filter.selectedSegment = 0

            p.field.stringValue = "zebra stripes"
            p.hits = []
            p.applyFilter()
            RunLoop.main.run(until: Date().addingTimeInterval(0.1))
            Self.render(panel.contentView!, to: out.appendingPathComponent("search-empty-\(name).png"))
        }
    }
}
