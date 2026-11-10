import AppKit
@testable import CorralCore
import Testing
@testable import CorralKit

@MainActor
struct SidebarTests {
    typealias Kind = SidebarNode.Kind

    func make() -> (Fixture, SidebarViewController) {
        let f = Fixture()
        let s = SidebarViewController(manager: f.manager)
        _ = s.view
        return (f, s)
    }

    /// Sidebar laid out in a window that is never ordered in: real row views and cells, nothing on screen.
    func makeWindowed(height: CGFloat = 760) -> (Fixture, SidebarViewController, NSWindow) {
        let f = Fixture()
        let s = SidebarViewController(manager: f.manager)
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 280, height: height), styleMask: [.borderless],
                         backing: .buffered, defer: false)
        w.isReleasedWhenClosed = false
        w.contentView = s.view
        settle(w)
        return (f, s, w)
    }

    func settle(_ w: NSWindow) {
        w.contentView?.layoutSubtreeIfNeeded()
        w.displayIfNeeded()
    }

    func row(_ s: SidebarViewController, _ kind: Kind) -> Int { s.outline.row(forItem: s.node(kind)) }

    func cell<T>(_ s: SidebarViewController, _ kind: Kind, as: T.Type = T.self) -> T? {
        let r = row(s, kind)
        return r >= 0 ? s.outline.view(atColumn: 0, row: r, makeIfNecessary: false) as? T : nil
    }

    func rowView(_ s: SidebarViewController, _ kind: Kind) -> SidebarRowView? {
        let r = row(s, kind)
        return r >= 0 ? s.outline.rowView(atRow: r, makeIfNecessary: false) as? SidebarRowView : nil
    }

    /// The outline's items in display order.
    func shownItems(_ s: SidebarViewController) -> [Kind] {
        (0..<s.outline.numberOfRows).compactMap { (s.outline.item(atRow: $0) as? SidebarNode)?.kind }
    }

    /// What the outline should show for the model and its expansion state.
    func expectedItems(_ s: SidebarViewController) -> [Kind] {
        var out: [Kind] = []
        func walk(_ list: [SidebarNode]) {
            for n in list {
                out.append(n.kind)
                if s.outline.isItemExpanded(n) { walk(n.children) }
            }
        }
        walk(s.roots)
        return out
    }

    /// Per-parent pure inserts / removes, the shape the real diff emits for those cases.
    static func naivePlan(old: SidebarViewController.Snapshot, new: SidebarViewController.Snapshot)
        -> SidebarDiff.Plan<Kind> {
        var ops: [SidebarDiff.Op<Kind>] = []
        for (parent, list) in new {
            guard let before = old[parent] else { continue }
            for (i, k) in before.enumerated() where !list.contains(k) { ops.append(.remove(parent: parent, index: i)) }
            for (i, k) in list.enumerated() where !before.contains(k) { ops.append(.insert(parent: parent, index: i)) }
        }
        return .ops(ops)
    }

    @Test func rowsForFoldersSessionsClosedAndBackground() {
        let (f, s) = make()
        defer { f.cleanup() }
        let folder = f.manager.newFolder(name: "Infra", directory: "/repo")
        f.manager.newSession(agent: .claude, cwd: f.dir.path, folder: .some(folder))
        let inFolder = f.selected!
        f.manager.newSession(agent: .claude, cwd: f.dir.path, folder: .some(nil))
        let closed = f.selected!
        f.manager.close(closed)
        f.manager.applyBackground([BackgroundAgent(id: "j1", sessionId: "s", name: "Job", cwd: "/", state: "blocked", needs: "go")])
        f.effects.active = false
        f.manager.apply(.hook(HookEvent(agent: .claude, event: "PermissionRequest", message: "Allow Bash?")), to: inFolder)

        let o = s.outline
        #expect(s.roots.count == 3)
        for row in 0..<o.numberOfRows {
            _ = o.view(atColumn: 0, row: row, makeIfNecessary: true)
            _ = s.outlineView(o, heightOfRowByItem: o.item(atRow: row)!)
            _ = s.outlineView(o, shouldSelectItem: o.item(atRow: row)!)
        }
        o.expandItem(s.node(.closedHeader))
        let folderNode = s.node(.folder(folder))
        let folderCell = s.outlineView(o, viewFor: nil, item: folderNode) as? FolderRowView
        #expect(folderCell?.badge.stringValue == "1")
        let cell = s.outlineView(o, viewFor: nil, item: s.node(.session(inFolder))) as? SessionRowView
        #expect(cell?.subtitle.stringValue == "Allow Bash?")
        #expect(cell?.agentGlyph.toolTip == "Claude")
        #expect(cell?.time.stringValue == "now")
        let closedCell = s.outlineView(o, viewFor: nil, item: s.node(.closed(closed))) as? CompactRowView
        #expect(closedCell?.title.stringValue.isEmpty == false)
        let bgCell = s.outlineView(o, viewFor: nil, item: s.node(.background("j1"))) as? CompactRowView
        #expect(bgCell?.title.stringValue == "Job")
        #expect(bgCell?.trailing.stringValue == "BLOCKED")
        let header = s.outlineView(o, viewFor: nil, item: s.node(.closedHeader)) as? SectionHeaderView
        #expect(header?.title.stringValue == "CLOSED")
        #expect(header?.countLabel.stringValue == "1")
        #expect(header?.accessibilityLabel() == "Closed, 1 session")
        let bgHeader = s.outlineView(o, viewFor: nil, item: s.node(.backgroundHeader)) as? SectionHeaderView
        #expect(bgHeader?.accessibilityLabel() == "Background, 1 agent")
        #expect(s.outlineView(o, isGroupItem: s.node(.closedHeader)))
        #expect(!s.outlineView(o, isItemExpandable: s.node(.session(inFolder))))
        #expect(!s.outlineView(o, shouldSelectItem: s.node(.closedHeader)))
        #expect(s.outlineView(o, heightOfRowByItem: s.node(.session(inFolder))) == 38)
        #expect(s.outlineView(o, heightOfRowByItem: folderNode) == 28)
        #expect(s.outlineView(o, heightOfRowByItem: s.node(.closedHeader)) == 30)
        #expect(s.outlineView(o, heightOfRowByItem: s.node(.closed(closed))) == 26)

        // Row views carry the row kind and the attention tone.
        let rv = s.outlineView(o, rowViewForItem: s.node(.session(inFolder))) as? SidebarRowView
        #expect(rv?.kind == .session)
        #expect(rv?.tone == .attention)
        #expect((s.outlineView(o, rowViewForItem: s.node(.closedHeader)) as? SidebarRowView)?.kind == .header)
        #expect((s.outlineView(o, rowViewForItem: s.node(.background("j1"))) as? SidebarRowView)?.tone == .attention)
        #expect((s.outlineView(o, rowViewForItem: folderNode) as? SidebarRowView)?.kind == .folder)
        #expect((s.outlineView(o, rowViewForItem: s.node(.closed(closed))) as? SidebarRowView)?.kind == .compact)
    }

    @Test func subtitlesFollowActivity() {
        let (f, s) = make()
        defer { f.cleanup() }
        f.manager.newSession(agent: .claude, cwd: f.dir.path)
        let id = f.selected!
        func row() -> SessionRowView? {
            s.outlineView(s.outline, viewFor: nil, item: s.node(.session(id))) as? SessionRowView
        }
        func subtitle() -> String { row()?.subtitle.stringValue ?? "" }
        // Direct launch: "Starting…" until the agent shows, then the directory. VoiceOver says the same.
        #expect(subtitle() == "Starting…")
        #expect(row()?.accessibilityLabel()?.hasSuffix(", Starting") == true)
        f.manager.launchReady(id)
        #expect(row()?.accessibilityLabel()?.hasSuffix(", Idle") == true)
        // Temp directories collapse to their leaf.
        #expect(subtitle() == RelativeTime.compactPath(f.dir.path))
        #expect(subtitle() == f.dir.lastPathComponent)
        f.manager.apply(.hook(HookEvent(agent: .claude, event: "UserPromptSubmit")), to: id)
        #expect(subtitle() == "Working")
        f.effects.active = false
        f.manager.apply(.hook(HookEvent(agent: .claude, event: "Stop")), to: id)
        #expect(subtitle() == "Done")
        f.manager.apply(.hook(HookEvent(agent: .claude, event: "StopFailure", message: "rate limited")), to: id)
        #expect(subtitle() == "rate limited")
        f.manager.apply(.processExited, to: id)
        #expect(subtitle() == "Exited")
        f.manager.apply(.hook(HookEvent(agent: .claude, event: "PermissionRequest")), to: id)
        #expect(subtitle() == "Permission needed")

        // Without hooks a bare terminal notification still shows clearly.
        f.manager.newSession(agent: .shell, cwd: f.dir.path)
        let plain = f.selected!
        f.manager.apply(.foregroundProcess(.claude), to: plain)
        f.manager.apply(.desktopNotification(title: "", body: ""), to: plain)
        let cell = s.outlineView(s.outline, viewFor: nil, item: s.node(.session(plain))) as? SessionRowView
        #expect(cell?.subtitle.stringValue == "Waiting for your input")
    }

    @Test func selectingRowsDrivesManagerAndPreviews() {
        let (f, s) = make()
        defer { f.cleanup() }
        final class Spy: SidebarDelegate {
            var closed: UUID?
            var bg: String?
            var focus = 0
            func sidebarShowClosed(_ id: UUID) { closed = id }
            func sidebarShowBackground(_ agent: BackgroundAgent) { bg = agent.id }
            func sidebarFocusTerminal() { focus += 1 }
        }
        let spy = Spy()
        s.delegate = spy
        f.manager.newSession(agent: .shell, cwd: f.dir.path)
        let a = f.selected!
        f.manager.newSession(agent: .claude, cwd: f.dir.path)
        let b = f.selected!
        f.manager.close(b)
        f.manager.applyBackground([BackgroundAgent(id: "j1", sessionId: "s", name: "Job", cwd: "/", state: "working")])
        s.outline.expandItem(s.node(.closedHeader))

        s.outline.selectRowIndexes([s.outline.row(forItem: s.node(.closed(b)))], byExtendingSelection: false)
        #expect(spy.closed == b)
        // A background refresh keeps the closed preview selected.
        f.manager.applyBackground(f.manager.background)
        #expect(s.outline.item(atRow: s.outline.selectedRow) as? SidebarNode === s.node(.closed(b)))
        s.outline.selectRowIndexes([s.outline.row(forItem: s.node(.background("j1")))], byExtendingSelection: false)
        #expect(spy.bg == "j1")
        s.outline.selectRowIndexes([s.outline.row(forItem: s.node(.session(a)))], byExtendingSelection: false)
        #expect(f.selected == a)
        #expect(!f.manager.selectionWantsFocus, "keyboard selection keeps focus in the list")
    }

    @Test func dragAndDrop() {
        let (f, s) = make()
        defer { f.cleanup() }
        let o = s.outline
        let folder = f.manager.newFolder(name: "F")
        let inner = f.manager.newFolder(name: "Inner", in: folder)
        f.manager.newSession(agent: .shell, cwd: f.dir.path, folder: .some(nil))
        let a = f.selected!
        f.manager.newSession(agent: .claude, cwd: f.dir.path, folder: .some(nil))
        let b = f.selected!
        f.manager.close(b)

        // Session into folder.
        var drag = FakeDrag(token: "s:\(a.uuidString)")
        #expect(s.outlineView(o, validateDrop: drag, proposedItem: s.node(.folder(folder)), proposedChildIndex: -1) == .move)
        #expect(s.outlineView(o, acceptDrop: drag, item: s.node(.folder(folder)), childIndex: -1))
        #expect(f.manager.workspace.children(of: folder).contains { $0.id == a })

        // Drop on a session lands after it; root drops clamp before the sections.
        _ = s.outlineView(o, validateDrop: drag, proposedItem: s.node(.session(a)), proposedChildIndex: -1)
        _ = s.outlineView(o, validateDrop: drag, proposedItem: nil, proposedChildIndex: 99)
        #expect(s.outlineView(o, acceptDrop: drag, item: nil, childIndex: 0))
        #expect(f.manager.workspace.tree.first?.id == a)

        // Folder into its own child is refused.
        drag = FakeDrag(token: "f:\(folder.uuidString)")
        #expect(s.outlineView(o, validateDrop: drag, proposedItem: s.node(.folder(inner)), proposedChildIndex: -1) == [])
        // Nothing can be dropped onto section headers.
        #expect(s.outlineView(o, validateDrop: drag, proposedItem: s.node(.closedHeader), proposedChildIndex: -1) == [])
        #expect(!s.outlineView(o, acceptDrop: drag, item: s.node(.closedHeader), childIndex: 0))

        // Closed session dragged into the tree reopens there.
        drag = FakeDrag(token: "c:\(b.uuidString)")
        #expect(s.outlineView(o, acceptDrop: drag, item: s.node(.folder(inner)), childIndex: 0))
        #expect(f.manager.live[b] != nil)
        #expect(f.manager.workspace.children(of: inner).first?.id == b)

        #expect(!s.outlineView(o, acceptDrop: FakeDrag(token: "junk"), item: nil, childIndex: 0))
        #expect(s.outlineView(o, pasteboardWriterForItem: s.node(.session(a))) != nil)
        #expect(s.outlineView(o, pasteboardWriterForItem: s.node(.folder(folder))) != nil)
        #expect(s.outlineView(o, pasteboardWriterForItem: s.node(.closedHeader)) == nil)
    }

    @Test func contextMenusAndActions() {
        let (f, s) = make()
        defer { f.cleanup() }
        var prompts: [String] = []
        Presenter.alert = { alert, _, done in
            prompts.append(alert.messageText)
            (alert.accessoryView as? NSTextField)?.stringValue = "Named"
            done(.alertFirstButtonReturn)
        }
        let folder = f.manager.newFolder(name: "F", directory: "/x")
        f.manager.newSession(agent: .claude, cwd: f.dir.path, folder: .some(nil), agentSessionId: "sid")
        let a = f.selected!
        f.manager.newSession(agent: .claude, cwd: f.dir.path, folder: .some(nil))
        let b = f.selected!
        f.manager.close(b)
        f.manager.applyBackground([BackgroundAgent(id: "j1", sessionId: "s", name: "Job", cwd: "/", state: "working")])

        let menu = NSMenu()
        func titles(_ node: SidebarNode?) -> [String] {
            s.populate(menu, for: node)
            return menu.items.map(\.title)
        }
        #expect(titles(nil).contains("New Folder"))
        #expect(titles(s.node(.session(a))).contains("Copy Resume Command"))
        #expect(titles(s.node(.folder(folder))).contains("Clear Default Directory"))
        #expect(titles(s.node(.closed(b))).contains("Reopen"))
        #expect(titles(s.node(.closedHeader)).count == 1)
        #expect(titles(s.node(.background("j1"))) == ["Attach in New Session"])
        #expect(titles(s.node(.backgroundHeader)) == ["Refresh"])

        func run(_ title: String, on node: SidebarNode?, sub: String? = nil) {
            s.populate(menu, for: node)
            var item = menu.items.first { $0.title == title }!
            if let sub { item = item.submenu!.items.first { $0.title == sub }! }
            _ = (item.target as AnyObject?)?.perform(item.action, with: item)
        }
        run("Copy Resume Command", on: s.node(.session(a)))
        #expect(NSPasteboard.general.string(forType: .string) == "claude --resume sid")
        run("Move to Folder", on: s.node(.session(a)), sub: "F")
        #expect(f.manager.workspace.parent(of: a) == .some(folder))
        run("Move to Folder", on: s.node(.session(a)), sub: "Top Level")
        #expect(f.manager.workspace.parent(of: a) == .some(nil))
        run("Move to Folder", on: s.node(.session(a)), sub: "New Folder…")
        #expect(f.manager.workspace.folders.values.contains { $0.name == "Named" })
        run("Rename…", on: s.node(.session(a)))
        #expect(f.manager.workspace.sessions[a]?.customName == "Named")
        run("Default Folder for New", on: s.node(.folder(folder)), sub: "Claude Code Sessions")
        #expect(f.manager.workspace.defaults(for: .claude).folder == folder)
        run("Default Folder for New", on: s.node(.folder(folder)), sub: "Claude Code Sessions")
        #expect(f.manager.workspace.defaults(for: .claude).folder == nil)
        run("Clear Default Directory", on: s.node(.folder(folder)))
        #expect(f.manager.workspace.folders[folder]?.directory == nil)
        run("New Shell Here", on: s.node(.folder(folder)))
        run("New Claude Session Here", on: s.node(.folder(folder)))
        #expect(f.manager.workspace.children(of: folder).count == 2)
        run("New Subfolder", on: s.node(.folder(folder)))
        run("Reopen", on: s.node(.closed(b)))
        #expect(f.manager.live[b] != nil)
        f.manager.close(b)
        run("Remove from List", on: s.node(.closed(b)))
        #expect(f.manager.workspace.sessions[b] == nil)
        run("Attach in New Session", on: s.node(.background("j1")))
        run("Refresh", on: s.node(.backgroundHeader))
        run("Close Session", on: s.node(.session(a)))
        run("Delete Folder (keep sessions)", on: s.node(.folder(folder)))
        #expect(f.manager.workspace.folders[folder] == nil)
        run("New Folder", on: nil)
        s.promptRename(f.manager.workspace.folders.keys.first!)
        #expect(prompts.count >= 4)
    }

    @Test func expansionIsRemembered() {
        let (f, s) = make()
        defer { f.cleanup() }
        let folder = f.manager.newFolder(name: "F")
        f.manager.newSession(agent: .shell, cwd: f.dir.path, folder: .some(folder))
        s.outline.collapseItem(s.node(.folder(folder)))
        #expect(f.manager.workspace.folders[folder]?.expanded == false)
        s.outline.expandItem(s.node(.folder(folder)))
        #expect(f.manager.workspace.folders[folder]?.expanded == true)
        #expect(s.selectedFolder == nil)
        s.outline.selectRowIndexes([s.outline.row(forItem: s.node(.folder(folder)))], byExtendingSelection: false)
        #expect(s.selectedFolder == folder)
    }

    @Test func integrationBannerFollowsStatus() throws {
        let (f, s) = make()
        defer { f.cleanup() }
        #expect(!s.banner.isHidden)
        #expect(s.banner.label.stringValue.contains("Claude"))
        #expect(s.banner.button.action == #selector(AppDelegate.installIntegrations(_:)))
        try Integrations.installOpenCode(pluginDir: f.env.integrationPaths.opencodePluginDir)
        f.manager.refreshIntegrations()
        #expect(!s.banner.isHidden)
        #expect(s.banner.missing == ["Claude", "PI"])
        try Integrations.installPi(extensionDir: f.env.integrationPaths.piExtensionDir)
        _ = try Integrations.installClaude(settingsURL: f.env.integrationPaths.claudeSettings)
        f.manager.refreshIntegrations()
        #expect(s.banner.isHidden)
    }

    // MARK: Update paths (§4.4)

    @Test func statusChangesReconfigureVisibleRowsInPlace() {
        let (f, s, w) = makeWindowed()
        defer { f.cleanup() }
        let folder = f.manager.newFolder(name: "F")
        f.manager.newSession(agent: .claude, cwd: f.dir.path, folder: .some(folder))
        let id = f.selected!
        f.manager.newSession(agent: .shell, cwd: f.dir.path, folder: .some(nil))
        settle(w)
        let reloads = s.outline.reloadCount
        let before = cell(s, .session(id), as: SessionRowView.self)
        #expect(before != nil)
        f.effects.active = false
        f.manager.apply(.hook(HookEvent(agent: .claude, event: "PermissionRequest", message: "Allow?")), to: id)
        let after = cell(s, .session(id), as: SessionRowView.self)
        #expect(after === before, "status never swaps the cell")
        #expect(after?.subtitle.stringValue == "Allow?")
        #expect(after?.title.font == Fonts.rowTitleStrong)
        #expect(rowView(s, .session(id))?.tone == .attention)
        #expect(cell(s, .folder(folder), as: FolderRowView.self)?.badge.stringValue == "1")
        #expect(s.waiting.contains(.session(id)))
        #expect(s.outline.reloadCount == reloads, "no reloadData for status")

        f.manager.apply(.hook(HookEvent(agent: .claude, event: "UserPromptSubmit")), to: id)
        #expect(cell(s, .session(id), as: SessionRowView.self)?.subtitle.stringValue == "Working")
        #expect(rowView(s, .session(id))?.tone == .plain)
        #expect(cell(s, .folder(folder), as: FolderRowView.self)?.badge.isHidden == true)
        #expect(!s.waiting.contains(.session(id)))

        // A collapsed folder still follows its hidden children: badge, pips, count, pulse.
        s.outline.collapseItem(s.node(.folder(folder)))
        settle(w)
        f.manager.apply(.hook(HookEvent(agent: .claude, event: "PermissionRequest")), to: id)
        let fc = cell(s, .folder(folder), as: FolderRowView.self)
        #expect(fc?.badge.stringValue == "1")
        #expect(fc?.pulsing == true)
        #expect(fc?.countLabel.stringValue == "1")
        #expect(fc?.toolTip == "1 waiting · 1 session")
        s.setLoopsPaused(true)
        #expect(s.loopsPaused)
        #expect(fc?.pulsing == false)
        s.setLoopsPaused(false)
        #expect(fc?.pulsing == true)
        f.manager.apply(.hook(HookEvent(agent: .claude, event: "UserPromptSubmit")), to: id)
        #expect(fc?.pips.colors.count == 1)
        #expect(fc?.pulsing == false)
        #expect(s.outline.reloadCount == reloads)
    }

    @Test func clockRefreshesTimesInPlace() {
        let (f, s, w) = makeWindowed()
        defer { f.cleanup() }
        f.manager.newSession(agent: .claude, cwd: f.dir.path)
        let id = f.selected!
        f.manager.newSession(agent: .claude, cwd: f.dir.path)
        let closed = f.selected!
        f.manager.close(closed)
        s.outline.expandItem(s.node(.closedHeader))
        f.manager.apply(.hook(HookEvent(agent: .claude, event: "UserPromptSubmit")), to: id)
        settle(w)
        let c = cell(s, .session(id), as: SessionRowView.self)
        #expect(c?.time.stringValue == "now")
        let reloads = s.outline.reloadCount
        s.refreshClock(now: Date().addingTimeInterval(600))
        #expect(c?.time.stringValue == "10m")
        #expect(cell(s, .session(id), as: SessionRowView.self) === c)
        #expect(cell(s, .closed(closed), as: CompactRowView.self)?.trailing.stringValue == "10m")
        #expect(s.outline.reloadCount == reloads)
    }

    @Test func plannedOpsAnimateWithoutReload() {
        let (f, s, w) = makeWindowed()
        defer { f.cleanup() }
        // Planned ops run only where they can animate.
        let visible = Motion.assumeVisible
        Motion.assumeVisible = true
        defer { Motion.assumeVisible = visible }
        let folder = f.manager.newFolder(name: "F")
        f.manager.newSession(agent: .shell, cwd: f.dir.path, folder: .some(folder))
        f.manager.newSession(agent: .shell, cwd: f.dir.path, folder: .some(nil))
        settle(w)
        s.planner = { Self.naivePlan(old: $0, new: $1) }
        let reloads = s.outline.reloadCount

        // Pure insert at the root and inside an expanded folder.
        f.manager.newSession(agent: .claude, cwd: f.dir.path, folder: .some(nil))
        let added = f.selected!
        f.manager.newSession(agent: .shell, cwd: f.dir.path, folder: .some(folder))
        #expect(shownItems(s) == expectedItems(s))
        #expect(s.outline.reloadCount == reloads)
        #expect(f.selected.map { row(s, .session($0)) } == s.outline.selectedRow)

        // A new folder arrives expanded (non-animated expansion of inserted folders).
        let sub = f.manager.newFolder(name: "Sub")
        f.manager.newSession(agent: .shell, cwd: f.dir.path, folder: .some(sub))
        #expect(s.outline.isItemExpanded(s.node(.folder(sub))))
        #expect(shownItems(s) == expectedItems(s))

        // Pure remove (forget a closed one is a reload-shaped change; delete a folder is a remove + inserts).
        f.manager.move(added, to: folder, at: 0)
        #expect(shownItems(s) == expectedItems(s))

        // Changes inside a collapsed folder reload that folder only.
        s.outline.collapseItem(s.node(.folder(folder)))
        f.manager.newSession(agent: .shell, cwd: f.dir.path, folder: .some(folder))
        #expect(shownItems(s) == expectedItems(s))
        s.outline.expandItem(s.node(.folder(folder)))
        #expect(shownItems(s) == expectedItems(s))
        #expect(s.outline.reloadCount == reloads, "every structural change above went through ops")

        // Renames are an empty plan: cells update in place.
        f.manager.rename(added, to: "Renamed")
        #expect(cell(s, .session(added), as: SessionRowView.self)?.title.stringValue == "Renamed")
        #expect(s.outline.reloadCount == reloads)
    }

    @Test func singleMoveUsesMoveItem() {
        let (f, s, w) = makeWindowed()
        defer { f.cleanup() }
        // Planned ops run only where they can animate.
        let visible = Motion.assumeVisible
        Motion.assumeVisible = true
        defer { Motion.assumeVisible = visible }
        let a = f.manager.newFolder(name: "A")
        let b = f.manager.newFolder(name: "B")
        f.manager.newSession(agent: .shell, cwd: f.dir.path, folder: .some(a))
        let moved = f.selected!
        f.manager.newSession(agent: .shell, cwd: f.dir.path, folder: .some(b))
        settle(w)
        let reloads = s.outline.reloadCount
        s.planner = { old, new in
            guard let from = old[.folder(a)]?.firstIndex(of: .session(moved)),
                  let to = new[.folder(b)]?.firstIndex(of: .session(moved)) else { return .reload }
            return .ops([.move(fromParent: .folder(a), from: from, toParent: .folder(b), to: to)])
        }
        f.manager.move(moved, to: b, at: 0)
        #expect(shownItems(s) == expectedItems(s))
        #expect(s.outline.reloadCount == reloads)

        // Into a collapsed folder: removed from the open one, the collapsed one reloads.
        s.outline.collapseItem(s.node(.folder(a)))
        s.planner = { old, new in
            guard let from = old[.folder(b)]?.firstIndex(of: .session(moved)),
                  let to = new[.folder(a)]?.firstIndex(of: .session(moved)) else { return .reload }
            return .ops([.move(fromParent: .folder(b), from: from, toParent: .folder(a), to: to)])
        }
        f.manager.move(moved, to: a, at: 0)
        #expect(shownItems(s) == expectedItems(s))
        s.outline.expandItem(s.node(.folder(a)))
        #expect(shownItems(s) == expectedItems(s))
        #expect(s.outline.reloadCount == reloads)

        // Out of a collapsed folder into an open one.
        s.outline.collapseItem(s.node(.folder(a)))
        s.planner = { old, new in
            guard let from = old[.folder(a)]?.firstIndex(of: .session(moved)),
                  let to = new[.folder(b)]?.firstIndex(of: .session(moved)) else { return .reload }
            return .ops([.move(fromParent: .folder(a), from: from, toParent: .folder(b), to: to)])
        }
        f.manager.move(moved, to: b, at: nil)
        #expect(shownItems(s) == expectedItems(s))
        #expect(s.outline.reloadCount == reloads)

        // A move whose parent is new can't be applied row by row: full reload.
        s.planner = { _, _ in .ops([.move(fromParent: .folder(UUID()), from: 0, toParent: nil, to: 0)]) }
        f.manager.move(moved, to: nil, at: 0)
        #expect(s.outline.reloadCount == reloads + 1)
        #expect(shownItems(s) == expectedItems(s))
    }

    @Test func wrongPlansFallBackToReload() {
        let (f, s, w) = makeWindowed()
        defer { f.cleanup() }
        // Planned ops run only where they can animate.
        let visible = Motion.assumeVisible
        Motion.assumeVisible = true
        defer { Motion.assumeVisible = visible }
        f.manager.newSession(agent: .shell, cwd: f.dir.path)
        settle(w)
        // An empty plan for a real insert leaves the outline short: detected, full reload.
        s.planner = { _, _ in .ops([]) }
        let reloads = s.outline.reloadCount
        f.manager.newSession(agent: .shell, cwd: f.dir.path)
        #expect(s.outline.reloadCount == reloads + 1)
        #expect(shownItems(s) == expectedItems(s))
        // Out-of-range indexes never reach AppKit.
        s.planner = { _, _ in .ops([.insert(parent: nil, index: 99)]) }
        f.manager.newSession(agent: .shell, cwd: f.dir.path)
        #expect(s.outline.reloadCount == reloads + 2)
        s.planner = { _, _ in .ops([.remove(parent: nil, index: -1)]) }
        f.manager.newSession(agent: .shell, cwd: f.dir.path)
        s.planner = { _, _ in .ops([.move(fromParent: nil, from: 50, toParent: nil, to: 0)]) }
        f.manager.newSession(agent: .shell, cwd: f.dir.path)
        #expect(s.outline.reloadCount == reloads + 4)
        #expect(shownItems(s) == expectedItems(s))
        // The real planner's `.reload` keeps today's path.
        s.planner = { _, _ in .reload }
        f.manager.newSession(agent: .shell, cwd: f.dir.path)
        #expect(s.outline.reloadCount == reloads + 5)
        #expect(shownItems(s) == expectedItems(s))
    }

    // MARK: Hover, clicks, headers

    @Test func hoverSwapsTrailingAccessories() {
        let (f, s, w) = makeWindowed()
        defer { f.cleanup() }
        let folder = f.manager.newFolder(name: "F")
        f.manager.newSession(agent: .claude, cwd: f.dir.path, folder: .some(folder))
        let id = f.selected!
        f.manager.newSession(agent: .claude, cwd: f.dir.path)
        let closed = f.selected!
        f.manager.close(closed)
        f.manager.apply(.hook(HookEvent(agent: .claude, event: "UserPromptSubmit")), to: id)
        s.outline.expandItem(s.node(.closedHeader))
        settle(w)

        let sr = row(s, .session(id))
        s.outline.setHoveredRow(sr, animated: false)
        let sc = cell(s, .session(id), as: SessionRowView.self)
        #expect(rowView(s, .session(id))?.hovered == true)
        #expect(sc?.closeButton.alphaValue == 1)
        #expect(sc?.time.alphaValue == 0)
        // The × takes clicks only while shown.
        let center = NSPoint(x: sc!.closeButton.frame.midX, y: sc!.closeButton.frame.midY)
        #expect(sc?.hitTest(sc!.convert(center, to: sc!.superview)) === sc?.closeButton)

        s.outline.setHoveredRow(row(s, .folder(folder)), animated: false)
        #expect(sc?.closeButton.alphaValue == 0)
        #expect(sc?.time.alphaValue == 1)
        #expect(sc?.hitTest(sc!.convert(center, to: sc!.superview)) === sc)
        let fc = cell(s, .folder(folder), as: FolderRowView.self)
        #expect(fc?.title.textColor == Theme.ramp(.chrome).primary)

        s.outline.setHoveredRow(row(s, .closedHeader), animated: false)
        #expect(cell(s, .closedHeader, as: SectionHeaderView.self)?.chevron.alphaValue == 1)
        #expect(fc?.title.textColor == Theme.ramp(.chrome).secondary)

        s.outline.setHoveredRow(row(s, .closed(closed)), animated: false)
        let cc = cell(s, .closed(closed), as: CompactRowView.self)
        #expect(cc?.reopenButton.alphaValue == 1)
        #expect(cc?.trailing.alphaValue == 0)
        let reopenCenter = NSPoint(x: cc!.reopenButton.frame.midX, y: cc!.reopenButton.frame.midY)
        #expect(cc?.hitTest(cc!.convert(reopenCenter, to: cc!.superview)) === cc?.reopenButton)

        // An unchanged tree reconfigures in place: hover survives.
        let reloads = s.outline.reloadCount
        s.reload()
        #expect(s.outline.reloadCount == reloads)
        #expect(s.outline.hoveredRow == row(s, .closed(closed)))
        #expect(cc?.reopenButton.alphaValue == 1)
        // A full reload clears hover on every row; the pointer is not over the (non-key) window, so nothing comes back.
        s.planner = { _, _ in .reload }
        f.manager.newSession(agent: .shell, cwd: f.dir.path)
        #expect(s.outline.reloadCount == reloads + 1)
        #expect(s.outline.hoveredRow == -1)
        settle(w)
        s.outline.enumerateAvailableRowViews { rv, _ in #expect((rv as? SidebarRowView)?.hovered == false) }
        #expect(cell(s, .closed(closed), as: CompactRowView.self)?.reopenButton.alphaValue == 0)
        s.outline.refreshHoverFromMouse()
        #expect(s.outline.hoveredRow == -1)

        // Row buttons route through the same paths as the menus (busy agents ask first).
        settle(w)
        s.closeRowClicked(cell(s, .session(id), as: SessionRowView.self)!.closeButton)
        #expect(f.ui.confirms.count == 1)
        #expect(f.manager.live[id] == nil)
        settle(w)
        if let cc2 = cell(s, .closed(closed), as: CompactRowView.self) {
            s.reopenRowClicked(cc2.reopenButton)
            #expect(f.manager.live[closed] != nil)
        }
    }

    @Test func headerClicksAndChevronsToggle() throws {
        let defaults = UserDefaults.standard
        let saved = defaults.object(forKey: "sidebar.closed.expanded")
        defer { defaults.set(saved, forKey: "sidebar.closed.expanded") }
        defaults.set(false, forKey: "sidebar.closed.expanded")
        let (f, s, w) = makeWindowed()
        defer { f.cleanup() }
        let folder = f.manager.newFolder(name: "F")
        f.manager.newSession(agent: .shell, cwd: f.dir.path, folder: .some(folder))
        f.manager.newSession(agent: .claude, cwd: f.dir.path)
        f.manager.close(f.selected!)
        settle(w)
        let header = s.node(.closedHeader)
        #expect(!s.outline.isItemExpanded(header))
        s.handleClick(row: row(s, .closedHeader))
        settle(w)  // without animation a toggle rebuilds the rows; cells come with the next layout
        #expect(s.outline.isItemExpanded(header))
        #expect(defaults.bool(forKey: "sidebar.closed.expanded"))
        #expect(cell(s, .closedHeader, as: SectionHeaderView.self)?.chevron.expanded == true)
        s.handleClick(row: row(s, .closedHeader))
        #expect(!s.outline.isItemExpanded(header))
        #expect(!defaults.bool(forKey: "sidebar.closed.expanded"))
        // Clicks on other rows never toggle; headers are never selected.
        s.handleClick(row: row(s, .folder(folder)))
        s.handleClick(row: -1)
        #expect(s.outline.isItemExpanded(s.node(.folder(folder))))

        // A click on the selected session puts the keyboard in its terminal (no selection change does).
        final class Focus: SidebarDelegate {
            var count = 0
            func sidebarShowClosed(_ id: UUID) {}
            func sidebarShowBackground(_ agent: BackgroundAgent) {}
            func sidebarFocusTerminal() { count += 1 }
        }
        let spy = Focus()
        s.delegate = spy
        f.manager.newSession(agent: .shell, cwd: f.dir.path)
        settle(w)
        let selected = try #require(f.manager.workspace.selected)
        s.handleClick(row: row(s, .session(selected)))
        #expect(spy.count == 1)
        let other = try #require(f.manager.workspace.openSessionsInOrder.first { $0 != selected })
        s.handleClick(row: row(s, .session(other)))
        #expect(spy.count == 1)

        let fc = cell(s, .folder(folder), as: FolderRowView.self)!
        #expect(fc.disclosure.chevron.expanded)
        s.disclosureClicked(fc.disclosure)
        settle(w)
        #expect(!s.outline.isItemExpanded(s.node(.folder(folder))))
        #expect(f.manager.workspace.folders[folder]?.expanded == false)
        #expect(cell(s, .folder(folder), as: FolderRowView.self)?.disclosure.chevron.expanded == false)
        // The chevron's hit target reaches past the cell's leading edge.
        let left = NSPoint(x: fc.frame.minX - 3, y: fc.frame.midY)
        #expect(fc.hitTest(left) === fc.disclosure)
        s.toggle(s.node(.folder(folder)), animated: false)
        #expect(s.outline.isItemExpanded(s.node(.folder(folder))))
    }

    /// Group rows restyle a cell's `textField` outlet (system font and label color); the header keeps its own.
    @Test func hostedHeaderKeepsSectionStyle() {
        let (f, s, w) = makeWindowed()
        defer { f.cleanup() }
        f.manager.newSession(agent: .claude, cwd: f.dir.path)
        f.manager.close(f.selected!)
        f.manager.applyBackground([BackgroundAgent(id: "j1", sessionId: "s", name: "Job", cwd: "/", state: "working")])
        settle(w)
        for kind in [Kind.closedHeader, .backgroundHeader] {
            let h = cell(s, kind, as: SectionHeaderView.self)
            #expect(h != nil)
            let attrs = h?.title.attributedStringValue.attributes(at: 0, effectiveRange: nil) ?? [:]
            #expect(attrs[.foregroundColor] as? NSColor == Theme.ramp(.chrome).tertiary)
            #expect(attrs[.font] as? NSFont == Fonts.section)
            #expect(h?.textField == nil)
        }
        #expect(cell(s, .closedHeader, as: SectionHeaderView.self)?.title.stringValue == "CLOSED")
    }

    @Test func unchangedTreeUpdatesInPlace() {
        let (f, s, w) = makeWindowed()
        defer { f.cleanup() }
        // Planned ops run only where they can animate.
        let visible = Motion.assumeVisible
        Motion.assumeVisible = true
        defer { Motion.assumeVisible = visible }
        f.manager.newSession(agent: .shell, cwd: f.dir.path)
        let id = f.selected!
        f.manager.applyBackground([BackgroundAgent(id: "j1", sessionId: "s", name: "Job", cwd: "/", state: "working")])
        settle(w)
        // Whatever the planner says, an identical tree never reaches it.
        var planned = 0
        s.planner = { _, _ in planned += 1; return .reload }
        let reloads = s.outline.reloadCount
        let c = cell(s, .background("j1"), as: CompactRowView.self)
        f.manager.applyBackground(f.manager.background)
        f.manager.applyBackground([BackgroundAgent(id: "j1", sessionId: "s", name: "Job 2", cwd: "/", state: "blocked", needs: "go")])
        f.manager.rename(id, to: "Renamed")
        #expect(s.outline.reloadCount == reloads)
        #expect(planned == 0)
        #expect(cell(s, .background("j1"), as: CompactRowView.self) === c)
        #expect(c?.title.stringValue == "Job 2")
        #expect(rowView(s, .background("j1"))?.tone == .attention)
        #expect(s.waiting.contains(.background("j1")))
        #expect(cell(s, .session(id), as: SessionRowView.self)?.title.stringValue == "Renamed")
        // A real change still goes through the planner.
        f.manager.newSession(agent: .shell, cwd: f.dir.path)
        #expect(planned == 1)
        #expect(s.outline.reloadCount == reloads + 1)
    }

    @Test func plannedOpsDropStaleHover() {
        let (f, s, w) = makeWindowed()
        defer { f.cleanup() }
        // Planned ops run only where they can animate.
        let visible = Motion.assumeVisible
        Motion.assumeVisible = true
        defer { Motion.assumeVisible = visible }
        let folder = f.manager.newFolder(name: "F")
        f.manager.newSession(agent: .shell, cwd: f.dir.path, folder: .some(folder))
        let inner = f.selected!
        f.manager.newSession(agent: .shell, cwd: f.dir.path, folder: .some(nil))
        let other = f.selected!
        settle(w)
        s.planner = { Self.naivePlan(old: $0, new: $1) }
        let reloads = s.outline.reloadCount
        s.outline.setHoveredRow(row(s, .session(inner)), animated: false)
        #expect(cell(s, .session(inner), as: SessionRowView.self)?.hovered == true)
        // An insert above shifts every row below it: no row keeps a hover the pointer never gave it.
        f.manager.move(other, to: folder, at: 0)
        #expect(s.outline.reloadCount == reloads)
        #expect(shownItems(s) == expectedItems(s))
        #expect(s.outline.hoveredRow == -1)
        settle(w)
        s.outline.enumerateAvailableRowViews { rv, _ in #expect((rv as? SidebarRowView)?.hovered == false) }
        #expect(cell(s, .session(inner), as: SessionRowView.self)?.hovered == false)
        #expect(cell(s, .session(inner), as: SessionRowView.self)?.closeButton.alphaValue == 0)
    }

    @Test func pauseNeverLeaksThroughReuse() {
        let (f, s, w) = makeWindowed()
        defer { f.cleanup() }
        s.planner = { _, _ in .reload }
        f.effects.active = false
        var folders: [UUID] = []
        for i in 0..<3 {
            let folder = f.manager.newFolder(name: "F\(i)")
            f.manager.newSession(agent: .claude, cwd: f.dir.path, folder: .some(folder))
            folders.append(folder)
        }
        settle(w)
        s.setLoopsPaused(true)
        #expect(cell(s, .folder(folders[0]), as: FolderRowView.self)?.loopsPaused == true)
        // Rows leave while paused: their cells go back to the pool still paused.
        f.manager.deleteFolder(folders[1])
        f.manager.deleteFolder(folders[2])
        settle(w)
        s.setLoopsPaused(false)
        // A collapsed folder over a waiting session, dequeued after the resume, pulses.
        let late = f.manager.newFolder(name: "Late")
        f.manager.newSession(agent: .claude, cwd: f.dir.path, folder: .some(late))
        let waitingId = f.selected!
        f.manager.apply(.hook(HookEvent(agent: .claude, event: "PermissionRequest")), to: waitingId)
        s.outline.collapseItem(s.node(.folder(late)))
        settle(w)
        let fc = cell(s, .folder(late), as: FolderRowView.self)
        #expect(fc?.loopsPaused == false)
        #expect(fc?.pulsing == true)
        s.outline.enumerateAvailableRowViews { rv, _ in
            let c = (rv as? SidebarRowView)?.cellView
            if let c = c as? SessionRowView { #expect(!c.loopsPaused) }
            if let c = c as? FolderRowView { #expect(!c.loopsPaused) }
        }
        // Pausing twice is free and resuming restores the pulse.
        s.setLoopsPaused(true)
        s.setLoopsPaused(true)
        #expect(fc?.pulsing == false)
        s.setLoopsPaused(false)
        #expect(fc?.pulsing == true)
    }

    @Test func edgeChipsCountRowsHiddenInCollapsedParents() {
        let defaults = UserDefaults.standard
        let saved = defaults.object(forKey: "sidebar.background.collapsed")
        defer { defaults.set(saved, forKey: "sidebar.background.collapsed") }
        defaults.set(true, forKey: "sidebar.background.collapsed")
        let (f, s, w) = makeWindowed(height: 260)
        defer { f.cleanup() }
        f.effects.active = false
        var ids: [UUID] = []
        for _ in 0..<12 {
            f.manager.newSession(agent: .shell, cwd: f.dir.path, folder: .some(nil))
            ids.append(f.selected!)
        }
        let folder = f.manager.newFolder(name: "Far")
        var hidden: [UUID] = []
        for _ in 0..<2 {
            f.manager.newSession(agent: .claude, cwd: f.dir.path, folder: .some(folder))
            hidden.append(f.selected!)
        }
        s.outline.collapseItem(s.node(.folder(folder)))
        f.manager.applyBackground([BackgroundAgent(id: "j1", sessionId: "s", name: "Job", cwd: "/", state: "blocked", needs: "go")])
        f.manager.select(ids[0])
        s.scroll.contentView.scroll(to: NSPoint(x: 0, y: -4))
        s.scroll.reflectScrolledClipView(s.scroll.contentView)
        settle(w)
        #expect(!s.outline.isItemExpanded(s.node(.backgroundHeader)))
        for id in hidden { f.manager.apply(.hook(HookEvent(agent: .claude, event: "PermissionRequest")), to: id) }
        // Two waiting sessions in one collapsed folder count once; the collapsed section counts once.
        #expect(s.bottomChip.isShown)
        #expect(s.bottomChip.label.stringValue == "↓ 2 waiting")
        #expect(s.chipTargets.below == row(s, .folder(folder)))

        // Reveal: the collapsed folder is selected (its badge pulses there) and stays collapsed.
        s.revealWaiting(above: false)
        settle(w)
        #expect(s.outline.selectedRow == row(s, .folder(folder)))
        #expect(!s.outline.isItemExpanded(s.node(.folder(folder))))
        // A collapsed section: it opens and the waiting agent is selected.
        for id in hidden { f.manager.apply(.hook(HookEvent(agent: .claude, event: "UserPromptSubmit")), to: id) }
        s.scroll.contentView.scroll(to: NSPoint(x: 0, y: -4))
        s.scroll.reflectScrolledClipView(s.scroll.contentView)
        settle(w)
        #expect(s.bottomChip.label.stringValue == "↓ 1 waiting")
        #expect(s.chipTargets.below == row(s, .backgroundHeader))
        s.revealWaiting(above: false)
        settle(w)
        #expect(s.outline.isItemExpanded(s.node(.backgroundHeader)))
        #expect(s.outline.selectedRow == row(s, .background("j1")))
        _ = w
    }

    @Test func clockCatchesUpWhenVisibleAgain() {
        let (f, s, w) = makeWindowed()
        defer { f.cleanup() }
        f.manager.newSession(agent: .claude, cwd: f.dir.path)
        let id = f.selected!
        f.manager.apply(.hook(HookEvent(agent: .claude, event: "UserPromptSubmit")), to: id)
        settle(w)
        let c = cell(s, .session(id), as: SessionRowView.self)
        s.refreshClock(now: Date().addingTimeInterval(600))
        #expect(c?.time.stringValue == "10m")
        // Still occluded: nothing.
        s.occlusionChanged(visible: false)
        NotificationCenter.default.post(name: NSWindow.didChangeOcclusionStateNotification, object: w)
        #expect(c?.time.stringValue == "10m")
        s.occlusionChanged(visible: true)
        #expect(c?.time.stringValue == "now")
        // Resuming loops (window shown / app unhidden) catches up too.
        s.refreshClock(now: Date().addingTimeInterval(600))
        s.setLoopsPaused(true)
        #expect(c?.time.stringValue == "10m")
        s.setLoopsPaused(false)
        #expect(c?.time.stringValue == "now")
        #expect(s.topChip.scrollTarget === s.scroll && s.bottomChip.scrollTarget === s.scroll)
    }

    // MARK: Chrome

    @Test func statuslineCountsAndSegments() {
        let (f, s) = make()
        defer { f.cleanup() }
        let bar = s.bottomBar
        #expect(bar.counts?.total == 0)
        #expect(!bar.totalLabel.isHidden)
        #expect(bar.totalLabel.stringValue == "0 sessions")
        #expect(bar.newFolderButton.action == #selector(MainWindowController.newFolder(_:)))
        f.effects.active = false
        var ids: [UUID] = []
        for _ in 0..<5 {
            f.manager.newSession(agent: .claude, cwd: f.dir.path)
            ids.append(f.selected!)
        }
        #expect(bar.totalLabel.stringValue == "5 sessions")
        f.manager.apply(.hook(HookEvent(agent: .claude, event: "PermissionRequest")), to: ids[0])
        f.manager.apply(.hook(HookEvent(agent: .claude, event: "UserPromptSubmit")), to: ids[1])
        f.manager.apply(.hook(HookEvent(agent: .claude, event: "UserPromptSubmit")), to: ids[2])
        f.manager.apply(.hook(HookEvent(agent: .claude, event: "Stop")), to: ids[2])
        f.manager.apply(.hook(HookEvent(agent: .claude, event: "StopFailure", message: "x")), to: ids[3])
        #expect(bar.counts == SidebarStatusBar.Counts(needsInput: 1, working: 1, doneUnread: 1, error: 1, total: 5))
        #expect(bar.totalLabel.isHidden)
        for seg in SidebarStatusBar.Segment.allCases {
            #expect(bar.buttons[seg]?.isHidden == false)
            #expect(bar.buttons[seg]?.countLabel.stringValue == "1")
        }
        #expect(bar.buttons[.needsInput]?.accessibilityLabel() == "1 waiting for input")

        // Segments cycle through sessions in that state.
        f.manager.select(ids[4])
        s.statusSegmentClicked(.working)
        #expect(f.selected == ids[1])
        s.statusSegmentClicked(.error)
        #expect(f.selected == ids[3])
        f.manager.select(ids[4])
        s.statusSegmentClicked(.done)
        #expect(f.selected == ids[2])
        s.statusSegmentClicked(.needsInput)
        #expect(f.selected == ids[0])
        // The button path goes through the same handler.
        f.manager.select(ids[4])
        bar.segmentClicked(bar.buttons[.working]!)
        #expect(f.selected == ids[1])

        f.manager.apply(.hook(HookEvent(agent: .claude, event: "UserPromptSubmit")), to: ids[0])
        #expect(bar.counts?.needsInput == 0)
        #expect(bar.buttons[.needsInput]?.isHidden == true)
        #expect(bar.buttons[.working]?.countLabel.stringValue == "2")
    }

    @Test func edgeChipsPointAtOffscreenWaitingRows() {
        let (f, s, w) = makeWindowed(height: 260)
        defer { f.cleanup() }
        f.effects.active = false
        var ids: [UUID] = []
        for _ in 0..<14 {
            f.manager.newSession(agent: .claude, cwd: f.dir.path)
            ids.append(f.selected!)
        }
        f.manager.select(ids[0])
        s.scroll.contentView.scroll(to: NSPoint(x: 0, y: -4))
        s.scroll.reflectScrolledClipView(s.scroll.contentView)
        settle(w)
        #expect(!s.topChip.isShown)
        #expect(!s.bottomChip.isShown)
        f.manager.apply(.hook(HookEvent(agent: .claude, event: "PermissionRequest")), to: ids[12])
        #expect(s.bottomChip.isShown)
        #expect(s.bottomChip.label.stringValue == "↓ 1 waiting")
        #expect(s.chipTargets.below == row(s, .session(ids[12])))
        #expect(!s.bottomFade.isHidden)
        #expect(s.topFade.isHidden)

        // Click: scrolls there and selects it with keyboard semantics.
        s.revealWaiting(above: false)
        settle(w)
        #expect(f.selected == ids[12])
        #expect(!f.manager.selectionWantsFocus)
        #expect(!s.bottomChip.isShown)
        #expect(!s.topFade.isHidden)

        // From the bottom, a waiting row at the top shows the up chip.
        f.manager.apply(.hook(HookEvent(agent: .claude, event: "PermissionRequest")), to: ids[0])
        #expect(s.topChip.isShown)
        #expect(s.topChip.label.stringValue == "↑ 1 waiting")
        s.revealWaiting(above: true)
        #expect(f.selected == ids[0])
        // Nothing to reveal is a no-op.
        s.revealWaiting(above: true)
        #expect(f.selected == ids[0])
        // Answering clears the chips.
        for id in [ids[0], ids[12]] { f.manager.apply(.hook(HookEvent(agent: .claude, event: "UserPromptSubmit")), to: id) }
        #expect(!s.topChip.isShown && !s.bottomChip.isShown)
        _ = w
    }

    @Test func commandHintsFollowSelectIndex() {
        let (f, s, w) = makeWindowed(height: 900)
        defer { f.cleanup() }
        var ids: [UUID] = []
        for _ in 0..<11 {
            f.manager.newSession(agent: .shell, cwd: f.dir.path)
            ids.append(f.selected!)
        }
        settle(w)
        func hint(_ id: UUID) -> String? { cell(s, .session(id), as: SessionRowView.self)?.hintText }
        #expect(hint(ids[0]) == nil)
        s.setCommandHeld(true)
        for i in 0..<8 { #expect(hint(ids[i]) == "⌘\(i + 1)") }
        #expect(hint(ids[8]) == nil)
        #expect(hint(ids[9]) == nil)
        #expect(hint(ids[10]) == "⌘9")
        let c0 = cell(s, .session(ids[0]), as: SessionRowView.self)
        #expect(c0?.hint.isHidden == false)
        #expect(c0?.hint.stringValue == "⌘1")
        #expect(c0?.time.alphaValue == 0)
        // The numbers match what ⌘N selects.
        f.manager.selectIndex(Int.max)
        #expect(f.selected == ids[10])
        f.manager.selectIndex(2)
        #expect(f.selected == ids[2])
        // Structure changes renumber while held.
        f.manager.close(ids[0])
        settle(w)
        #expect(hint(ids[1]) == "⌘1")
        // Release (or no key window) hides them.
        s.handleFlagsChanged(NSEvent.keyEvent(with: .flagsChanged, location: .zero, modifierFlags: .command, timestamp: 0,
                                              windowNumber: 0, context: nil, characters: "", charactersIgnoringModifiers: "",
                                              isARepeat: false, keyCode: 55)!)
        #expect(s.commandHints.isEmpty)
        #expect(hint(ids[1]) == nil)
        #expect(c0?.time.alphaValue == 1 || c0?.model?.since == nil)
        s.setCommandHeld(true)
        s.setCommandHeld(false)
        #expect(s.commandHints.isEmpty)

        // Fewer than nine: the last one keeps its own number.
        let (g, t) = make()
        defer { g.cleanup() }
        for _ in 0..<3 { g.manager.newSession(agent: .shell, cwd: g.dir.path) }
        t.setCommandHeld(true)
        #expect(Set(t.commandHints.values) == ["⌘1", "⌘2", "⌘3"])
        let rv = t.outlineView(t.outline, viewFor: nil, item: t.node(.session(g.manager.workspace.openSessionsInOrder[1])))
        #expect((rv as? SessionRowView)?.hintText == "⌘2")
    }

    @Test func themeAndMotionChangesRecolorInPlace() {
        let (f, s, w) = makeWindowed()
        defer {
            Theme.update(background: nil, foreground: nil, windowTheme: nil)
            f.cleanup()
        }
        f.manager.newSession(agent: .claude, cwd: f.dir.path)
        let id = f.selected!
        settle(w)
        let c = cell(s, .session(id), as: SessionRowView.self)
        Theme.update(background: RGB(hex: 0xFDF6E3).color, foreground: RGB(hex: 0x657B83).color, windowTheme: nil)
        #expect(c?.title.textColor == Theme.ramp(.chrome).primary)
        #expect(cell(s, .session(id), as: SessionRowView.self) === c)
        NotificationCenter.default.post(name: .corralMotionChanged, object: nil)
        Theme.update(background: RGB(hex: 0x1E1E2E).color, foreground: RGB(hex: 0xCDD6F4).color, windowTheme: nil)
        #expect(c?.title.textColor == Theme.ramp(.chrome).primary)
        settle(w)
    }

    // MARK: Animated paths (forced: offscreen windows always report occluded)

    @Test func animatedPathsRunHeadless() throws {
        SidebarFX.forceAnimations = true
        defer { SidebarFX.forceAnimations = false }
        let defaults = UserDefaults.standard
        let saved = defaults.object(forKey: "sidebar.closed.expanded")
        defer { defaults.set(saved, forKey: "sidebar.closed.expanded") }
        defaults.set(false, forKey: "sidebar.closed.expanded")
        let (f, s, w) = makeWindowed(height: 320)
        defer { f.cleanup() }
        s.planner = { Self.naivePlan(old: $0, new: $1) }
        let folder = f.manager.newFolder(name: "F")
        f.effects.active = false
        var ids: [UUID] = []
        for _ in 0..<10 {
            f.manager.newSession(agent: .claude, cwd: f.dir.path, folder: .some(folder))
            ids.append(f.selected!)
            settle(w)
        }
        #expect(shownItems(s) == expectedItems(s))
        let reloads = s.outline.reloadCount

        // Status: tone, folder badge appear / increment / decrement / disappear, statusline push + bump.
        let fc = cell(s, .folder(folder), as: FolderRowView.self)
        for id in [ids[0], ids[1]] {
            f.manager.apply(.hook(HookEvent(agent: .claude, event: "PermissionRequest")), to: id)
            rowView(s, .session(id))?.updateLayer()
        }
        #expect(fc?.badge.stringValue == "2")
        #expect(rowView(s, .session(ids[0]))?.state == .attention)
        f.manager.apply(.hook(HookEvent(agent: .claude, event: "UserPromptSubmit")), to: ids[1])
        rowView(s, .session(ids[1]))?.updateLayer()
        #expect(fc?.badge.stringValue == "1")
        f.manager.apply(.hook(HookEvent(agent: .claude, event: "UserPromptSubmit")), to: ids[0])
        #expect(fc?.badge.layer?.animation(forKey: "sidebar.badge.out") != nil, "shrinks out, then hides")
        f.manager.apply(.hook(HookEvent(agent: .claude, event: "PermissionRequest")), to: ids[0])
        #expect(fc?.badge.isHidden == false)
        #expect(s.bottomBar.counts?.needsInput == 1)

        // Hover and selection crossfades on the same items.
        s.outline.setHoveredRow(row(s, .session(ids[2])))
        rowView(s, .session(ids[2]))?.updateLayer()
        s.outline.setHoveredRow(row(s, .session(ids[3])))
        rowView(s, .session(ids[2]))?.updateLayer()
        #expect(rowView(s, .session(ids[2]))?.state == SidebarRowView.FillState.none)
        f.manager.select(ids[2])
        rowView(s, .session(ids[2]))?.updateLayer()
        f.manager.select(ids[3])
        rowView(s, .session(ids[3]))?.updateLayer()
        let rv = rowView(s, .session(ids[3]))
        rv?.isTargetForDropOperation = true
        rv?.updateLayer()
        rv?.isTargetForDropOperation = false
        rv?.flashArrival()
        #expect(rv?.fill.animation(forKey: "sidebar.arrival") != nil)

        // Edge chips show, push and hide; reveal scrolls with the animator.
        f.manager.apply(.hook(HookEvent(agent: .claude, event: "PermissionRequest")), to: ids[9])
        #expect(s.bottomChip.isShown)
        f.manager.apply(.hook(HookEvent(agent: .claude, event: "PermissionRequest")), to: ids[8])
        #expect(s.bottomChip.label.stringValue == "↓ 2 waiting")
        s.revealWaiting(above: false)
        settle(w)
        for id in [ids[8], ids[9], ids[0]] { f.manager.apply(.hook(HookEvent(agent: .claude, event: "UserPromptSubmit")), to: id) }
        #expect(!s.bottomChip.isShown)

        // Hints fade; toggles animate the outline and chevrons.
        s.setCommandHeld(true)
        s.setCommandHeld(false)
        f.manager.newSession(agent: .claude, cwd: f.dir.path)
        f.manager.close(f.selected!)
        settle(w)
        s.handleClick(row: row(s, .closedHeader))
        s.handleClick(row: row(s, .closedHeader))
        if let fc = cell(s, .folder(folder), as: FolderRowView.self) { s.disclosureClicked(fc.disclosure) }
        #expect(f.manager.workspace.folders[folder]?.expanded == false)
        _ = reloads

        // Banner fades out, then hides in the completion; showing again is immediate.
        try Integrations.installOpenCode(pluginDir: f.env.integrationPaths.opencodePluginDir)
        try Integrations.installPi(extensionDir: f.env.integrationPaths.piExtensionDir)
        _ = try Integrations.installClaude(settingsURL: f.env.integrationPaths.claudeSettings)
        f.manager.refreshIntegrations()
        #expect(s.banner.layer?.animation(forKey: "sidebar.banner") != nil)
        try FileManager.default.removeItem(at: f.env.integrationPaths.piExtensionDir)
        f.manager.refreshIntegrations()
        #expect(!s.banner.isHidden)
    }

    @Test func pointerEventsDriveHover() {
        let (f, s, w) = makeWindowed()
        defer { f.cleanup() }
        for _ in 0..<3 { f.manager.newSession(agent: .shell, cwd: f.dir.path) }
        settle(w)
        let o = s.outline
        let target = o.convert(NSPoint(x: o.rect(ofRow: 1).midX, y: o.rect(ofRow: 1).midY), to: nil)
        func mouse(_ type: NSEvent.EventType) -> NSEvent {
            NSEvent.mouseEvent(with: type, location: target, modifierFlags: [], timestamp: 0, windowNumber: w.windowNumber,
                               context: nil, eventNumber: 0, clickCount: 0, pressure: 0)!
        }
        o.mouseMoved(with: mouse(.mouseMoved))
        #expect(o.hoveredRow == 1)
        #expect(rowView(s, .session(f.manager.workspace.openSessionsInOrder[1]))?.hovered == true)
        let exit = NSEvent.enterExitEvent(with: .mouseExited, location: target, modifierFlags: [], timestamp: 0,
                                          windowNumber: w.windowNumber, context: nil, eventNumber: 0, trackingNumber: 0,
                                          userData: nil)!
        // Exits from other tracking areas (cell tooltips, buttons) don't clear the hover.
        o.mouseExited(with: exit)
        o.mouseEntered(with: exit)
        #expect(o.hoveredRow == 1)
        o.updateTrackingAreas()
        o.refreshRowStates()
        NotificationCenter.default.post(name: NSWindow.didResignKeyNotification, object: w)
        #expect(o.hoveredRow == -1, "resigning key clears hover")
        NotificationCenter.default.post(name: NSWindow.didBecomeKeyNotification, object: w)
        s.rowClicked()
        s.doubleClicked()
        s.menuNeedsUpdate(NSMenu())
        s.setLoopsPaused(true)
        f.manager.newSession(agent: .shell, cwd: f.dir.path)
        settle(w)
        s.setLoopsPaused(false)
    }

    // MARK: Gallery (opt-in, offscreen)

    @Test(.enabled(if: ProcessInfo.processInfo.environment["CORRAL_SNAPSHOTS"] != nil))
    func gallery() throws {
        let out = URL(fileURLWithPath: ProcessInfo.processInfo.environment["CORRAL_SNAPSHOTS"]!)
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        Motion.enabled = false
        defer { Motion.enabled = true }
        let palettes: [(String, NSAppearance.Name, UInt32, UInt32)] = [
            ("dark", .darkAqua, 0x1E1E2E, 0xCDD6F4), ("light", .aqua, 0xFDF6E3, 0x657B83),
        ]
        defer { Theme.update(background: nil, foreground: nil, windowTheme: nil) }
        for (name, appearance, bg, fg) in palettes {
            let f = Fixture()
            defer { f.cleanup() }
            Theme.update(background: RGB(hex: bg).color, foreground: RGB(hex: fg).color, windowTheme: nil)
            let s = SidebarViewController(manager: f.manager)
            let host = NSView(frame: NSRect(x: 0, y: 0, width: 280, height: 720))
            host.wantsLayer = true
            host.layer?.backgroundColor = Theme.tokens.chrome.cgColor
            let w = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
            w.isReleasedWhenClosed = false
            w.appearance = NSAppearance(named: appearance)
            w.contentView = host
            s.view.frame = host.bounds
            s.view.autoresizingMask = [.width, .height]
            host.addSubview(s.view)
            w.alphaValue = 0
            w.ignoresMouseEvents = true
            w.orderFrontRegardless()
            defer { w.orderOut(nil) }
            SnapshotTests.populate(f)
            let collapsed = f.manager.newFolder(name: "Collapsed waiting")
            f.manager.newSession(agent: .claude, cwd: f.dir.path, folder: .some(collapsed))
            let hidden = f.selected!
            f.manager.apply(.hook(HookEvent(agent: .claude, event: "PermissionRequest")), to: hidden)
            s.outline.collapseItem(s.node(.folder(collapsed)))
            s.outline.expandItem(s.node(.closedHeader))
            f.manager.select(f.manager.workspace.openSessionsInOrder[2])
            w.makeFirstResponder(s.outline)
            RunLoop.main.run(until: Date().addingTimeInterval(0.2))
            s.outline.setHoveredRow(s.outline.row(forItem: s.node(.session(f.manager.workspace.openSessionsInOrder[4]))), animated: false)
            SnapshotTests.render(host, to: out.appendingPathComponent("sidebar-gallery-\(name).png"))
            s.outline.setHoveredRow(-1, animated: false)
            s.setCommandHeld(true)
            SnapshotTests.render(host, to: out.appendingPathComponent("sidebar-hints-\(name).png"))
            s.setCommandHeld(false)
            w.setContentSize(NSSize(width: 280, height: 360))
            s.scroll.contentView.scroll(to: NSPoint(x: 0, y: 60))
            s.scroll.reflectScrolledClipView(s.scroll.contentView)
            f.manager.apply(.hook(HookEvent(agent: .claude, event: "PermissionRequest")), to: f.manager.workspace.openSessionsInOrder.last!)
            RunLoop.main.run(until: Date().addingTimeInterval(0.1))
            SnapshotTests.render(host, to: out.appendingPathComponent("sidebar-chips-\(name).png"))
        }
    }
}
