import AppKit
@testable import CorralCore
import Testing
@testable import CorralKit

/// Opt-in: CORRAL_SNAPSHOTS=<dir> renders the main window offscreen (light + dark) with sessions in
/// every state, for visual review without putting anything on screen.
@MainActor
@Suite(.serialized)
struct SnapshotTests {
    nonisolated static let dir = ProcessInfo.processInfo.environment["CORRAL_SNAPSHOTS"]

    /// Builds a realistic workspace: folders, agents in every state, closed sessions, a background job.
    static func populate(_ f: Fixture) {
        let m = f.manager!
        let infra = m.newFolder(name: "Photo Library", directory: f.dir.path)
        let cart = m.newFolder(name: "Garden Planner")
        func add(_ title: String, _ agent: AgentKind, in folder: UUID?, _ signals: [Signal]) {
            m.newSession(agent: agent, cwd: f.dir.path, folder: .some(folder))
            let id = m.workspace.selected!
            // Running sessions: the launch cover has its own gallery (ContainerTests.cardGallery).
            m.launchReady(id)
            m.rename(id, to: title)
            for s in signals { m.apply(s, to: id) }
        }
        f.effects.active = false
        add("APP-66947 replica conflicts", .claude, in: infra,
            [.hook(HookEvent(agent: .claude, event: "PermissionRequest", message: "Bash: ./gradlew test --tests Replica*"))])
        add("Library error rates", .claude, in: infra, [.hook(HookEvent(agent: .claude, event: "UserPromptSubmit"))])
        add("Thumb sizes for HEIC", .opencode, in: infra,
            [.hook(HookEvent(agent: .opencode, event: "session.status", status: "busy")),
             .hook(HookEvent(agent: .opencode, event: "session.idle"))])
        add("EXIF metadata import", .claude, in: cart, [])
        add("gradle build", .shell, in: cart, [.commandFinished(exitCode: 1, seconds: 42)])
        add("websocket refactor", .pi, in: nil, [.hook(HookEvent(agent: .pi, event: "agent_start"))])
        add("~/Documents/Code", .shell, in: nil, [])
        m.newSession(agent: .shell, cwd: f.dir.path, folder: .some(nil))
        let closed = m.workspace.selected!
        m.rename(closed, to: "Kafka consumer lag")
        m.close(closed)
        m.applyBackground([BackgroundAgent(id: "272cff61", sessionId: "272cff61-x", name: "EU/US/APAC/LATAM S3 migration",
                                           cwd: f.dir.path, state: "blocked", needs: "trigger reindex job")])
        m.select(m.workspace.openSessionsInOrder[1])
    }

    /// The galleries show running sessions; no launch cover or "Starting…" leaks into them.
    @Test func populatedWorkspaceHasNoLaunchingSessions() {
        let f = Fixture()
        defer { f.cleanup() }
        Self.populate(f)
        #expect(f.manager.launchingCount == 0)
    }

    static func render(_ view: NSView, to url: URL) {
        view.layoutSubtreeIfNeeded()
        view.displayIfNeeded()
        guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
        view.cacheDisplay(in: view.bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])?.write(to: url)
    }

    /// The keyboard-shortcuts sheet from the real menu, on a popover-like background.
    @Test(.enabled(if: dir != nil)) func shortcutsSheet() throws {
        let out = URL(fileURLWithPath: Self.dir!)
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        _ = NSApplication.shared
        let menu = AppDelegate(makeTerminals: { FakeFactory() }).buildMenu()
        for (name, appearance, bg, fg) in [("dark", NSAppearance.Name.darkAqua, UInt32(0x1E1E2E), UInt32(0xCDD6F4)),
                                           ("light", .aqua, 0xFDF6E3, 0x657B83)] {
            Theme.update(background: RGB(hex: bg).color, foreground: RGB(hex: fg).color, windowTheme: nil)
            let sheet = ShortcutsView(sections: ShortcutList.sections(from: menu))
            let box = NSBox()
            box.boxType = .custom
            box.titlePosition = .noTitle
            box.borderWidth = 0
            box.cornerRadius = 10
            box.fillColor = .windowBackgroundColor
            box.contentViewMargins = .zero
            box.contentView = sheet
            box.appearance = NSAppearance(named: appearance)
            box.frame = NSRect(origin: .zero, size: sheet.fittingSize)
            Self.render(box, to: out.appendingPathComponent("shortcuts-\(name).png"))
        }
    }

    @Test(.enabled(if: dir != nil)) func mainWindow() throws {
        let out = URL(fileURLWithPath: Self.dir!)
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        Motion.enabled = false
        defer { Motion.enabled = true }
        // Two reference terminal themes: Catppuccin Mocha (dark) and Solarized Light.
        let palettes: [(String, NSAppearance.Name, UInt32, UInt32)] = [
            ("dark", .darkAqua, 0x1E1E2E, 0xCDD6F4), ("light", .aqua, 0xFDF6E3, 0x657B83),
        ]
        for (name, appearance, bg, fg) in palettes {
            let f = Fixture()
            defer { f.cleanup() }
            f.factory.backgroundColor = RGB(hex: bg).color
            f.factory.foregroundColor = RGB(hex: fg).color
            Theme.update(background: f.factory.backgroundColor, foreground: f.factory.foregroundColor, windowTheme: nil)
            let w = MainWindowController(manager: f.manager)
            let window = w.window!
            window.appearance = NSAppearance(named: appearance)
            window.setContentSize(NSSize(width: 1100, height: 680))
            // Ordered in but fully transparent and click-through: real layout, nothing visible.
            window.alphaValue = 0
            window.ignoresMouseEvents = true
            window.orderFrontRegardless()
            defer { window.orderOut(nil) }
            if let item = w.split.splitViewItems.first, item.isCollapsed { item.isCollapsed = false }
            Self.populate(f)
            w.sidebar.outline.expandItem(w.sidebar.node(.closedHeader))
            for t in f.factory.made {
                t.view.wantsLayer = true
                t.view.layer?.backgroundColor = RGB(hex: bg).color.cgColor
            }
            RunLoop.main.run(until: Date().addingTimeInterval(0.3))
            Self.render(w.window!.contentView!.superview ?? w.window!.contentView!, to: out.appendingPathComponent("main-\(name).png"))
            Self.render(w.sidebar.view, to: out.appendingPathComponent("sidebar-\(name).png"))

            // Two sessions on one card, a third dragged over its left half.
            let order = f.manager.workspace.openSessionsInOrder
            f.manager.showBeside(order[0], of: order[1])
            let stack = w.container.stack.bounds
            _ = w.container.dragOver(token: "s:\(order[2].uuidString)",
                                     at: w.container.card.convert(NSPoint(x: stack.minX + 20, y: stack.midY), from: w.container.stack))
            RunLoop.main.run(until: Date().addingTimeInterval(0.2))
            Self.render(w.window!.contentView!.superview ?? w.window!.contentView!, to: out.appendingPathComponent("main-split-\(name).png"))
            w.container.cardDragEnded()

            let p = SearchPanelController(manager: f.manager)
            p.window?.appearance = NSAppearance(named: appearance)
            p.window?.alphaValue = 0
            p.window?.ignoresMouseEvents = true
            p.window?.orderFrontRegardless()
            defer { p.window?.orderOut(nil) }
            p.hits = [
                SearchHit(key: "claude:a", agent: .claude, sessionId: "a", cwd: f.dir.path, title: "Library Kafka authentication",
                          updated: Date(), snippets: [SearchSnippet(role: "user", text: "why does the \u{1}kafka\u{2} consumer lag grow", date: nil),
                                                      SearchSnippet(role: "command", text: "rg -n \u{1}kafka\u{2} src/", date: nil)]),
                SearchHit(key: "opencode:b", agent: .opencode, sessionId: "b", cwd: "/repo", title: "Grafana metric for consumer lag",
                          updated: Date().addingTimeInterval(-86_400), snippets: [SearchSnippet(role: "assistant", text: "The \u{1}kafka\u{2} metric is…", date: nil)]),
            ]
            p.hits[0].matchCount = 7
            p.hits[1].matchCount = 1
            p.field.stringValue = "kafka"
            p.applyFilter()
            RunLoop.main.run(until: Date().addingTimeInterval(0.2))
            Self.render(p.window!.contentView!, to: out.appendingPathComponent("search-\(name).png"))

            // → details for the first result, fed directly once the index has answered for the fake key.
            p.showPreview()
            RunLoop.main.run(until: Date().addingTimeInterval(0.3))
            let now = Date()
            p.preview.show(p.shown[0], place: .outside, detail: SearchDetail(
                created: now.addingTimeInterval(-3 * 86_400), updated: now.addingTimeInterval(-900), total: 7,
                matches: [
                    SearchSnippet(role: "user", text: "why does the \u{1}kafka\u{2} consumer lag grow every night around 02:00? It started after the last deploy last week.",
                                  date: now.addingTimeInterval(-3 * 86_400)),
                    SearchSnippet(role: "command", text: "rg -n \u{1}kafka\u{2} src/main/kotlin --glob '*Consumer*'", date: now.addingTimeInterval(-3 * 86_400 + 60)),
                    SearchSnippet(role: "assistant", text: "The lag comes from the nightly re-aggregation: it publishes 40k updates in one burst and the \u{1}kafka\u{2} listener commits per message. Batching the commits (max.poll.records 500) brings it back under a minute.",
                                  date: now.addingTimeInterval(-3 * 86_400 + 300)),
                ]), searched: true)
            RunLoop.main.run(until: Date().addingTimeInterval(0.2))
            Self.render(p.window!.contentView!, to: out.appendingPathComponent("search-details-\(name).png"))
        }
    }
}
