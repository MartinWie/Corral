import AppKit
@testable import CorralCore
import Testing
@testable import CorralKit

@MainActor
struct ViewTests {
    @Test func rowViewsAndHelpers() {
        let r = SessionRowView(frame: .zero)
        r.configure(title: "T", subtitle: "S", agent: .opencode, activity: .needsInput, unread: true, detailIsAlert: true)
        #expect(r.agentGlyph.toolTip == "OpenCode")
        #expect(!r.agentGlyph.isHidden)
        #expect(r.subtitle.textColor == Theme.tokens.status.needsInput.text)
        #expect(SessionRowView.agentTag(.pi) == "PI")
        #expect(SessionRowView.agentTag(.shell) == "")
        let fr = FolderRowView(frame: .zero)
        fr.configure(name: "F", needsInput: 0, hasDirectory: true)
        #expect(fr.badge.isHidden)
        #expect(fr.glyph.symbol == "folder.fill")
        let c = CompactRowView(frame: .zero)
        c.configure(title: "x", trailing: "1m", activity: .done, unread: false, agent: .pi, dim: true)
        #expect(c.trailing.stringValue == "1m")
        let now = Date()
        #expect(RelativeTime.short(since: now, now: now) == "now")
        #expect(RelativeTime.short(since: now.addingTimeInterval(-120), now: now) == "2m")
        #expect(RelativeTime.short(since: now.addingTimeInterval(-7200), now: now) == "2h")
        #expect(RelativeTime.short(since: now.addingTimeInterval(-172_800), now: now) == "2d")
        #expect(RelativeTime.abbreviatePath(NSHomeDirectory() + "/x") == "~/x")
        #expect(RelativeTime.abbreviatePath("/tmp") == "/tmp")
    }

    @Test func compactPaths() {
        let home = NSHomeDirectory()
        #expect(RelativeTime.compactPath(home + "/Documents/Code/corral") == "~/Documents/Code/corral")
        #expect(RelativeTime.compactPath("/var/folders/ab/xyz/T/corralkit-1") == "corralkit-1")
        #expect(RelativeTime.compactPath("/private/var/folders/ab/xyz/T/job") == "job")
        #expect(RelativeTime.compactPath("/private/tmp/scratch") == "scratch")
        #expect(RelativeTime.compactPath("/tmp/a/b") == "b")
        #expect(RelativeTime.compactPath("/tmp") == "/tmp")
        #expect(RelativeTime.compactPath("/opt/homebrew/bin") == "/opt/homebrew/bin")
        #expect(RelativeTime.compactPath(home + "/Documents/Code/corral", components: 2) == "Code/corral")
        #expect(RelativeTime.compactPath("/repo", components: 2) == "/repo")
    }

    @Test func sessionContentByState() {
        func model(_ a: Activity, unread: Bool = false, detail: String? = nil) -> SessionRowModel {
            var s = LiveStatus()
            s.activity = a
            s.unread = unread
            s.detail = detail
            return .make(title: "T", status: s, agent: .claude, cwd: NSHomeDirectory() + "/repo")
        }
        #expect(model(.needsInput).subtitle == "Waiting for your input")
        #expect(model(.needsInput, detail: "Allow?").subtitle == "Allow?")
        #expect(model(.working).subtitle == "Working")
        #expect(model(.working, detail: "Bash").subtitle == "Working · Bash")
        #expect(model(.done, unread: true).subtitle == "Done")
        #expect(model(.done).subtitle == "~/repo")
        #expect(model(.error).subtitle == "Error")
        #expect(model(.error, detail: "exit 1").subtitle == "exit 1")
        #expect(model(.exited).subtitle == "Exited")
        #expect(model(.idle).subtitle == "~/repo")
        #expect(model(.needsInput).since != nil)
        #expect(model(.working).since != nil)
        #expect(model(.error).since != nil)
        #expect(model(.done, unread: true).since != nil)
        #expect(model(.done).since == nil)
        #expect(model(.idle).since == nil)
        #expect(model(.exited).since == nil)
        #expect(model(.idle).subtitleIsPath)
        #expect(!model(.working).subtitleIsPath)
        for a in [Activity.idle, .working, .needsInput, .done, .error, .exited] {
            #expect(!SessionRowModel.stateLabel(a, unread: true).isEmpty)
        }

        let r = SessionRowView(frame: NSRect(x: 0, y: 0, width: 240, height: 38))
        let id = UUID()
        let t = Theme.tokens
        r.configure(model(.needsInput, detail: "Allow?"), session: id, animated: false)
        #expect(r.title.font == Fonts.rowTitleStrong)
        #expect(r.subtitle.font == Fonts.rowSubStrong)
        #expect(r.subtitle.textColor == t.status.needsInput.text)
        #expect(r.time.textColor == t.status.needsInput.text)
        #expect(r.time.stringValue == "now")
        #expect(r.accessibilityLabel() == "T, Needs input")
        r.configure(model(.done, unread: true), session: id, animated: true)
        #expect(r.title.font == Fonts.rowTitleMedium)
        #expect(r.time.textColor == t.status.done.text)
        r.configure(model(.error), session: id, animated: true)
        #expect(r.subtitle.textColor == t.status.error.text)
        #expect(r.title.font == Fonts.rowTitle)
        r.configure(model(.exited), session: id, animated: true)
        #expect(r.title.textColor == t.ramp(.chrome).secondary)
        #expect(r.time.stringValue == "")
        r.configure(model(.idle), session: id, animated: true)
        #expect(r.agentGlyph.isHidden, "idle: the icon already shows the agent")
        #expect(r.subtitle.lineBreakMode == .byTruncatingHead)
        r.configure(model(.working), session: id, animated: true)
        #expect(!r.agentGlyph.isHidden)
        #expect(r.time.textColor == t.ramp(.chrome).tertiary)
        r.refreshTime(now: Date().addingTimeInterval(3 * 3600))
        #expect(r.time.stringValue == "3h")

        // Hover and hint accessories, then reuse resets them.
        r.setHovered(true, animated: true)
        #expect(r.closeButton.alphaValue == 1 && r.time.alphaValue == 0)
        r.setHint("⌘3", animated: true)
        #expect(r.hint.stringValue == "⌘3" && r.hint.alphaValue == 1 && r.closeButton.alphaValue == 0)
        r.rowStateChanged(selected: true, keyWindow: true)
        #expect(r.icon.haloSuppressed)
        r.rowStateChanged(selected: true, keyWindow: false)
        #expect(!r.icon.haloSuppressed)
        r.setLoopsPaused(true)
        #expect(r.loopsPaused)
        r.prepareForReuse()
        #expect(r.hintText == nil && !r.hovered && r.hint.isHidden)
        #expect(r.time.alphaValue == 1)
    }

    @Test func folderRowCollapsedSummaryAndBadge() {
        var m = FolderRowModel(name: "Infra", hasDirectory: false, needsInput: 2, working: 2, doneUnread: 1, errors: 1,
                               sessions: 6, expanded: false)
        #expect(m.summary == "2 waiting · 1 error · 2 working · 1 done · 6 sessions")
        let f = FolderRowView(frame: NSRect(x: 0, y: 0, width: 240, height: 28))
        f.configure(m, animated: false)
        #expect(f.badge.stringValue == "2")
        #expect(!f.badge.isHidden)
        #expect(f.pips.colors.count == 3)
        #expect(!f.pips.isHidden)
        #expect(f.pips.intrinsicContentSize.width == CGFloat(23))
        #expect(f.countLabel.stringValue == "6")
        #expect(f.toolTip == m.summary)
        #expect(f.pulsing)
        #expect(f.glyph.symbol == "folder")
        #expect(!f.disclosure.chevron.expanded)
        #expect(f.accessibilityLabel() == "Infra, 2 waiting")
        f.layoutSubtreeIfNeeded()
        f.pips.layout()

        // Paused loops stop the ping; Reduce Motion swaps it for the static halo.
        let wasReduced = Motion.reduced
        defer { Motion.setReduced(wasReduced) }
        f.setLoopsPaused(true)
        #expect(!f.pulsing)
        #expect(f.badge.halo.animation(forKey: "sidebar.l2") == nil)
        f.setLoopsPaused(false)
        #expect(f.pulsing)
        Motion.setReduced(true)
        f.configure(m, animated: false)
        #expect(f.badge.halo.animation(forKey: "sidebar.l2static") != nil)
        Motion.setReduced(false)
        f.configure(m, animated: false)
        #expect(f.badge.halo.animation(forKey: "sidebar.l2") != nil || !Motion.full)

        // Expanded: no pips, no count, no pulse; the badge stays while anything waits.
        f.setExpanded(true, animated: false)
        #expect(f.pips.isHidden && f.countLabel.isHidden && !f.pulsing)
        #expect(f.disclosure.chevron.expanded)
        #expect(f.toolTip == nil)
        #expect(!f.badge.isHidden)
        m.needsInput = 3
        m.expanded = true
        f.configure(m, animated: true)
        #expect(f.badge.stringValue == "3")
        m.needsInput = 0
        f.configure(m, animated: true)
        #expect(f.badge.isHidden)
        f.setHovered(true, animated: true)
        #expect(f.title.textColor == Theme.ramp(.chrome).primary)
        f.setHovered(false, animated: true)
        f.rowStateChanged(selected: true, keyWindow: true)
        #expect(f.title.textColor == Theme.ramp(.chrome).primary)
        f.prepareForReuse()
        #expect(f.badge.isHidden && f.model == nil)
        f.setExpanded(false, animated: false)
        #expect(FolderRowModel(name: "x", hasDirectory: false, sessions: 1).summary == "1 session")
    }

    @Test func headerAndCompactRows() {
        let h = SectionHeaderView(frame: NSRect(x: 0, y: 0, width: 240, height: 30))
        h.configure(title: "Closed", count: 3, noun: "session", expanded: true, animated: false)
        #expect(h.title.stringValue == "CLOSED")
        #expect(h.countLabel.stringValue == "3")
        #expect(h.accessibilityLabel() == "Closed, 3 sessions")
        #expect(h.chevron.expanded)
        h.setHovered(true, animated: true)
        #expect(h.chevron.alphaValue == 1)
        h.prepareForReuse()
        #expect(h.chevron.alphaValue == 0 && !h.hovered)

        let t = Theme.tokens
        let c = CompactRowView(frame: NSRect(x: 0, y: 0, width: 240, height: 26))
        let bg = UUID()
        c.configure(CompactRowModel(title: "Job", trailing: "blocked", activity: .needsInput, unread: true, agent: .claude,
                                    style: .background), session: bg, animated: false)
        #expect(c.trailing.stringValue == "BLOCKED")
        #expect(c.trailing.textColor == t.status.needsInput.text)
        #expect(c.title.font == Fonts.compactStrong)
        c.configure(CompactRowModel(title: "Job", trailing: "running", activity: .working, unread: false, agent: .claude,
                                    style: .background), session: bg, animated: true)
        #expect(c.trailing.textColor == t.status.working.text)
        c.configure(CompactRowModel(title: "Job", trailing: "done", activity: .done, unread: false, agent: .claude,
                                    style: .background), session: bg, animated: true)
        #expect(c.trailing.textColor == t.status.done.text)
        c.configure(CompactRowModel(title: "Job", trailing: "idle", activity: .idle, unread: false, agent: .claude,
                                    style: .background), session: bg, animated: true)
        #expect(c.trailing.textColor == t.ramp(.chrome).tertiary)
        // Background rows have no hover accessory.
        c.setHovered(true, animated: true)
        #expect(c.reopenButton.alphaValue == 0)
        c.setHovered(false, animated: true)

        let closedAt = Date().addingTimeInterval(-7200)
        c.configure(CompactRowModel(title: "Old", trailing: "2h", activity: .idle, unread: false, agent: .shell, style: .closed,
                                    closedAt: closedAt), session: UUID(), animated: false)
        #expect(c.title.textColor == t.ramp(.chrome).secondary)
        #expect(c.trailing.textColor == t.ramp(.chrome).quaternary)
        c.refreshTime(now: closedAt.addingTimeInterval(3 * 86400))
        #expect(c.trailing.stringValue == "3d")
        c.setHovered(true, animated: true)
        #expect(c.reopenButton.alphaValue == 1 && c.trailing.alphaValue == 0)
        c.rowStateChanged(selected: true, keyWindow: true)
        #expect(c.icon.haloSuppressed)
        c.setLoopsPaused(true)
        #expect(c.loopsPaused)
        c.prepareForReuse()
        #expect(!c.hovered && c.reopenButton.alphaValue == 0)
    }

    @Test func rowViewFillPrecedence() {
        typealias R = SidebarRowView
        func state(kind: R.Kind = .session, tone: R.Tone = .plain, selected: Bool = false, focused: Bool = false,
                   key: Bool = true, hovered: Bool = false, drop: Bool = false) -> R.FillState {
            R.fillState(kind: kind, tone: tone, selected: selected, focused: focused, windowKey: key, hovered: hovered,
                        dropTarget: drop)
        }
        #expect(state(kind: .header, tone: .attention, selected: true, hovered: true, drop: true) == .header)
        #expect(state(tone: .attention, selected: true, drop: true) == .dropTarget)
        #expect(state(tone: .attention, selected: true, focused: true) == .attentionSelected)
        #expect(state(tone: .attention, hovered: true) == .attention)
        #expect(state(selected: true, focused: true, hovered: true) == .selectedFocused)
        #expect(state(selected: true) == .selectedKey)
        #expect(state(selected: true, key: false) == .selectedInactive)
        #expect(state(hovered: true) == .hovered)
        #expect(state() == .none)

        let t = Theme.tokens
        #expect(R.look(.none) == R.Look())
        #expect(R.look(.header) == R.Look())
        #expect(R.look(.dropTarget).border != nil)
        #expect(R.look(.attention) == R.Look(fill: t.status.wash, border: t.status.washBorder, gutter: t.status.needsInput.fill))
        #expect(R.look(.attentionSelected).fill == t.status.washSelected)
        #expect(R.look(.selectedFocused).gutter == t.accent)
        #expect(R.look(.selectedKey) == R.Look(fill: t.ramp(.chrome).selected))
        #expect(R.look(.selectedInactive).fill != nil)
        #expect(R.look(.hovered).fill == t.ramp(.chrome).hover)

        // The row view resolves its own state; system selection drawing is off.
        let rv = R(frame: NSRect(x: 0, y: 0, width: 260, height: 38))
        #expect(rv.interiorBackgroundStyle == .normal)
        rv.drawSelection(in: rv.bounds)
        rv.drawBackground(in: rv.bounds)
        rv.drawSeparator(in: rv.bounds)
        rv.drawDraggingDestinationFeedback(in: rv.bounds)
        rv.tone = .attention
        rv.updateLayer()
        #expect(rv.state == .attention)
        #expect(rv.fill.backgroundColor == t.status.wash.cgColor)
        rv.tone = .plain
        rv.hovered = true
        rv.updateLayer()
        #expect(rv.state == .hovered)
        rv.isTargetForDropOperation = true
        #expect(rv.dropTarget)
        rv.updateLayer()
        #expect(rv.state == .dropTarget)
        rv.isTargetForDropOperation = false
        rv.isSelected = true
        rv.isEmphasized = true
        rv.updateLayer()
        #expect(rv.state == .selectedInactive)
        rv.kind = .header
        rv.updateLayer()
        rv.layout()
        #expect(!rv.hairline.isHidden)
        #expect(rv.fill.frame == rv.bounds.insetBy(dx: 6, dy: 1))
        #expect(rv.gutter.frame.width == 3 && rv.gutter.frame.height == 22)
        rv.flashArrival()
        rv.refreshInstantly()
        rv.prepareForReuse()
        #expect(!rv.hovered)
        #expect(rv.cellView == nil)
    }

    @Test func outlineGeometryAndHoverBookkeeping() {
        let o = SidebarOutlineView()
        o.applyStyle()
        #expect(o.style == .plain)
        #expect(o.selectionHighlightStyle == .none, "the row view draws selection itself")
        #expect(o.intercellSpacing == .zero)
        #expect(o.indentationPerLevel == 14)
        #expect(o.draggingDestinationFeedbackStyle == .gap)
        #expect(o.frameOfOutlineCell(atRow: 0) == .zero)
        #expect(SidebarOutlineView.cellX(level: 0) == 14)
        #expect(SidebarOutlineView.cellX(level: 2) == 42)
        o.setHoveredRow(5)
        #expect(o.hoveredRow == -1, "rows that don't exist are never hovered")
        o.reloadData()
        #expect(o.reloadCount >= 1)
        o.refreshHoverFromMouse()
        o.refreshRowStates()
        _ = o.becomeFirstResponder()
        _ = o.resignFirstResponder()
    }

    @Test func chromeComponents() {
        let bar = SidebarStatusBar(frame: NSRect(x: 0, y: 0, width: 260, height: 32))
        bar.update(.init(needsInput: 2, working: 0, doneUnread: 0, error: 1, total: 9), animated: false)
        #expect(bar.buttons[.needsInput]?.isHidden == false)
        #expect(bar.buttons[.working]?.isHidden == true)
        #expect(bar.buttons[.error]?.countLabel.stringValue == "1")
        #expect(bar.totalLabel.isHidden)
        bar.update(.init(needsInput: 3, working: 1, doneUnread: 0, error: 0, total: 9), animated: true)
        #expect(bar.buttons[.needsInput]?.count == 3)
        bar.update(.init(total: 1), animated: true)
        #expect(!bar.totalLabel.isHidden)
        #expect(bar.totalLabel.stringValue == "1 session")
        var hits: [SidebarStatusBar.Segment] = []
        bar.onSegment = { hits.append($0) }
        bar.segmentClicked(bar.buttons[.done]!)
        #expect(hits == [.done])
        for seg in SidebarStatusBar.Segment.allCases {
            #expect(SidebarStatusBar.glyphImage(seg, color: SidebarStatusBar.color(for: seg), scale: 2) != nil)
            #expect(!SidebarStatusBar.tooltip(seg).isEmpty)
            let b = bar.buttons[seg]!
            b.setCount(2)
            #expect(b.intrinsicContentSize.height == 20)
            b.applyTheme()
            b.updateLayer()
        }
        bar.applyTheme()
        bar.layout()
        bar.updateLayer()

        let chip = AttentionEdgeChip(direction: .down)
        var clicks = 0
        chip.onClick = { clicks += 1 }
        #expect(!chip.isShown)
        chip.update(count: 2, animated: true)
        #expect(chip.isShown)
        #expect(chip.label.stringValue == "↓ 2 waiting")
        #expect(AttentionEdgeChip.text(1, .up) == "↑ 1 waiting")
        chip.update(count: 3, animated: true)
        #expect(chip.label.stringValue == "↓ 3 waiting")
        #expect(chip.accessibilityPerformPress())
        #expect(clicks == 1)
        #expect(chip.acceptsFirstMouse(for: nil))
        chip.frame = NSRect(x: 0, y: 0, width: 90, height: 20)
        chip.layout()
        chip.updateLayer()
        chip.update(count: 0, animated: true)
        #expect(!chip.isShown)
        #expect(chip.isHidden)

        let card = IntegrationsCard(frame: NSRect(x: 0, y: 0, width: 240, height: 70))
        card.update(missing: ["Claude", "PI"])
        #expect(card.label.stringValue == "Exact agent status needs hooks for Claude, PI.")
        #expect(card.missing == ["Claude", "PI"])
        card.updateLayer()
        card.layoutSubtreeIfNeeded()
        card.applyTheme()
        card.button.refresh()
        #expect(card.button.attributedTitle.string == "Install Integrations…")
    }

    @Test func animatedBranches() {
        SidebarFX.forceAnimations = true
        defer { SidebarFX.forceAnimations = false }
        let f = FolderRowView(frame: NSRect(x: 0, y: 0, width: 240, height: 28))
        var m = FolderRowModel(name: "F", hasDirectory: false, sessions: 3)
        for n in [2, 3, 1] {
            m.needsInput = n
            f.configure(m, animated: true)
            #expect(f.badge.stringValue == "\(n)")
        }
        m.needsInput = 0
        f.configure(m, animated: true)
        #expect(f.badge.layer?.animation(forKey: "sidebar.badge.out") != nil)
        m.needsInput = 4
        f.configure(m, animated: true)
        #expect(f.badge.layer?.animation(forKey: "sidebar.badge.out") == nil, "a new count cancels the exit")
        f.setExpanded(false, animated: true)
        #expect(!f.disclosure.chevron.expanded)

        let bar = SidebarStatusBar(frame: NSRect(x: 0, y: 0, width: 260, height: 32))
        bar.update(.init(needsInput: 1, working: 1, total: 2), animated: true)
        bar.update(.init(needsInput: 2, working: 3, total: 5), animated: true)
        bar.update(.init(needsInput: 1, working: 3, total: 5), animated: true)
        #expect(bar.buttons[.needsInput]?.count == 1)

        let chip = AttentionEdgeChip(direction: .up)
        chip.update(count: 1, animated: true)
        chip.update(count: 2, animated: true)
        chip.update(count: 0, animated: true)
        #expect(chip.hiding, "fades out before hiding")
        chip.update(count: 1, animated: true)
        #expect(chip.isShown)

        let r = SessionRowView(frame: NSRect(x: 0, y: 0, width: 240, height: 38))
        r.configure(SessionRowModel(title: "T", subtitle: "S", agent: .claude, activity: .working, unread: false, since: Date()),
                    session: UUID(), animated: true)
        r.setHovered(true, animated: true)
        #expect(r.closeButton.layer?.animation(forKey: "sidebar.fade") != nil)
        r.setHint("⌘1", animated: true)
        let h = SectionHeaderView(frame: NSRect(x: 0, y: 0, width: 240, height: 30))
        h.configure(title: "Closed", count: 1, noun: "session", expanded: false, animated: true)
        h.configure(title: "Closed", count: 1, noun: "session", expanded: true, animated: true)
        h.setHovered(true, animated: true)
        let c = CompactRowView(frame: NSRect(x: 0, y: 0, width: 240, height: 26))
        c.configure(CompactRowModel(title: "x", trailing: "", activity: .idle, unread: false, agent: .shell, style: .closed),
                    session: UUID(), animated: true)
        c.setHovered(true, animated: true)
        #expect(c.reopenButton.layer?.animation(forKey: "sidebar.fade") != nil)
        #expect(SidebarFX.canAnimate(c))

        let seg = bar.buttons[.working]!
        #expect(seg.hitTest(NSPoint(x: seg.frame.midX, y: seg.frame.midY)) === seg)
        seg.updateTrackingAreas()
        let ev = NSEvent.enterExitEvent(with: .mouseEntered, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0,
                                        context: nil, eventNumber: 0, trackingNumber: 0, userData: nil)!
        seg.mouseEntered(with: ev)
        seg.mouseExited(with: ev)
        let card = IntegrationsCard(frame: NSRect(x: 0, y: 0, width: 240, height: 70))
        card.button.updateTrackingAreas()
        card.button.mouseEntered(with: ev)
        #expect(card.button.attributedTitle.attribute(.underlineStyle, at: 0, effectiveRange: nil) != nil)
        card.button.mouseExited(with: ev)
        var clicked = 0
        chip.onClick = { clicked += 1 }
        func mouse(_ type: NSEvent.EventType, _ p: NSPoint = NSPoint(x: 5, y: 5)) -> NSEvent {
            NSEvent.mouseEvent(with: type, location: p, modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil,
                               eventNumber: 0, clickCount: 1, pressure: 1)!
        }
        // Button semantics: fires on release inside, never on press; dragging out cancels.
        chip.mouseDown(with: mouse(.leftMouseDown))
        #expect(chip.pressed && clicked == 0)
        chip.mouseUp(with: mouse(.leftMouseUp))
        #expect(clicked == 1 && !chip.pressed)
        chip.mouseDown(with: mouse(.leftMouseDown))
        chip.mouseDragged(with: mouse(.leftMouseDragged, NSPoint(x: 500, y: 500)))
        #expect(!chip.pressed)
        chip.mouseUp(with: mouse(.leftMouseUp, NSPoint(x: 500, y: 500)))
        #expect(clicked == 1)
        #expect(chip.accessibilityPerformPress())
        #expect(clicked == 2)
    }

    @Test func edgeChipFeedbackAndScrollPassThrough() {
        let t = Theme.tokens
        let rest = AttentionEdgeChip.plateColor(t, hovered: false, pressed: false)
        let hover = AttentionEdgeChip.plateColor(t, hovered: true, pressed: false)
        let press = AttentionEdgeChip.plateColor(t, hovered: true, pressed: true)
        #expect(rest == t.status.needsInput.fill)
        #expect(ColorMath.lightness(RGB(hover)) > ColorMath.lightness(RGB(rest)))
        #expect(RGB(press) != RGB(rest) && RGB(press) != RGB(hover))

        let chip = AttentionEdgeChip(direction: .down)
        chip.frame = NSRect(x: 0, y: 0, width: 90, height: 20)
        chip.update(count: 1, animated: false)
        chip.layout()
        chip.updateLayer()
        #expect(chip.plateFill == rest.cgColor)
        let ev = NSEvent.enterExitEvent(with: .mouseEntered, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0,
                                        context: nil, eventNumber: 0, trackingNumber: 0, userData: nil)!
        chip.updateTrackingAreas()
        chip.mouseEntered(with: ev)
        chip.updateLayer()
        #expect(chip.hovered)
        #expect(chip.plateFill == hover.cgColor)
        chip.mouseDown(with: NSEvent.mouseEvent(with: .leftMouseDown, location: NSPoint(x: 5, y: 5), modifierFlags: [],
                                                timestamp: 0, windowNumber: 0, context: nil, eventNumber: 0, clickCount: 1,
                                                pressure: 1)!)
        chip.updateLayer()
        #expect(chip.plateFill == press.cgColor)
        chip.mouseExited(with: ev)
        chip.update(count: 0, animated: false)
        #expect(!chip.hovered && !chip.pressed, "hiding drops hover and press")

        final class ScrollSpy: NSScrollView {
            var wheels = 0
            override func scrollWheel(with event: NSEvent) { wheels += 1 }
        }
        let spy = ScrollSpy(frame: NSRect(x: 0, y: 0, width: 100, height: 100))
        let wheel = NSEvent(cgEvent: CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 1, wheel1: -4,
                                             wheel2: 0, wheel3: 0)!)!
        chip.scrollWheel(with: wheel)
        #expect(spy.wheels == 0)
        chip.scrollTarget = spy
        chip.scrollWheel(with: wheel)
        #expect(spy.wheels == 1)
    }

    @Test func agentGlyphKeepsItsAspect() {
        let r = SessionRowView(frame: NSRect(x: 0, y: 0, width: 240, height: 38))
        func show(_ agent: AgentKind) {
            r.configure(SessionRowModel(title: "T", subtitle: "S", agent: agent, activity: .working, unread: false, since: nil),
                        session: UUID(), animated: false)
            r.layoutSubtreeIfNeeded()
        }
        show(.opencode)
        let code = SessionRowView.agentSymbol(.opencode)
        #expect(r.agentGlyph.symbol == code)
        #expect(r.agentGlyph.frame.height == 11)
        #expect(r.agentGlyph.frame.width == SessionRowView.glyphWidth(code))
        #expect(r.agentGlyph.frame.width > 11, "wide symbols widen the box instead of shrinking")
        #expect(r.agentGlyph.frame.maxX == r.bounds.maxX)
        show(.claude)
        #expect(r.agentGlyph.symbol == SessionRowView.agentSymbol(.claude))
        #expect(r.agentGlyph.frame.width == SessionRowView.glyphWidth(SessionRowView.agentSymbol(.claude)))
        #expect(r.agentGlyph.frame.maxX == r.bounds.maxX)
        show(.pi)
        #expect(r.agentGlyph.symbol == GlyphCache.agentSymbol(.pi))
        for a in AgentKind.allCases { #expect(SessionRowView.agentSymbol(a) == GlyphCache.agentSymbol(a)) }
    }

    @Test func statuslineGlyphsCutTheirMarkInBarColor() {
        defer { Theme.update(background: nil, foreground: nil, windowTheme: nil) }
        for seg in SidebarStatusBar.Segment.allCases {
            let color = SidebarStatusBar.color(for: seg)
            let a = SidebarStatusBar.glyphImage(seg, color: color, scale: 2)
            #expect(a != nil)
            #expect(SidebarStatusBar.glyphImage(seg, color: color, scale: 2) === a, "cached")
        }
        // The inner mark follows the bar color, so a theme change re-renders.
        let before = SidebarStatusBar.glyphImage(.done, color: SidebarStatusBar.color(for: .done), scale: 2)
        Theme.update(background: RGB(hex: 0xFDF6E3).color, foreground: RGB(hex: 0x657B83).color, windowTheme: nil)
        let after = SidebarStatusBar.glyphImage(.done, color: SidebarStatusBar.color(for: .done), scale: 2)
        #expect(after != nil && after !== before)
    }

    @Test func motionHelpers() {
        let v = NSView(frame: NSRect(x: 0, y: 0, width: 20, height: 20))
        v.wantsLayer = true
        SidebarFX.fade(v, to: 0.5, animated: true)
        #expect(v.alphaValue == 0.5)
        #expect(v.layer?.animation(forKey: "sidebar.fade") != nil)
        SidebarFX.fade(v, to: 1, animated: false)
        #expect(v.layer?.animation(forKey: "sidebar.fade") == nil)
        SidebarFX.fade(v, to: 1, animated: true)
        let l = v.layer!
        SidebarFX.bump(l, peak: 1.2)
        #expect(l.animation(forKey: "sidebar.bump") != nil)
        SidebarFX.push(l, up: true)
        let wasReduced = Motion.reduced
        Motion.setReduced(true)
        SidebarFX.push(l, up: false)
        Motion.setReduced(wasReduced)
        #expect(!(l.animationKeys() ?? []).isEmpty)
        let owned = SidebarFX.ownedLayer()
        SidebarFX.color(owned, "backgroundColor", to: NSColor.red.cgColor, duration: 0.1)
        #expect(owned.backgroundColor == NSColor.red.cgColor)
        SidebarFX.color(owned, "backgroundColor", to: nil, duration: 0.1)
        #expect(owned.backgroundColor?.alpha == 0)
        SidebarFX.color(owned, "borderColor", to: NSColor.blue.cgColor, duration: nil)
        #expect(owned.borderColor == NSColor.blue.cgColor)
        SidebarFX.color(owned, "borderColor", to: NSColor.blue.cgColor, duration: nil)
        let chevron = ChevronView(frame: NSRect(x: 0, y: 0, width: 12, height: 12))
        chevron.setExpanded(true, animated: true)
        #expect(chevron.expanded)
        chevron.layout()
        chevron.updateLayer()
        #expect(chevron.chevron.contents != nil)
        #expect(FolderRowView.ping().repeatCount == .infinity)
        #expect(FolderRowView.staticHalo().isRemovedOnCompletion == false)
    }
}
