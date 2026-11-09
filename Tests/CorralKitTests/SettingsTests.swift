import AppKit
@testable import CorralCore
import Testing
@testable import CorralKit

@MainActor
struct SettingsTests {
    static let dark = (bg: RGB(hex: 0x1E1E2E).color, fg: RGB(hex: 0xCDD6F4).color)
    static let light = (bg: RGB(hex: 0xFDF6E3).color, fg: RGB(hex: 0x657B83).color)
    nonisolated static let snapshotDir = ProcessInfo.processInfo.environment["CORRAL_SNAPSHOTS"]

    /// Forces `updateLayer` on a themed view without putting it on screen.
    static func draw(_ v: NSView) {
        v.needsDisplay = true
        v.displayIfNeeded()
    }

    @Test func perAgentDefaults() {
        let f = Fixture()
        defer { f.cleanup() }
        let folder = f.manager.newFolder(name: "Agents")
        _ = f.manager.newFolder(name: "Nested", in: folder)
        f.manager.setAgentDefaults(AgentDefaults(directory: f.dir.path), for: .claude)
        let w = SettingsWindowController(manager: f.manager)
        w.refresh()
        #expect(w.pathLabels[.claude]?.stringValue.isEmpty == false)
        #expect(w.pathLabels[.claude]?.toolTip == f.dir.path)
        #expect(w.pathLabels[.pi]?.stringValue == "Not set")
        let popup = w.folderPopups[.opencode]!
        #expect(popup.numberOfItems == 3)
        popup.selectItem(at: 1)
        w.folderChanged(popup)
        #expect(f.manager.workspace.defaults(for: .opencode).folder == folder)
        let clear = NSButton()
        clear.tag = AgentKind.allCases.firstIndex(of: .claude)!
        w.clearDirectory(clear)
        #expect(f.manager.workspace.defaults(for: .claude).directory == nil)
    }

    @Test func folderPopupListsFoldersInSidebarOrderWithIndentation() {
        let f = Fixture()
        defer { f.cleanup() }
        let a = f.manager.newFolder(name: "Agents")
        let nested = f.manager.newFolder(name: "Nested", in: a)
        // Same name twice: both must stay (addItem(withTitle:) would merge them).
        let b = f.manager.newFolder(name: "Agents")
        f.manager.setAgentDefaults(AgentDefaults(folder: b), for: .pi)
        let w = SettingsWindowController(manager: f.manager)
        let popup = w.folderPopups[.pi]!
        #expect(popup.itemTitles == ["Next to selection", "Agents", "Nested", "Agents"])
        #expect(popup.itemArray.map(\.indentationLevel) == [0, 0, 1, 0])
        #expect(popup.itemArray.allSatisfy { $0.image != nil })
        #expect(popup.indexOfSelectedItem == 3)
        popup.selectItem(at: 2)
        w.folderChanged(popup)
        #expect(f.manager.workspace.defaults(for: .pi).folder == nested)
        popup.selectItem(at: 0)
        w.folderChanged(popup)
        #expect(f.manager.workspace.defaults(for: .pi).folder == nil)
        // A deleted default folder falls back to the first entry.
        f.manager.setAgentDefaults(AgentDefaults(folder: UUID()), for: .shell)
        #expect(w.folderPopups[.shell]?.indexOfSelectedItem == 0)
    }

    @Test func clearButtonShowsOnlyWhenADirectoryIsSet() {
        let f = Fixture()
        defer { f.cleanup() }
        f.manager.setAgentDefaults(AgentDefaults(directory: f.dir.path), for: .claude)
        let w = SettingsWindowController(manager: f.manager)
        let r = Theme.ramp(.card)
        #expect(w.clearButtons[.claude]?.isHidden == false)
        #expect(w.clearButtons[.pi]?.isHidden == true)
        #expect(w.pathLabels[.claude]?.textColor == r.secondary)
        #expect(w.pathLabels[.claude]?.font == Fonts.pageMono)
        #expect(w.pathLabels[.pi]?.textColor == r.tertiary)
        #expect(w.pathLabels[.pi]?.font == NSFont.systemFont(ofSize: 12, weight: .regular))
        // The clear button acts for its own row (tag = AgentKind index) and the row updates via .structure.
        let clear = w.clearButtons[.claude]!
        #expect(clear.target === w)
        #expect(clear.action == #selector(SettingsWindowController.clearDirectory(_:)))
        w.clearDirectory(clear)
        #expect(f.manager.workspace.defaults(for: .claude).directory == nil)
        #expect(w.clearButtons[.claude]?.isHidden == true)
        #expect(w.pathLabels[.claude]?.stringValue == "Not set")
        #expect(w.pathLabels[.claude]?.textColor == Theme.ramp(.card).tertiary)
        #expect(w.pathLabels[.claude]?.font != Fonts.pageMono)
        #expect(w.pathLabels[.claude]?.toolTip == nil)
        f.manager.setAgentDefaults(AgentDefaults(directory: f.dir.path), for: .pi)
        #expect(w.clearButtons[.pi]?.isHidden == false)
        #expect(w.pathLabels[.pi]?.stringValue == RelativeTime.abbreviatePath(f.dir.path))
    }

    @Test func rowControlsAreWiredPerAgent() {
        let f = Fixture()
        defer { f.cleanup() }
        let w = SettingsWindowController(manager: f.manager)
        for (i, agent) in AgentKind.allCases.enumerated() {
            #expect(w.chooseButtons[agent]?.tag == i)
            #expect(w.chooseButtons[agent]?.action == #selector(SettingsWindowController.chooseDirectory(_:)))
            #expect(w.clearButtons[agent]?.tag == i)
            #expect(w.folderPopups[agent]?.tag == i)
            #expect(w.folderPopups[agent]?.action == #selector(SettingsWindowController.folderChanged(_:)))
            #expect(w.tiles[agent]?.agent == agent)
        }
    }

    @Test func groupSeparatorsSitBetweenRowsInsetToTheNameColumn() {
        let g = SettingsGroupView(rows: 4, rowHeight: 52, separatorInset: 52)
        g.frame = NSRect(x: 0, y: 0, width: 560, height: 208)
        g.layout()
        #expect(g.separators.count == 3)
        #expect(g.separators.map(\.frame.minX) == [52, 52, 52])
        #expect(g.separators.map(\.frame.width) == [508, 508, 508])
        #expect(g.separators.map(\.frame.minY) == [156, 104, 52])
        #expect(g.separators.allSatisfy { $0.frame.height == 1 && $0.action(forKey: "backgroundColor") == nil })
        let none = SettingsGroupView(rows: 1, rowHeight: 52, separatorInset: 52)
        #expect(none.separators.isEmpty)
    }

    @Test func tileFillDoublesTheSunkenOverlay() {
        let t = ThemeTokens.make(background: Self.dark.bg, foreground: Self.dark.fg, windowTheme: nil,
                                 systemDark: true, increaseContrast: false, accent: .systemBlue)
        let r = t.ramp(.chrome)
        let expected = ColorMath.over(RGB(r.primary), RGB(r.surface), 0.10)
        let fill = RGB(SettingsTileView.fill(r))
        #expect(abs(fill.r - expected.r) < 0.01 && abs(fill.g - expected.g) < 0.01 && abs(fill.b - expected.b) < 0.01)
        #expect(ColorMath.lightness(fill) > ColorMath.lightness(RGB(r.sunken)))
    }

    @Test func notSetPlaceholderStaysLegibleOnTheGroupFill() {
        for (bg, fg) in [Self.dark, Self.light] {
            for contrast in [false, true] {
                let t = ThemeTokens.make(background: bg, foreground: fg, windowTheme: nil, systemDark: bg == Self.dark.bg,
                                         increaseContrast: contrast, accent: .systemBlue)
                let r = t.ramp(.card)
                let placeholder = SettingsWindowController.pathColor(set: false, r)
                #expect(placeholder == r.tertiary)
                #expect(SettingsWindowController.pathColor(set: true, r) == r.secondary)
                // Drawn on the group's sunken fill, not on chrome: still ≥ 2.8:1 (tertiary is guarded to 3:1 on chrome).
                #expect(ColorMath.contrast(RGB(placeholder), RGB(r.sunken)) >= 2.8)
            }
        }
    }

    @Test func pathTruncatesAtTheHeadAndClearHugsIt() throws {
        let f = Fixture()
        defer { f.cleanup() }
        let home = NSHomeDirectory()
        f.manager.setAgentDefaults(AgentDefaults(directory: home + "/Code"), for: .claude)
        let long = home + "/Documents/Code/photo-library/service/src/main/kotlin/com/example/library/and/deeper/still"
        f.manager.setAgentDefaults(AgentDefaults(directory: long), for: .opencode)
        let w = SettingsWindowController(manager: f.manager)
        let window = try #require(w.window)
        w.show(.agents, animated: false)
        window.contentView?.layoutSubtreeIfNeeded()
        for agent in AgentKind.allCases {
            #expect(w.pathLabels[agent]?.lineBreakMode == .byTruncatingHead)
        }
        // In window coordinates, on alignment rects (a label's frame is 2 pt wider on each side than its text).
        func win(_ v: NSView) -> NSRect { v.superview!.convert(v.alignmentRect(forFrame: v.frame), to: nil) }
        // Short path: as wide as its text, × right after it, then Choose….
        let shortPath = try #require(w.pathLabels[.claude]), shortClear = try #require(w.clearButtons[.claude])
        let choose = try #require(w.chooseButtons[.claude])
        #expect(abs(win(shortClear).minX - win(shortPath).maxX - 6) < 1)
        #expect(abs(win(shortPath).width - shortPath.intrinsicContentSize.width) < 1)
        #expect(abs(win(choose).minX - win(shortClear).maxX - 10) < 1)
        // Long path: compressed into the row (the title column stays), × still hugs it.
        let longPath = try #require(w.pathLabels[.opencode]), longClear = try #require(w.clearButtons[.opencode])
        let longChoose = try #require(w.chooseButtons[.opencode])
        #expect(win(longPath).width < longPath.intrinsicContentSize.width - 20)
        #expect(abs(win(longClear).minX - win(longPath).maxX - 6) < 1)
        #expect(longPath.stringValue == RelativeTime.abbreviatePath(long))
        #expect(longPath.toolTip == long)
        // Choose… sits on the trailing edge whatever the path length.
        #expect(abs(win(choose).maxX - win(longChoose).maxX) < 0.5)
    }

    @Test func popupMenusAreRebuiltOnlyWhenTheFolderListChanges() throws {
        let f = Fixture()
        defer { f.cleanup() }
        let a = f.manager.newFolder(name: "Agents")
        f.manager.setAgentDefaults(AgentDefaults(folder: a), for: .claude)
        let w = SettingsWindowController(manager: f.manager)
        let popup = try #require(w.folderPopups[.claude])
        let menu = popup.menu
        // Session-only structure changes reuse the menus.
        f.manager.newSession(agent: .shell, cwd: f.dir.path)
        f.manager.close(try #require(f.selected))
        f.manager.setAgentDefaults(AgentDefaults(directory: f.dir.path, folder: a), for: .claude)
        #expect(popup.menu === menu)
        #expect(popup.indexOfSelectedItem == 1)
        #expect(w.pathLabels[.claude]?.stringValue == RelativeTime.abbreviatePath(f.dir.path))
        // Renaming, adding or nesting a folder rebuilds them, keeping the selection on the same folder.
        f.manager.rename(a, to: "Renamed")
        #expect(popup.menu !== menu)
        #expect(popup.itemTitles == ["Next to selection", "Renamed"])
        let renamed = popup.menu
        _ = f.manager.newFolder(name: "First", in: nil)
        #expect(popup.menu !== renamed)
        #expect(popup.titleOfSelectedItem == "Renamed")
        #expect(w.folderPopups[.pi]?.numberOfItems == 3)
        // An explicit refresh with nothing changed is a no-op for the menus.
        let current = popup.menu
        w.refresh()
        #expect(popup.menu === current)
    }

    @Test func menuSymbolsShareOneCanvas() throws {
        let f = Fixture()
        defer { f.cleanup() }
        _ = f.manager.newFolder(name: "Agents")
        let w = SettingsWindowController(manager: f.manager)
        let images = try #require(w.folderPopups[.shell]?.itemArray.map(\.image))
        let sizes = images.compactMap { $0?.size }
        #expect(sizes.count == 2)
        #expect(sizes.allSatisfy { $0 == sizes[0] })
        #expect(images.allSatisfy { $0?.isTemplate == true })
        // The glyph is drawn centered into the canvas.
        let symbols = SettingsWindowController.menuSymbols(["arrow.turn.down.right", "no.such.symbol.corral"])
        #expect(symbols[1] == nil)
        let image = try #require(symbols[0])
        var rect = NSRect(origin: .zero, size: image.size)
        let cg = try #require(image.cgImage(forProposedRect: &rect, context: nil, hints: nil))
        #expect(cg.width > 0 && cg.height > 0)
    }

    @Test func placeWindowRestoresOrCentersOnceThenKeepsThePosition() throws {
        let name = "CorralSettingsTest-\(UUID().uuidString)"
        defer { NSWindow.removeFrame(usingName: name) }
        let f = Fixture()
        defer { f.cleanup() }
        let w = SettingsWindowController(manager: f.manager)
        w.frameName = name
        let window = try #require(w.window)
        let fitted = window.frame.size
        #expect(!w.positioned)
        w.placeWindow()
        #expect(w.positioned)
        #expect(window.frameAutosaveName == name)
        #expect(window.frame.size == fitted)
        // A window the user moved stays put on the next ⌘,.
        window.setFrameOrigin(NSPoint(x: 120, y: 240))
        w.placeWindow()
        #expect(window.frame.origin == NSPoint(x: 120, y: 240))
        // Next launch: the saved frame comes back.
        // Relative to the main screen: AppKit drops a saved frame that is on no screen.
        let screen = NSScreen.main?.visibleFrame.origin ?? .zero
        window.setFrame(NSRect(x: screen.x + 120, y: screen.y + 140, width: fitted.width, height: fitted.height + 100), display: false)
        window.saveFrame(usingName: name)
        let saved = window.frame
        let w2 = SettingsWindowController(manager: f.manager)
        w2.frameName = name
        let window2 = try #require(w2.window)
        w2.placeWindow()
        // Resizable: the saved size comes back too.
        #expect(window2.frame == saved)
    }

    // MARK: Gallery

    /// Opt-in (CORRAL_SNAPSHOTS=<dir>): renders every Settings page offscreen as settings-<page>-{dark,light}.png.
    /// Synchronous on purpose: no other test can change the global theme between update and render.
    @Test(.enabled(if: snapshotDir != nil)) func gallery() throws {
        let out = URL(fileURLWithPath: Self.snapshotDir!)
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        let wasEnabled = Motion.enabled
        Motion.enabled = false
        let savedUnbinds = GhosttyDefaults.unbinds
        defer {
            Motion.enabled = wasEnabled
            GhosttyDefaults.unbinds = savedUnbinds
            Theme.update(background: nil, foreground: nil, windowTheme: nil)
        }
        _ = NSApplication.shared
        for (name, colors) in [("dark", Self.dark), ("light", Self.light)] {
            let f = Fixture()
            defer { f.cleanup() }
            Theme.update(background: colors.bg, foreground: colors.fg, windowTheme: nil)
            let m = f.manager!
            let home = NSHomeDirectory()
            let infra = m.newFolder(name: "Photo Library")
            _ = m.newFolder(name: "Replica conflicts", in: infra)
            let cart = m.newFolder(name: "Garden Planner")
            m.setAgentDefaults(AgentDefaults(directory: home + "/Code/corral", folder: infra), for: .claude)
            m.setAgentDefaults(AgentDefaults(directory: home + "/Documents/Code/photo-library/service/src/main/kotlin",
                                             folder: cart), for: .opencode)
            m.setAgentDefaults(AgentDefaults(folder: cart), for: .pi)
            _ = try Integrations.installClaude(settingsURL: f.env.integrationPaths.claudeSettings)
            m.refreshIntegrations()
            m.setKeepAwake(true)
            m.newSession(agent: .claude, cwd: f.dir.path)
            m.apply(.hook(HookEvent(agent: .claude, event: "UserPromptSubmit")), to: m.workspace.selected!)
            let suite = "corral-gallery-\(UUID().uuidString)"
            let defaults = UserDefaults(suiteName: suite)!
            defer { defaults.removePersistentDomain(forName: suite) }
            let app = AppDelegate(makeTerminals: { FakeFactory() }, shortcutDefaults: defaults)
            app.trackerAvailable = { false }
            app.shortcuts.register(app.buildMenu())
            app.shortcuts.set(KeyCombo(key: "c", mods: [.command, .control]),
                              for: NSStringFromSelector(#selector(MainWindowController.newShell(_:))))
            let w = SettingsWindowController(manager: m, shortcuts: app.shortcuts)
            w.ghosttyConfigPath = { home + "/.config/ghostty/config" }
            let window = try #require(w.window)
            window.alphaValue = 0
            window.ignoresMouseEvents = true
            window.orderFrontRegardless()
            defer { window.orderOut(nil) }
            for pane in SettingsPane.allCases {
                w.show(pane, animated: false)
                w.refreshTerminal()
                if pane == .shortcuts, let rec = w.shortcutsView?.rows.first?.recorder {
                    rec.beginRecording()
                    rec.setLiveMods([.command, .shift])
                }
                let frame = window.contentView?.superview ?? window.contentView!
                frame.layoutSubtreeIfNeeded()
                frame.displayIfNeeded()
                let rep = try #require(frame.bitmapImageRepForCachingDisplay(in: frame.bounds))
                frame.cacheDisplay(in: frame.bounds, to: rep)
                try rep.representation(using: .png, properties: [:])?
                    .write(to: out.appendingPathComponent("settings-\(pane.rawValue)-\(name).png"))
            }
        }
    }
}
