import AppKit
@testable import CorralCore
import Testing
@testable import CorralKit

/// Opt-in gallery gate (nonisolated: test traits are evaluated off the main actor).
private let cardSnapshotDir = ProcessInfo.processInfo.environment["CORRAL_SNAPSHOTS"]

@MainActor
struct ContainerTests {
    /// Container laid out at a fixed size, without a window.
    func makeContainer(_ f: Fixture, size: NSSize = NSSize(width: 800, height: 500)) -> TerminalContainerViewController {
        let c = TerminalContainerViewController(manager: f.manager)
        c.view.frame = NSRect(origin: .zero, size: size)
        c.view.layoutSubtreeIfNeeded()
        return c
    }

    /// A main menu with the real key equivalents, so `KeyHint` resolves.
    static func withMenu(_ body: @MainActor () throws -> Void) rethrows {
        let menu = NSMenu()
        let top = NSMenuItem(title: "Session", action: nil, keyEquivalent: "")
        let sub = NSMenu(title: "Session")
        func add(_ sel: Selector, _ key: String, _ mods: NSEvent.ModifierFlags = .command) {
            let i = NSMenuItem(title: "\(sel)", action: sel, keyEquivalent: key)
            i.keyEquivalentModifierMask = mods
            sub.addItem(i)
        }
        add(#selector(MainWindowController.newShell(_:)), "t")
        add(#selector(MainWindowController.newClaude(_:)), "c", [.command, .control])
        add(#selector(MainWindowController.newOpenCode(_:)), "o", [.command, .control])
        add(#selector(MainWindowController.newPi(_:)), "p", [.command, .control])
        add(#selector(MainWindowController.searchSessions(_:)), "k")
        add(#selector(MainWindowController.nextAttention(_:)), "i")
        top.submenu = sub
        menu.addItem(top)
        let saved = NSApplication.shared.mainMenu
        NSApplication.shared.mainMenu = menu
        defer { NSApplication.shared.mainMenu = saved }
        try body()
    }

    @Test func showsSelectedTerminalAndPlaceholders() {
        let f = Fixture()
        defer { f.cleanup() }
        let c = TerminalContainerViewController(manager: f.manager)
        _ = c.view
        c.showSelected(focus: true)
        #expect(!c.placeholder.isHidden)
        #expect(c.placeholder.page == .empty)
        f.manager.newSession(agent: .shell, cwd: f.dir.path)
        let a = f.selected!
        f.manager.newSession(agent: .claude, cwd: f.dir.path)
        let b = f.selected!
        c.showSelected(focus: true)
        #expect(f.terminal(b)?.view.isHidden == false)
        #expect(f.terminal(a)?.view.isHidden == true)
        #expect(c.shownSession == b)
        #expect(c.placeholder.isHidden)
        f.manager.select(a)
        c.showSelected(focus: false)
        #expect(f.terminal(a)?.visibility.last == true)
        #expect(f.terminal(b)?.visibility.last == false)
        c.focusTerminal()

        // The window covered (screen locked or asleep): the shown terminal stops drawing, and draws
        // again when the window shows; a session switched to meanwhile waits for the window too.
        c.setWindowVisible(false)
        #expect(f.terminal(a)?.visibility.last == false)
        let bSeen = f.terminal(b)?.visibility.count
        f.manager.select(b)
        c.showSelected(focus: false)
        #expect(f.terminal(b)?.visibility.last == false)
        c.setWindowVisible(true)
        #expect(f.terminal(b)?.visibility.last == true && f.terminal(b)?.visibility.count == (bSeen ?? 0) + 2)
        // Waking displays redraw the shown terminal from scratch; never while the window is covered.
        let before = f.terminal(b)?.visibility.count ?? 0
        c.redrawShownTerminals()
        #expect(f.terminal(b)?.visibility.suffix(2) == [false, true] && f.terminal(b)?.visibility.count == before + 2)
        c.setWindowVisible(false)
        c.redrawShownTerminals()
        #expect(f.terminal(b)?.visibility.last == false)
        c.setWindowVisible(true)
        f.manager.select(a)
        c.showSelected(focus: false)

        f.manager.close(b)
        let record = f.manager.workspace.sessions[b]!
        c.showClosed(record)
        #expect(c.shownSession == nil)
        #expect(f.terminal(a)?.view.isHidden == true)
        #expect(c.placeholder.button.title == "Reopen")
        #expect(c.placeholder.page == .closed(b))
        c.placeholder.tapped()
        #expect(f.manager.live[b] != nil)
        c.showBackground(BackgroundAgent(id: "j", sessionId: "s", name: "Job", cwd: "/", state: "blocked", needs: "x", detail: "y"))
        #expect(c.placeholder.button.title == "Attach")
        #expect(c.placeholder.page == .background("j"))
        c.applyBackground()
    }

    @Test func terminalsSitInsetInsideTheCardAndHiddenOnesDoNotResize() {
        let f = Fixture()
        defer { f.cleanup() }
        let c = makeContainer(f)
        #expect(c.card.frame == NSRect(x: 0, y: 6, width: 794, height: 494))
        #expect(c.stack.frame == c.card.bounds.insetBy(dx: 4, dy: 4))
        f.manager.newSession(agent: .shell, cwd: f.dir.path)
        let a = f.selected!
        f.manager.newSession(agent: .shell, cwd: f.dir.path)
        let b = f.selected!
        c.showSelected(focus: false)
        let va = f.terminal(a)!.view, vb = f.terminal(b)!.view
        #expect(vb.frame == c.stack.bounds)
        #expect(vb.autoresizingMask == [.width, .height])
        #expect(va.autoresizingMask == [])
        // Never masked, clipped or rounded.
        #expect(vb.layer?.mask == nil)
        #expect(vb.layer?.cornerRadius ?? 0 == 0)
        #expect(c.card.layer?.masksToBounds == false)

        // Resize: only the visible terminal follows; the hidden one keeps its old frame.
        let hiddenFrame = va.frame
        c.view.frame = NSRect(x: 0, y: 0, width: 1000, height: 600)
        c.view.layoutSubtreeIfNeeded()
        #expect(vb.frame.size == c.stack.bounds.size)
        #expect(va.frame == hiddenFrame)

        // Shown again: one frame refresh, then autoresizing.
        f.manager.select(a)
        c.showSelected(focus: false)
        #expect(va.frame == c.stack.bounds)
        #expect(va.autoresizingMask == [.width, .height])
        #expect(vb.autoresizingMask == [])

        // A placeholder page parks every terminal.
        c.showBackground(BackgroundAgent(id: "j", sessionId: "s", name: "Job", cwd: "/", state: "working"))
        #expect(va.isHidden && va.autoresizingMask == [])
    }

    @Test func cardMarginsFollowSidebarAndFullScreen() {
        let f = Fixture()
        defer { f.cleanup() }
        let c = makeContainer(f)
        #expect(c.cardMargins == (0, 6, 6))
        c.sidebarCollapsed = true
        c.view.layoutSubtreeIfNeeded()
        #expect(c.cardMargins == (6, 6, 6))
        #expect(c.card.frame.minX == 6)
        c.setFullScreen(true)
        c.view.layoutSubtreeIfNeeded()
        #expect(c.isFullScreen)
        #expect(c.card.frame == c.view.bounds)
        c.card.updateLayer()
        #expect(c.card.layer?.cornerRadius == 0)
        #expect(c.card.layer?.borderWidth == 0)
        #expect(c.card.layer?.shadowOpacity == 0)
        #expect(c.card.layer?.shadowPath == nil)
        c.setFullScreen(false)
        c.view.layoutSubtreeIfNeeded()
        c.card.updateLayer()
        #expect(c.card.frame.minX == 6)
        #expect(c.card.layer?.cornerRadius == 10)
        #expect(c.card.layer?.borderWidth == 1)
        #expect((c.card.layer?.shadowOpacity ?? 0) > 0)
        #expect(c.card.layer?.shadowPath != nil)
        #expect(c.card.layer?.masksToBounds == false)
        #expect(!c.card.clipsToBounds && !c.stack.clipsToBounds)
        c.sidebarCollapsed = false
        #expect(c.cardMargins == (0, 6, 6))
    }

    @Test func themeColorsChromeCardAndPages() {
        let f = Fixture()
        defer { f.cleanup() }
        let c = makeContainer(f)
        c.view.updateLayer()
        c.card.updateLayer()
        #expect(c.view.layer?.backgroundColor == Theme.tokens.chrome.cgColor)
        #expect(c.card.layer?.backgroundColor == Theme.tokens.card.cgColor)
        #expect(c.card.layer?.borderColor == Theme.tokens.cardEdge.cgColor)
        #expect(c.placeholder.appearance?.name == Theme.tokens.cardAppearance.name)
        #expect(c.placeholder.emptyTitle.textColor == Theme.ramp(.card).primary)
        // A theme change recolors the pages (observer path).
        NotificationCenter.default.post(name: .corralThemeDidChange, object: nil)
        #expect(c.findBar.field.textColor == Theme.ramp(.card).primary)
        // Background from the terminal config: tokens follow it.
        let saved = (f.factory.backgroundColor, f.factory.foregroundColor)
        f.factory.backgroundColor = RGB(hex: 0xFDF6E3).color
        f.factory.foregroundColor = RGB(hex: 0x657B83).color
        Theme.update(background: f.factory.backgroundColor, foreground: f.factory.foregroundColor, windowTheme: nil)
        c.applyBackground()
        c.card.updateLayer()
        #expect(RGB(Theme.tokens.card).hex == "#FDF6E3")
        #expect(!Theme.tokens.isCardDark)
        #expect(c.card.layer?.backgroundColor == Theme.tokens.card.cgColor)
        f.factory.backgroundColor = saved.0
        f.factory.foregroundColor = saved.1
        Theme.update(background: saved.0, foreground: saved.1, windowTheme: nil)
        c.applyBackground()
    }

    @Test func switchFadeIsPresentationOnly() {
        let f = Fixture()
        defer { f.cleanup() }
        let c = makeContainer(f)
        f.manager.newSession(agent: .shell, cwd: f.dir.path)
        c.showSelected(focus: false)
        let v = f.terminal(f.selected)!.view
        v.wantsLayer = true
        c.fadeIn(v)
        let fade = v.layer?.animation(forKey: "switch.fade") as? CABasicAnimation
        #expect(fade?.keyPath == "opacity")
        #expect(fade?.fromValue as? Int == 0)
        #expect(fade?.duration == 0.10)
        #expect(v.layer?.opacity == 1)
        #expect(v.alphaValue == 1)
    }

    @Test func emptyStateOffersActionTiles() throws {
        let f = Fixture()
        defer { f.cleanup() }
        // Other suites may leave the app menu installed; start without one.
        let savedMenu = NSApplication.shared.mainMenu
        NSApplication.shared.mainMenu = nil
        defer { NSApplication.shared.mainMenu = savedMenu }
        let c = makeContainer(f)
        c.showSelected(focus: false)
        let p = c.placeholder
        #expect(!p.emptyPage.isHidden && p.previewPage.isHidden)
        #expect(p.tiles.map(\.title) == ["New Shell", "Claude Code", "OpenCode", "PI"])
        #expect(p.tiles.map(\.selector) == [#selector(MainWindowController.newShell(_:)), #selector(MainWindowController.newClaude(_:)),
                                             #selector(MainWindowController.newOpenCode(_:)), #selector(MainWindowController.newPi(_:))])
        #expect(p.action == nil)
        // No main menu: keycaps hide instead of guessing.
        #expect(p.tiles.allSatisfy { $0.keycap.isHidden })
        #expect(p.searchKey.isHidden && p.attentionKey.isHidden)
        Self.withMenu {
            p.refreshHints()
            #expect(p.tiles.map(\.keycap.stringValue) == ["⌘T", "⌃⌘C", "⌃⌘O", "⌃⌘P"])
            #expect(p.searchKey.stringValue == "⌘K")
            #expect(p.attentionKey.stringValue == "⌘I")
            #expect(p.tiles[0].toolTip == "New Shell (⌘T)")
        }
        // Layout: 2×2 grid of 200×56 tiles, 10 apart, centered in the card.
        c.view.layoutSubtreeIfNeeded()
        let frames = p.tiles.map { $0.convert($0.bounds, to: p) }
        #expect(frames.allSatisfy { $0.size == ActionTile.size })
        #expect(frames[1].minX - frames[0].maxX == 10)
        #expect(abs(frames[0].midY - frames[1].midY) < 0.5)
        #expect(abs((frames[0].minX + frames[1].maxX) / 2 - p.bounds.midX) < 1)
        // Optical center: content sits above the geometric middle.
        let content = p.emptyPage.frame
        #expect(content.midY > p.bounds.midY)

        // A click sends the menu action up the responder chain (no key window in tests: unhandled).
        #expect(!p.tiles[1].perform())
        #expect(!p.tiles[1].accessibilityPerformPress())
    }

    @Test func actionTileHoverAndPressStates() {
        let tile = ActionTile(title: "New Shell", symbol: "terminal", action: #selector(MainWindowController.newShell(_:)))
        tile.layoutSubtreeIfNeeded()
        tile.updateLayer()
        let r = Theme.ramp(.card)
        #expect(tile.layer?.backgroundColor == r.sunken.cgColor)
        #expect(tile.layer?.shadowOpacity == 0)
        #expect(tile.layer?.shadowPath != nil)
        tile.setHovered(true)
        #expect(tile.hovered)
        #expect(tile.layer?.backgroundColor == r.selected.cgColor)
        #expect(tile.layer?.borderColor == r.hairlineStrong.cgColor)
        #expect(tile.layer?.shadowOpacity == 1)
        tile.setPressed(true)
        #expect(tile.layer?.backgroundColor == r.pressed.cgColor)
        tile.setHovered(false)
        #expect(!tile.pressed)
        #expect(tile.layer?.backgroundColor == r.sunken.cgColor)
        // Mouse path: press inside, drag out, release outside: no action, no stuck state.
        let down = mouse(.leftMouseDown, at: NSPoint(x: 10, y: 10))
        tile.mouseEntered(with: down)
        tile.mouseDown(with: down)
        #expect(tile.pressed)
        tile.mouseDragged(with: mouse(.leftMouseDragged, at: NSPoint(x: 500, y: 500)))
        #expect(!tile.pressed)
        tile.mouseUp(with: mouse(.leftMouseUp, at: NSPoint(x: 500, y: 500)))
        tile.mouseDown(with: down)
        tile.mouseUp(with: mouse(.leftMouseUp, at: NSPoint(x: 10, y: 10)))
        #expect(!tile.pressed)
        tile.mouseExited(with: down)
        #expect(!tile.hovered)
        tile.updateTrackingAreas()
        tile.updateTrackingAreas()
        #expect(tile.trackingAreas.count == 1)
        #expect(tile.acceptsFirstMouse(for: nil))
        #expect(tile.accessibilityRole() == .button)
        #expect(tile.accessibilityLabel() == "New Shell")
    }

    func mouse(_ type: NSEvent.EventType, at p: NSPoint) -> NSEvent {
        NSEvent.mouseEvent(with: type, location: p, modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil,
                           eventNumber: 0, clickCount: 1, pressure: 1)!
    }

    @Test func closedPreviewShowsFactsAndCommand() {
        let f = Fixture()
        defer { f.cleanup() }
        let c = makeContainer(f)
        f.manager.newSession(agent: .claude, cwd: f.dir.path)
        let id = f.selected!
        f.manager.close(id)
        var r = f.manager.workspace.sessions[id]!
        r.agent = .claude
        r.agentSessionId = "8f2c1d9e-1111-2222-3333-444455556666"
        r.customName = "Kafka consumer lag"
        r.closedAt = Date(timeIntervalSince1970: 1_000_000)
        let p = c.placeholder
        p.now = { Date(timeIntervalSince1970: 1_000_000 + 2 * 3600 + 60) }
        p.command.pasteboard = NSPasteboard(name: NSPasteboard.Name("corral-test-\(UUID().uuidString)"))
        c.showClosed(r)
        c.view.layoutSubtreeIfNeeded()
        #expect(!p.previewPage.isHidden && p.emptyPage.isHidden)
        #expect(p.chip.stringValue == "Closed · 2h ago")
        #expect(p.titleLabel.stringValue == "Kafka consumer lag")
        #expect(p.gridRows.map(\.0) == ["Directory", "Agent", "Session", "Closed"])
        #expect(p.gridRows[1].1 == "Claude Code")
        #expect(p.gridRows[2].1 == "8f2c1d9e-1111-2222-3333-444455556666")
        #expect(p.callout.isHidden && p.detailLabel.isHidden && p.statusIcon.isHidden)
        #expect(!p.previewTile.glyph.isHidden)
        #expect(p.command.label.stringValue == "claude --resume 8f2c1d9e-1111-2222-3333-444455556666")
        #expect(!p.command.isHidden)
        p.command.copyCommand()
        #expect(p.command.pasteboard.string(forType: .string) == p.command.label.stringValue)
        #expect(p.command.copyButton.symbol == "checkmark")
        #expect(p.button.title == "Reopen")
        #expect(p.button.keyEquivalent == "\r")
        #expect(p.button.image != nil)
        // The column is centered, at most 480 wide, and fits in the card.
        let col = p.previewPage.frame
        #expect(col.width <= 480)
        #expect(abs(col.midX - p.bounds.midX) < 1)
        #expect(col.minY >= 0 && col.maxY <= p.bounds.maxY)
        p.command.pasteboard.releaseGlobally()

        // A shell closed just now: no session row, no command block.
        var shell = f.manager.workspace.sessions[id]!
        shell.agent = .shell
        shell.agentSessionId = nil
        shell.closedAt = p.now()
        c.showClosed(shell)
        #expect(p.chip.stringValue == "Closed · just now")
        #expect(p.gridRows.map(\.0) == ["Directory", "Agent", "Closed"])
        #expect(p.command.isHidden)
        p.command.copyCommand()
        #expect(PlaceholderView.closedChip(nil, now: Date()) == "Closed")
    }

    /// The open background page follows its job (state, needs, last change) without re-entering, and
    /// leaves the text alone when nothing changed, so a selection being copied survives.
    @Test func backgroundPageRefreshesInPlace() {
        let f = Fixture()
        defer { f.cleanup() }
        let c = makeContainer(f)
        let p = c.placeholder
        let working = BackgroundAgent(id: "j", sessionId: "s", name: "Job https://x/APP-1", cwd: "/", state: "working",
                                      updatedAt: Date().addingTimeInterval(-600))
        c.showBackground(working)
        #expect(p.page == .background("j") && !p.isHidden)
        #expect(p.chip.stringValue == "Working")

        // Unchanged job: nothing is rewritten.
        p.titleLabel.stringValue = "sentinel"
        c.refreshBackground([working])
        #expect(p.titleLabel.stringValue == "sentinel")
        p.titleLabel.stringValue = working.name

        var blocked = working
        blocked.state = "blocked"
        blocked.needs = "approve deploy"
        blocked.updatedAt = Date()
        c.refreshBackground([BackgroundAgent(id: "other", sessionId: "o", name: "Other", cwd: "/", state: "done"), blocked])
        #expect(p.chip.stringValue == "Blocked")
        #expect(!p.callout.isHidden && p.callout.label.stringValue == "Needs: approve deploy")
        #expect(p.gridRows.last?.1 == PlaceholderView.dateTime.string(from: blocked.updatedAt!))
        #expect(p.shownBackground == blocked)

        // Another page or a hidden placeholder is left alone; a vanished job keeps the last view.
        c.refreshBackground([])
        #expect(p.chip.stringValue == "Blocked")
        f.manager.newSession(agent: .shell, cwd: f.dir.path)
        c.showSelected(focus: false)
        var done = blocked
        done.state = "done"
        c.refreshBackground([done])
        #expect(p.shownBackground == blocked)
    }

    @Test func backgroundPreviewHighlightsWhatItNeeds() {
        let f = Fixture()
        defer { f.cleanup() }
        let c = makeContainer(f)
        let p = c.placeholder
        var attached: [String] = []
        let changed = Date().addingTimeInterval(-60)
        p.showBackground(BackgroundAgent(id: "272cff61", sessionId: "s-1", name: "S3 migration", cwd: "/tmp",
                                         state: "needs_input", needs: "trigger reindex job", detail: "Waiting on approval",
                                         updatedAt: changed)) {
            attached.append("272cff61")
        }
        #expect(p.chip.stringValue == "Needs Input")
        #expect(p.chip.fill == PlaceholderView.amberWash(Theme.tokens))
        #expect(!p.callout.isHidden)
        #expect(p.callout.label.stringValue == "Needs: trigger reindex job")
        #expect(p.detailLabel.stringValue == "Waiting on approval" && !p.detailLabel.isHidden)
        #expect(!p.statusIcon.isHidden && p.previewTile.glyph.isHidden)
        #expect(p.statusIcon.haloSuppressed)
        #expect(p.gridRows.map(\.0) == ["Directory", "Agent", "Job", "Session", "Changed"])
        // Relative wording for recent changes ("Today at 17:17"), not the plain date.
        let shown = p.gridRows.last?.1 ?? ""
        #expect(shown.contains(DateFormatter.localizedString(from: changed, dateStyle: .none, timeStyle: .short)))
        #expect(shown != DateFormatter.localizedString(from: changed, dateStyle: .medium, timeStyle: .short))
        // Everything on the page can be selected and copied.
        #expect(p.titleLabel.isSelectable && p.detailLabel.isSelectable && p.callout.label.isSelectable)
        #expect(p.gridValues.allSatisfy(\.isSelectable) && p.command.label.isSelectable)
        #expect(p.command.label.stringValue == "claude attach 272cff61")
        #expect(p.button.title == "Attach")
        p.tapped()
        #expect(attached == ["272cff61"])
        p.callout.layout()
        p.callout.updateLayer()
        #expect(p.callout.bar.frame.width == 2)
        NotificationCenter.default.post(name: .corralThemeDidChange, object: nil)
        #expect(p.callout.label.stringValue == "Needs: trigger reindex job")

        p.showBackground(BackgroundAgent(id: "b", sessionId: "s-2", name: "Docs", cwd: "/", state: "running"), attach: {})
        #expect(p.chip.stringValue == "Running")
        #expect(p.chip.fill == Theme.ramp(.card).sunken)
        #expect(p.callout.isHidden && p.detailLabel.isHidden)
        // No timestamp from Claude: no Changed row.
        #expect(p.gridRows.map(\.0) == ["Directory", "Agent", "Job", "Session"])
        // Theme refresh keeps the status icon in the tile, not the agent glyph.
        p.applyTheme()
        #expect(p.previewTile.glyph.isHidden)
    }

    @Test func placeholderEntranceOnlyWhenThePageChanges() {
        let reduced = Motion.reduced
        Motion.setReduced(false)
        defer { Motion.setReduced(reduced) }
        let f = Fixture()
        defer { f.cleanup() }
        let c = makeContainer(f)
        let p = c.placeholder
        p.showEmpty()
        p.addEntranceAnimations()
        #expect(p.emptyPage.layer?.animation(forKey: "entrance.opacity") != nil)
        #expect(p.tiles[3].layer?.animation(forKey: "entrance.opacity")?.beginTime ?? 0 > p.tiles[0].layer?.animation(forKey: "entrance.opacity")?.beginTime ?? 0)
        p.showClosed(SessionRecord(cwd: "/tmp"), reopen: {})
        p.addEntranceAnimations()
        #expect(p.previewPage.layer?.animation(forKey: "entrance.rise") != nil)
        Motion.setReduced(true)
        p.previewPage.layer?.removeAllAnimations()
        p.addEntranceAnimations()
        #expect(p.previewPage.layer?.animation(forKey: "entrance.opacity")?.duration == 0.15)
        #expect(p.previewPage.layer?.animation(forKey: "entrance.rise") == nil)
        Motion.setReduced(false)
        // Offscreen: nothing is scheduled.
        p.previewPage.layer?.removeAllAnimations()
        p.playEntrance()
        #expect(p.previewPage.layer?.animationKeys() == nil)

        // M2 scope: terminal → page and empty ↔ preview enter; preview → preview refreshes in place.
        let a = PlaceholderView.Page.closed(UUID()), b = PlaceholderView.Page.closed(UUID())
        typealias C = TerminalContainerViewController
        #expect(C.placeholderEnters(hidden: true, current: a, next: a))
        #expect(C.placeholderEnters(hidden: false, current: nil, next: .empty))
        #expect(C.placeholderEnters(hidden: false, current: .empty, next: a))
        #expect(C.placeholderEnters(hidden: false, current: a, next: .empty))
        #expect(!C.placeholderEnters(hidden: false, current: a, next: b))
        #expect(!C.placeholderEnters(hidden: false, current: a, next: .background("j")))
        #expect(!C.placeholderEnters(hidden: false, current: .empty, next: .empty))
    }

    @Test func tileKeycapPlateSitsAboveTheTileFill() {
        let tile = ActionTile(title: "Claude Code", symbol: "sparkle", action: #selector(MainWindowController.newClaude(_:)))
        tile.keycap.stringValue = "⌃⌘C"
        tile.frame = NSRect(origin: .zero, size: ActionTile.size)
        tile.layoutSubtreeIfNeeded()
        tile.updateLayer()
        tile.keycap.updateLayer()
        let r = Theme.ramp(.card)
        func check(_ fill: NSColor) {
            let plate = tile.keycap.layer?.backgroundColor
            #expect(plate == ActionTile.keycapColors(on: fill).plate.cgColor)
            #expect(plate != fill.cgColor)
            #expect(ColorMath.contrast(RGB(tile.keycap.plate), RGB(fill)) > 1.04)
            #expect(tile.keycap.edge.backgroundColor == tile.keycap.edgeColor.cgColor)
            #expect(tile.keycap.edgeColor != tile.keycap.plate)
        }
        // Resting, hovered and pressed tiles all show a plate (the shared KeyCap's sunken plate
        // would vanish on the sunken resting tile).
        #expect(tile.fillColor == r.sunken)
        check(r.sunken)
        tile.setHovered(true)
        check(r.selected)
        tile.setPressed(true)
        check(r.pressed)
        tile.setHovered(false)
        check(r.sunken)
        // Same colors again: no-op.
        tile.keycap.setColors(plate: tile.keycap.plate, edge: tile.keycap.edgeColor, animated: true, duration: 0.1)
        #expect(tile.keycap.layer?.animation(forKey: "cap.plate") == nil)
        tile.keycap.setColors(plate: r.hover, edge: r.hairline, animated: true, duration: 0.1)
        #expect(tile.keycap.layer?.animation(forKey: "cap.plate") != nil)
        #expect(tile.keycap.edge.animation(forKey: "cap.edge") != nil)
        #expect(tile.keycap.layer?.backgroundColor == r.hover.cgColor)
        // Edge stays inside the rounded plate.
        tile.keycap.layout()
        #expect(tile.keycap.edge.frame.minX == 2 && tile.keycap.edge.frame.height == 1)

        // Fits at 200: keycap shown. A narrow tile drops the keycap instead of truncating the title.
        #expect(!tile.keycap.isHidden)
        tile.frame.size.width = 140
        tile.layoutSubtreeIfNeeded()
        #expect(tile.keycap.isHidden)
        #expect(tile.label.frame.maxX <= 140 - 12)
        tile.frame.size.width = 200
        tile.layoutSubtreeIfNeeded()
        #expect(!tile.keycap.isHidden)
        tile.keycapAllowed = false
        tile.layoutSubtreeIfNeeded()
        #expect(tile.keycap.isHidden)
        tile.keycapAllowed = true
        tile.layoutSubtreeIfNeeded()
        #expect(!tile.keycap.isHidden)
        tile.keycap.stringValue = ""
        tile.layoutSubtreeIfNeeded()
        #expect(tile.keycap.isHidden && tile.keycapNeed == 0)
    }

    @Test func narrowCardHasNoMinimumWidth() {
        let f = Fixture()
        defer { f.cleanup() }
        // The container pinned into a host the way the split view drags it: the trailing edge at
        // the window-drag priority. A required content minimum would win and widen the container.
        func host(width: CGFloat, _ setup: (TerminalContainerViewController) -> Void) -> TerminalContainerViewController {
            let c = TerminalContainerViewController(manager: f.manager)
            let h = NSView(frame: NSRect(x: 0, y: 0, width: width, height: 520))
            c.view.translatesAutoresizingMaskIntoConstraints = false
            h.addSubview(c.view)
            let trailing = c.view.trailingAnchor.constraint(equalTo: h.trailingAnchor)
            trailing.priority = .dragThatCanResizeWindow
            NSLayoutConstraint.activate([
                c.view.leadingAnchor.constraint(equalTo: h.leadingAnchor),
                c.view.topAnchor.constraint(equalTo: h.topAnchor),
                c.view.bottomAnchor.constraint(equalTo: h.bottomAnchor),
                trailing,
            ])
            setup(c)
            h.layoutSubtreeIfNeeded()
            return c
        }
        Self.withMenu {
            // Empty state at a 300 pt card: tiles shrink together and stay inside the card.
            let c = host(width: 306) { c in
                c.showSelected(focus: false)
                c.placeholder.refreshHints()
            }
            #expect(c.view.frame.width == 306)
            #expect(c.card.frame.width == 300)
            let p = c.placeholder
            let frames = p.tiles.map { $0.convert($0.bounds, to: p) }
            #expect(frames.allSatisfy { abs($0.width - frames[0].width) < 0.5 })
            #expect(frames[0].width < ActionTile.size.width)
            #expect(frames.allSatisfy { $0.minX >= 15.5 && $0.maxX <= p.bounds.maxX - 15.5 })
            // Keycaps drop out on all tiles together (one can't fit "Claude Code" + ⌃⌘C).
            #expect(p.tiles.allSatisfy { $0.keycap.isHidden && !$0.keycapAllowed })
            // The subtitle wraps to a second line instead of overflowing.
            let sub = p.emptySubtitle.convert(p.emptySubtitle.bounds, to: p)
            #expect(sub.minX >= 14 && sub.maxX <= p.bounds.maxX - 14)
            #expect(sub.height > 1.5 * (Fonts.pageBody.ascender - Fonts.pageBody.descender))
            // The hint row keeps only the search hint.
            #expect(p.attentionHint.isHidden)
            #expect(p.hintRow.convert(p.hintRow.bounds, to: p).minX >= 0)

            // Roomy card: full hint row, 200 pt tiles with their keycaps.
            let wide = host(width: 806) { c in
                c.showSelected(focus: false)
                c.placeholder.refreshHints()
            }
            #expect(!wide.placeholder.attentionHint.isHidden)
            #expect(wide.placeholder.tiles.allSatisfy { $0.frame.width == ActionTile.size.width && !$0.keycap.isHidden })

            // Preview page and find bar at a 300 pt card.
            f.manager.newSession(agent: .claude, cwd: f.dir.path)
            let id = f.selected!
            f.manager.close(id)
            let record = f.manager.workspace.sessions[id]!
            let pc = host(width: 306) { c in c.showClosed(record) }
            #expect(pc.view.frame.width == 306)
            let col = pc.placeholder.previewPage.frame
            #expect(col.minX >= 23.5 && col.maxX <= pc.placeholder.bounds.maxX - 23.5)
            f.manager.newSession(agent: .shell, cwd: f.dir.path)
            let t = f.terminal(f.selected)!
            let fc = host(width: 306) { c in
                c.showSelected(focus: false)
                c.findAction(.startSearch("kafka"), terminal: t)
            }
            #expect(fc.view.frame.width == 306)
            #expect(fc.findBar.frame.minX >= 7.5)
            #expect(fc.findBar.field.frame.width >= FindBar.minFieldWidth && fc.findBar.field.frame.width < FindBar.fieldWidth)
        }
    }

    @Test func previewButtonAndCopyFeedback() {
        let f = Fixture()
        defer { f.cleanup() }
        let c = makeContainer(f)
        let p = c.placeholder
        // The ↩ keycap carries a transparent leading gutter; the button pads 14 on both sides.
        let img = PlaceholderView.returnKeyImage(color: .white)
        #expect(img.size.width >= 18 + PlaceholderView.returnKeyGutter)
        #expect(img.size.height == 17)
        p.showBackground(BackgroundAgent(id: "b", sessionId: "s", name: "Docs", cwd: "/", state: "running"), attach: {})
        c.view.layoutSubtreeIfNeeded()
        let title = ceil(p.button.attributedTitle.size().width)
        #expect(p.button.frame.width == title + 28 + (p.button.image?.size.width ?? 0))

        // Copy confirmation lasts until the pointer leaves the block (no timers).
        let cmd = p.command
        cmd.pasteboard = NSPasteboard(name: NSPasteboard.Name("corral-test-\(UUID().uuidString)"))
        defer { cmd.pasteboard.releaseGlobally() }
        cmd.copyCommand()
        #expect(cmd.copied && cmd.copyButton.symbol == "checkmark" && cmd.copyButton.toolTip == "Copied")
        let move = mouse(.leftMouseUp, at: .zero)
        cmd.mouseExited(with: move)
        #expect(!cmd.copied && cmd.copyButton.symbol == "doc.on.doc" && cmd.copyButton.toolTip == "Copy command")
        cmd.mouseExited(with: move)
        #expect(cmd.copyButton.symbol == "doc.on.doc")
        cmd.copyCommand()
        cmd.setCommand("claude attach x")
        #expect(!cmd.copied && cmd.copyButton.symbol == "doc.on.doc")
        cmd.updateTrackingAreas()
        cmd.updateTrackingAreas()
        #expect(cmd.trackingAreas.count == 1)
    }

    @Test func themeChangesRecolorOnceThroughTheObservers() {
        let f = Fixture()
        defer { f.cleanup() }
        let c = makeContainer(f)
        let apply = { Theme.update(background: f.factory.backgroundColor, foreground: f.factory.foregroundColor, windowTheme: nil) }
        apply()
        var posts = 0
        let token = NotificationCenter.default.addObserver(forName: .corralThemeDidChange, object: nil, queue: nil) { _ in posts += 1 }
        defer { NotificationCenter.default.removeObserver(token) }
        // Same config: nothing changes, nothing is posted or recolored; applyBackground never writes the theme.
        apply()
        c.applyBackground()
        #expect(posts == 0)
        let saved = (f.factory.backgroundColor, f.factory.foregroundColor)
        defer {
            f.factory.backgroundColor = saved.0
            f.factory.foregroundColor = saved.1
            apply()
        }
        f.factory.backgroundColor = RGB(hex: 0xFFFFFF).color
        f.factory.foregroundColor = RGB(hex: 0x1F2328).color
        apply()
        #expect(posts == 1)
        // The placeholder and find bar recolored themselves from the one notification.
        #expect(c.placeholder.emptyTitle.textColor == Theme.ramp(.card).primary)
        #expect(c.findBar.field.textColor == Theme.ramp(.card).primary)
        c.view.updateLayer()
        c.card.updateLayer()
        #expect(c.view.layer?.backgroundColor == Theme.tokens.chrome.cgColor)
        #expect(c.card.layer?.backgroundColor == Theme.tokens.card.cgColor)
    }

    @Test func findBarDrivesScrollbackSearch() {
        let f = Fixture()
        defer { f.cleanup() }
        let c = TerminalContainerViewController(manager: f.manager)
        _ = c.view
        f.manager.newSession(agent: .shell, cwd: f.dir.path)
        let t = f.terminal(f.selected)!
        c.showSelected(focus: false)
        c.findAction(.startSearch("needle"), terminal: t)
        #expect(!c.findBar.isHidden)
        #expect(c.findBar.isPresented)
        #expect(c.findTargetSession == t.sessionId)
        #expect(t.bindings.last == "search:needle")
        c.findAction(.searchTotal(4), terminal: t)
        c.findAction(.searchSelected(1), terminal: t)
        #expect(c.findBar.count.stringValue == "2/4")
        c.findBar.nextTapped()
        c.findBar.prevTapped()
        #expect(t.bindings.suffix(2) == ["navigate_search:next", "navigate_search:previous"])
        c.findBar.field.stringValue = "other"
        c.findBar.fieldChanged()
        #expect(t.bindings.last == "search:other")
        c.findBar.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification))
        #expect(t.bindings.last == "search:other")
        let tv = NSTextView()
        #expect(c.findBar.control(c.findBar.field, textView: tv, doCommandBy: #selector(NSResponder.insertNewline(_:))))
        #expect(t.bindings.last == "navigate_search:next")
        #expect(!c.findBar.control(c.findBar.field, textView: tv, doCommandBy: #selector(NSResponder.moveLeft(_:))))
        #expect(c.findBar.control(c.findBar.field, textView: tv, doCommandBy: #selector(NSResponder.cancelOperation(_:))))
        #expect(c.findBar.isHidden)
        #expect(!c.findBar.isPresented)
        #expect(c.findBar.field.stringValue == "")
        #expect(t.bindings.last == "end_search")
        c.findAction(.startSearch(nil), terminal: t)
        c.findAction(.endSearch, terminal: t)
        #expect(c.findBar.isHidden)
        c.findAction(.endSearch, terminal: t)
        c.findAction(.bell, terminal: t)
        // Switching sessions hides the bar and ends the search on the outgoing surface, so its
        // highlights don't outlive the bar.
        c.findAction(.startSearch(nil), terminal: t)
        let ends = t.bindings.filter { $0 == "end_search" }.count
        f.manager.newSession(agent: .shell, cwd: f.dir.path)
        c.showSelected(focus: false)
        #expect(c.findBar.isHidden)
        #expect(t.bindings.last == "end_search")
        #expect(t.bindings.filter { $0 == "end_search" }.count == ends + 1)
        // Late actions from the ended surface don't touch the bar now serving another terminal.
        let t2 = f.terminal(f.selected)!
        c.findAction(.startSearch("x"), terminal: t2)
        c.findAction(.searchTotal(7), terminal: t2)
        c.findAction(.searchTotal(1), terminal: t)
        c.findAction(.searchSelected(0), terminal: t)
        c.findAction(.endSearch, terminal: t)
        #expect(c.findBar.isPresented && c.findBar.total == 7 && c.findBar.selected == -1)
        #expect(c.findTargetSession == t2.sessionId)
        // A placeholder page does the same.
        c.showBackground(BackgroundAgent(id: "j", sessionId: "s", name: "Job", cwd: "/", state: "working"))
        #expect(c.findBar.isHidden)
        #expect(c.findTargetSession == nil)
        #expect(t2.bindings.last == "end_search")
        // Same session again: no end_search.
        f.manager.select(t2.sessionId)
        c.showSelected(focus: false)
        c.findAction(.startSearch("y"), terminal: t2)
        c.showSelected(focus: false)
        #expect(c.findBar.isPresented)
        #expect(t2.bindings.last == "search:y")
    }

    @Test func findBarCountTurnsRedOnZeroMatches() {
        let bar = FindBar()
        bar.layoutSubtreeIfNeeded()
        bar.updateLayer()
        let t = Theme.tokens
        #expect(bar.layer?.backgroundColor == t.cardElevated.cgColor)
        #expect(bar.layer?.borderColor == t.ramp(.card).hairlineStrong.cgColor)
        #expect(bar.layer?.cornerRadius == 10)
        #expect(bar.layer?.shadowPath != nil)
        #expect(bar.fittingSize.height == 32)
        // The divider is a real 1×16 view between the count and the chevrons, filled with the
        // strong hairline rebased onto the bar's elevated fill.
        bar.frame = NSRect(x: 0, y: 0, width: 380, height: 32)
        bar.layoutSubtreeIfNeeded()
        bar.divider.updateLayer()
        #expect(bar.divider.frame.size == NSSize(width: 1, height: 16))
        #expect(bar.divider.frame.minX > bar.count.frame.maxX && bar.divider.frame.maxX < bar.prevButton.frame.minX)
        let dividerColor = bar.divider.layer?.backgroundColor
        #expect(dividerColor != nil && dividerColor?.alpha == 1)
        #expect(dividerColor == FindBarDivider.color.cgColor)
        #expect(RGB(FindBarDivider.color) != RGB(t.cardElevated))
        #expect(ColorMath.contrast(RGB(FindBarDivider.color), RGB(t.cardElevated)) > 1.1)
        bar.total = 3
        #expect(bar.count.stringValue == "3")
        #expect(bar.count.textColor == t.ramp(.card).tertiary)
        bar.total = 0
        #expect(!bar.noMatches)
        bar.field.stringValue = "zzz"
        bar.fieldChanged()
        #expect(bar.noMatches)
        #expect(bar.count.stringValue == "0")
        #expect(bar.count.textColor != t.ramp(.card).tertiary)
        #expect(!bar.nextButton.isEnabled && !bar.prevButton.isEnabled)
        var nexts = 0
        bar.onNext = { nexts += 1 }
        // Enter with zero matches still navigates (Ghostty decides); the shake is offscreen-safe.
        #expect(bar.control(bar.field, textView: NSTextView(), doCommandBy: #selector(NSResponder.insertNewline(_:))))
        #expect(nexts == 1)
        bar.addShakeAnimation()
        let shake = bar.layer?.animation(forKey: "find.shake") as? CAKeyframeAnimation
        #expect(shake?.keyPath == "transform.translation.x")
        #expect(shake?.duration == 0.30)
        bar.reset()
        #expect(bar.count.stringValue == "" && bar.field.stringValue == "")
        #expect(bar.nextButton.isEnabled)
    }

    @Test func findBarShowAndHideMotion() {
        let reduced = Motion.reduced
        Motion.setReduced(false)
        defer { Motion.setReduced(reduced) }
        let bar = FindBar()
        bar.isHidden = true
        bar.reveal()
        #expect(!bar.isHidden && bar.isPresented)
        bar.addRevealAnimation()
        #expect(bar.layer?.animation(forKey: "find.in") != nil)
        #expect(bar.layer?.animation(forKey: "find.in.y") != nil)
        Motion.setReduced(true)
        bar.layer?.removeAllAnimations()
        bar.addRevealAnimation()
        #expect(bar.layer?.animation(forKey: "find.in.y") == nil)
        Motion.setReduced(false)
        // Animated hide: stays logically dismissed; a reveal before it lands cancels it.
        bar.dismiss()
        #expect(bar.isHidden && !bar.isPresented)
        bar.reveal()
        bar.addDismissAnimation(generation: 99)
        #expect(bar.layer?.animation(forKey: "find.out") != nil)
        #expect(bar.layer?.animation(forKey: "find.in") == nil)
        bar.reveal()
        #expect(bar.layer?.animation(forKey: "find.out") == nil)
        #expect(!bar.isHidden)
        bar.dismiss()
        bar.dismiss()
        #expect(bar.isHidden)
        bar.shake()
        #expect(bar.layer?.animation(forKey: "find.shake") == nil)
        // Re-showing during a fade-out continues from the current opacity, without the drop.
        bar.layer?.removeAllAnimations()
        bar.addRevealAnimation(from: 0.4)
        let resume = bar.layer?.animation(forKey: "find.in") as? CABasicAnimation
        #expect(resume?.fromValue as? Float == 0.4)
        #expect(bar.layer?.animation(forKey: "find.in.y") == nil)
        bar.layer?.removeAllAnimations()
        bar.addRevealAnimation()
        #expect((bar.layer?.animation(forKey: "find.in") as? CABasicAnimation)?.fromValue as? Float == 0)
    }

    /// Opt-in visual review: CORRAL_SNAPSHOTS=<dir> renders the card pages offscreen.
    @Test(.enabled(if: cardSnapshotDir != nil)) func cardGallery() throws {
        let out = URL(fileURLWithPath: cardSnapshotDir!)
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        Motion.enabled = false
        defer { Motion.enabled = true }
        let palettes: [(String, NSAppearance.Name, UInt32, UInt32)] = [
            ("dark", .darkAqua, 0x1E1E2E, 0xCDD6F4), ("light", .aqua, 0xFDF6E3, 0x657B83),
        ]
        Self.withMenu {
            for (name, appearance, bg, fg) in palettes {
                // Launch covers stay up for the shots (no cap while rendering).
                let f = Fixture { $0.launchProbeCap = 600 }
                defer { f.cleanup() }
                f.factory.backgroundColor = RGB(hex: bg).color
                f.factory.foregroundColor = RGB(hex: fg).color
                Theme.update(background: f.factory.backgroundColor, foreground: f.factory.foregroundColor, windowTheme: nil)
                let w = MainWindowController(manager: f.manager)
                let window = w.window!
                window.appearance = NSAppearance(named: appearance)
                window.setContentSize(NSSize(width: 1100, height: 680))
                window.alphaValue = 0
                window.ignoresMouseEvents = true
                window.orderFrontRegardless()
                defer { window.orderOut(nil) }
                if let item = w.split.splitViewItems.first, item.isCollapsed { item.isCollapsed = false }
                let c = w.container
                @MainActor func shot(_ tag: String) {
                    Self.render(window.contentView!.superview ?? window.contentView!, to: out.appendingPathComponent("card-\(tag)-\(name).png"))
                }
                c.showSelected(focus: false)
                c.placeholder.tiles[1].setHovered(true)
                shot("empty")
                c.placeholder.tiles[1].setHovered(false)

                f.manager.newSession(agent: .claude, cwd: f.dir.path)
                let id = f.selected!
                f.manager.rename(id, to: "Kafka consumer lag in the library ingestion pipeline")
                f.manager.close(id)
                var r = f.manager.workspace.sessions[id]!
                r.agentSessionId = "8f2c1d9e-4b7a-4c1e-9f3d-2a6b0c5e7d11"
                r.closedAt = Date().addingTimeInterval(-7300)
                r.cwd = NSHomeDirectory() + "/Documents/Code/photo-library"
                c.showClosed(r)
                shot("closed")

                c.showBackground(BackgroundAgent(id: "272cff61", sessionId: "272cff61-0b2e-4d6c-8a51-7c1f3e9d2a40",
                                                 name: "EU/US/APAC/LATAM S3 migration", cwd: NSHomeDirectory() + "/Documents/Code/photo-sharing",
                                                 state: "blocked", needs: "trigger reindex job on staging",
                                                 detail: "Paused before the production cutover step.",
                                                 updatedAt: Date().addingTimeInterval(-1500)))
                shot("background")

                // Launch cover: a new Claude session before its first frame, then a background attach.
                let repo = NSHomeDirectory() + "/Documents/Code/corral"
                let launchDir = FileManager.default.fileExists(atPath: repo) ? repo : f.dir.path
                f.manager.newSession(agent: .claude, cwd: launchDir)
                let launching = f.selected!
                f.manager.rename(launching, to: "Launch cover polish")
                for t in f.factory.made {
                    t.view.wantsLayer = true
                    t.view.layer?.backgroundColor = RGB(hex: bg).color.cgColor
                }
                c.showSelected(focus: false)
                shot("launch")
                f.manager.attach(BackgroundAgent(id: "9d41a7c0", sessionId: "9d41a7c0-1f2e-4b3c-8d7e-6a5b4c3d2e1f",
                                                 name: "Nightly thumb refresh", cwd: launchDir, state: "working"))
                for t in f.factory.made {
                    t.view.wantsLayer = true
                    t.view.layer?.backgroundColor = RGB(hex: bg).color.cgColor
                }
                c.showSelected(focus: false)
                shot("launch-attach")

                f.manager.newSession(agent: .shell, cwd: f.dir.path)
                c.showSelected(focus: false)
                for t in f.factory.made {
                    t.view.wantsLayer = true
                    t.view.layer?.backgroundColor = RGB(hex: bg).color.cgColor
                }
                let t = f.terminal(f.selected)!
                c.findAction(.startSearch("kafka"), terminal: t)
                c.findAction(.searchTotal(12), terminal: t)
                c.findAction(.searchSelected(2), terminal: t)
                shot("find")
                c.findAction(.searchTotal(0), terminal: t)
                c.findAction(.searchSelected(-1), terminal: t)
                shot("find-none")

                // Narrow card (half-screen window, wide sidebar): tiles shrink, keycaps and the
                // second hint drop out, nothing overflows the card.
                let narrow = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 380, height: 560), styleMask: [.borderless],
                                      backing: .buffered, defer: false)
                narrow.isReleasedWhenClosed = false
                narrow.appearance = NSAppearance(named: appearance)
                narrow.alphaValue = 0
                narrow.ignoresMouseEvents = true
                let nc = TerminalContainerViewController(manager: f.manager)
                narrow.contentView = nc.view
                narrow.orderFrontRegardless()
                defer { narrow.orderOut(nil) }
                f.manager.select(nil)
                nc.showSelected(focus: false)
                nc.placeholder.refreshHints()
                Self.render(nc.view, to: out.appendingPathComponent("card-empty-narrow-\(name).png"))
                nc.placeholder.isHidden = true
                nc.findBar.reveal()
                nc.findBar.field.stringValue = "consumer lag"
                nc.findBar.total = 3
                Self.render(nc.view, to: out.appendingPathComponent("card-find-narrow-\(name).png"))
                nc.findBar.dismiss()
                f.manager.select(launching)
                nc.showSelected(focus: false)
                Self.render(nc.view, to: out.appendingPathComponent("card-launch-narrow-\(name).png"))
            }
        }
    }

    static func render(_ view: NSView, to url: URL) {
        view.layoutSubtreeIfNeeded()
        view.displayIfNeeded()
        guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
        view.cacheDisplay(in: view.bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])?.write(to: url)
    }
}
