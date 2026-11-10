import AppKit
@testable import CorralCore
@testable import CorralKit

final class FakeTerminal: TerminalSurface {
    let sessionId: UUID
    let launch: LaunchSpec
    /// Accepts focus like the real terminal view, so focus paths are exercised realistically.
    final class FocusableView: NSView { override var acceptsFirstResponder: Bool { true } }
    let view: NSView = FocusableView(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
    var foregroundPid: pid_t = 0
    var needsConfirmQuit = false
    var onKeyDown: ((NSEvent) -> Void)?
    var onFocus: (() -> Void)?
    var text = ""
    var bindings: [String] = []
    var visibility: [Bool] = []
    var destroyed = false
    weak var factory: FakeFactory?

    init(sessionId: UUID, launch: LaunchSpec) {
        self.sessionId = sessionId
        self.launch = launch
    }

    func screenText() -> String { text }

    /// What `perform(binding:)` answers (Ghostty refuses unknown or malformed actions).
    var bindingResult = true

    func perform(binding: String) -> Bool {
        bindings.append(binding)
        factory?.onBinding?(self, binding)
        return bindingResult
    }

    func setVisible(_ visible: Bool) { visibility.append(visible) }
    func destroy() { destroyed = true }
}

final class FakeFactory: TerminalFactory {
    weak var actionHandler: TerminalActionHandler?
    var made: [FakeTerminal] = []
    var backgroundColor: NSColor? = .black
    var foregroundColor: NSColor?
    var windowTheme: String?
    var configPath = "/tmp/corral-test-ghostty-config"
    var reloads = 0
    /// Simulates the shell's first prompt (OSC 7 pwd) right after creation.
    var emitReady = false
    var onBinding: ((FakeTerminal, String) -> Void)?
    var onMake: ((FakeTerminal) -> Void)?

    func makeTerminal(sessionId: UUID, launch: LaunchSpec) -> TerminalSurface {
        let t = FakeTerminal(sessionId: sessionId, launch: launch)
        t.factory = self
        made.append(t)
        onMake?(t)
        if emitReady {
            DispatchQueue.main.async { [weak self, weak t] in
                guard let t else { return }
                _ = self?.actionHandler?.perform(.pwd(launch.cwd), terminal: t)
            }
        }
        return t
    }

    func reloadConfig() { reloads += 1 }

    func terminal(_ id: UUID) -> FakeTerminal? { made.last { $0.sessionId == id } }
}

final class FakeUI: SessionUI {
    var window: NSWindow?
    var isWindowKey = true
    var confirmAnswer = true
    var confirms: [String] = []
    var searches = 0
    var fullscreens = 0
    var finds: [TerminalAction] = []

    func confirm(title: String, message: String, button: String, completion: @escaping (Bool) -> Void) {
        confirms.append(title)
        completion(confirmAnswer)
    }

    func showSessionSearch() { searches += 1 }
    func toggleFullscreen() { fullscreens += 1 }
    func findAction(_ action: TerminalAction, terminal: TerminalSurface) { finds.append(action) }
}

/// Collects outside-world effects so tests can assert on them.
final class Effects {
    var opened: [URL] = []
    var alerts: [String] = []
    var badges: [String?] = []
    var terminated = 0
    var active = true
    /// Keep-awake assertions taken (reasons) and released (ids).
    var awake: [String] = []
    /// Per `awake` entry: whether it keeps the display on.
    var awakeDisplay: [Bool] = []
    var awakeReleased: [UInt32] = []
    var awakeRearmed: [UInt32] = []
    /// Assertions the system already let go (timed out).
    var awakeLapsed: Set<UInt32> = []
    var uptime: TimeInterval = 1000
    /// Notifications posted and withdrawn, and what macOS answers about permission.
    var notes: [CorralNote] = []
    var withdrawn: [String] = []
    var permission: Notifier.Permission = .allowed
    var permissionAnswer: Notifier.Permission = .allowed
    var permissionRequests = 0
}

/// A manager on temp dirs with fake terminals. Keep `fixture` alive for the test's duration.
final class Fixture {
    let dir: URL
    let factory = FakeFactory()
    let ui = FakeUI()
    let effects = Effects()
    var env: ManagerEnvironment
    private(set) var manager: SessionManager!

    init(start: Bool = false, configure: ((inout ManagerEnvironment) -> Void)? = nil) {
        _ = NSApplication.shared
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("corralkit-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let roots = SearchIndex.Roots(claudeProjects: dir.appendingPathComponent("projects"),
                                      opencodeDB: dir.appendingPathComponent("opencode/opencode.db"),
                                      piSessions: dir.appendingPathComponent("pi"))
        env = ManagerEnvironment(
            store: WorkspaceStore(url: dir.appendingPathComponent("state.json")),
            indexPath: dir.appendingPathComponent("index.sqlite").path,
            socketPath: NSTemporaryDirectory() + "ck-\(UInt32.random(in: 0...UInt32.max)).sock",
            roots: roots, jobsDir: dir.appendingPathComponent("jobs"), claudeBinary: nil, hookBinary: "/bin/true",
            notifications: false,
            integrationPaths: Integrations.Paths(claudeSettings: dir.appendingPathComponent("claude/settings.json"),
                                                 opencodePluginDir: dir.appendingPathComponent("oc-plugins"),
                                                 piExtensionDir: dir.appendingPathComponent("pi-ext")))
        let fx = effects
        env.openURL = { fx.opened.append($0) }
        env.power = PowerAssertion(acquire: { reason, display, _ in
                                       fx.awake.append(reason)
                                       fx.awakeDisplay.append(display)
                                       return UInt32(fx.awake.count)
                                   },
                                   rearm: { id, _ in fx.awakeRearmed.append(id); return !fx.awakeLapsed.contains(id) },
                                   release: { fx.awakeReleased.append($0) })
        env.uptime = { fx.uptime }
        env.notifier = Notifier(post: { fx.notes.append($0) }, withdraw: { fx.withdrawn += $0 },
                                permission: { $0(fx.permission) },
                                requestPermission: { done in
                                    fx.permissionRequests += 1
                                    fx.permission = fx.permissionAnswer
                                    done(fx.permission)
                                })
        env.agentPresent = { _, _ in true }
        env.agentInstalled = { _, _ in true }
        // No real process tree: tests that need background commands set their own.
        env.backgroundShells = { _ in [] }
        env.alert = { title, _ in fx.alerts.append(title) }
        env.setBadge = { fx.badges.append($0) }
        env.terminate = { fx.terminated += 1 }
        env.appIsActive = { fx.active }
        // Deterministic launch path regardless of the machine's shell (zsh = direct agent launch).
        env.loginShell = "/bin/zsh"
        // Restore everything at start unless a test is about the queue.
        env.restoreConcurrency = .max
        configure?(&env)
        makeManager()
        if start { manager.start() }
    }

    /// Claude transcripts for `ids`: closed sessions naming them can be resumed (and stay in Closed).
    func transcripts(_ ids: String...) {
        let project = env.roots.claudeProjects.appendingPathComponent("-test-project")
        try? FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        for id in ids { try? Data("{}\n".utf8).write(to: project.appendingPathComponent("\(id).jsonl")) }
    }

    /// A fresh manager over the same state file (simulates relaunch).
    func makeManager() {
        manager = SessionManager(terminals: factory, env: env)
        manager.ui = ui
    }

    func cleanup() {
        manager.prepareForTermination()
        try? FileManager.default.removeItem(at: dir)
    }

    var selected: UUID? { manager.workspace.selected }

    func terminal(_ id: UUID?) -> FakeTerminal? { id.flatMap { factory.terminal($0) } }
}

/// Runs the main queue until `condition` holds or the timeout passes.
@MainActor
func waitUntil(timeout: Double = 10, _ condition: () -> Bool) async {
    let deadline = Date().addingTimeInterval(timeout)
    while !condition() && Date() < deadline {
        try? await Task.sleep(for: .milliseconds(10))
    }
}

func keyEvent(_ keyCode: UInt16, chars: String, modifiers: NSEvent.ModifierFlags = []) -> NSEvent {
    NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: modifiers, timestamp: 1, windowNumber: 0,
                     context: nil, characters: chars, charactersIgnoringModifiers: chars, isARepeat: false,
                     keyCode: keyCode)!
}

/// Minimal NSDraggingInfo carrying a sidebar drag token.
final class FakeDrag: NSObject, NSDraggingInfo {
    let pasteboard: NSPasteboard
    init(token: String) {
        pasteboard = NSPasteboard(name: NSPasteboard.Name("corral-test-\(UUID().uuidString)"))
        pasteboard.clearContents()
        let item = NSPasteboardItem()
        item.setString(token, forType: SidebarViewController.dragType)
        pasteboard.writeObjects([item])
    }
    var draggingDestinationWindow: NSWindow? { nil }
    var draggingSourceOperationMask: NSDragOperation { .move }
    var draggingLocation: NSPoint { .zero }
    var draggedImageLocation: NSPoint { .zero }
    var draggedImage: NSImage? { nil }
    var draggingPasteboard: NSPasteboard { pasteboard }
    var draggingSource: Any? { nil }
    var draggingSequenceNumber: Int { 1 }
    func slideDraggedImage(to screenPoint: NSPoint) {}
    var draggingFormation: NSDraggingFormation = .default
    var animatesToDestination = false
    var numberOfValidItemsForDrop = 1
    func enumerateDraggingItems(options: NSDraggingItemEnumerationOptions = [], for view: NSView?,
                                classes: [AnyClass], searchOptions: [NSPasteboard.ReadingOptionKey: Any] = [:],
                                using block: (NSDraggingItem, Int, UnsafeMutablePointer<ObjCBool>) -> Void) {}
    var springLoadingHighlight: NSSpringLoadingHighlight { .none }
    func resetSpringLoading() {}
}

