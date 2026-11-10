import AppKit
import IOKit.pwr_mgt
import Carbon
import CorralCore

final class LiveSession {
    let id: UUID
    let terminal: TerminalSurface
    var status = LiveStatus()
    /// Set while a directly launched agent has not shown anything yet (launch cover, "Starting…").
    var launch: LaunchState?

    init(id: UUID, terminal: TerminalSurface) {
        self.id = id
        self.terminal = terminal
    }
}

enum ManagerChange {
    case structure
    case status(UUID)
    case selection
    case background
    case integrations
    /// Terminal config reloaded (theme / background color may have changed).
    case appearance
    /// A session's split panes changed (layout, a pane added, closed or promoted).
    case panes(UUID)
    /// App-wide preferences changed (`workspace.settings`).
    case settings
    /// Show this session in the sidebar even inside a collapsed folder (a notification was clicked).
    case reveal(UUID)
}

/// An IOKit "prevent idle system sleep" assertion, like `caffeinate -i`: the display may still sleep,
/// and closing the lid still sleeps the Mac. It times out on its own (`acquire`'s timeout, pushed out
/// again by `rearm`), so a status that wrongly stays "working" can't keep the Mac up for good.
public struct PowerAssertion {
    public var acquire: (_ reason: String, _ timeout: TimeInterval) -> UInt32?
    /// Restarts the timeout; false when the assertion is gone (it timed out).
    public var rearm: (_ id: UInt32, _ timeout: TimeInterval) -> Bool
    public var release: (UInt32) -> Void

    public init(acquire: @escaping (String, TimeInterval) -> UInt32?, rearm: @escaping (UInt32, TimeInterval) -> Bool,
                release: @escaping (UInt32) -> Void) {
        self.acquire = acquire
        self.rearm = rearm
        self.release = release
    }

    public static let system = PowerAssertion(acquire: { reason, timeout in
        let props: [String: Any] = [
            kIOPMAssertionTypeKey: kIOPMAssertionTypePreventUserIdleSystemSleep,
            kIOPMAssertionLevelKey: IOPMAssertionLevel(kIOPMAssertionLevelOn),
            kIOPMAssertionNameKey: reason,
            kIOPMAssertionTimeoutKey: timeout,
            kIOPMAssertionTimeoutActionKey: kIOPMAssertionTimeoutActionRelease,
        ]
        var id: IOPMAssertionID = 0
        return IOPMAssertionCreateWithProperties(props as CFDictionary, &id) == kIOReturnSuccess ? id : nil
    }, rearm: { id, timeout in
        IOPMAssertionSetProperty(id, kIOPMAssertionTimeoutKey as CFString, timeout as CFNumber) == kIOReturnSuccess
    }, release: { _ = IOPMAssertionRelease($0) })
}

/// A throwaway shell split next to a session's terminal (⌘D). Starting an agent in it turns it
/// into a session of its own (tracked like any other).
struct Pane {
    let id: UUID
    /// The session whose card holds the pane (changes when that session leaves a shared card).
    var owner: UUID
    let terminal: TerminalSurface
}

/// A direct agent launch waiting for its first frame.
struct LaunchState: Equatable {
    var kind: AgentLaunch.Kind
    var agent: AgentKind
    /// `ProcessInfo.systemUptime` at spawn (the probe's per-session cap).
    var started: TimeInterval
    /// Resumes replay their transcript: the cover waits until the screen stops changing.
    var lastScreen: Int?
    var stableTicks = 0
}

/// UI hooks the manager needs from the window.
protocol SessionUI: AnyObject {
    var window: NSWindow? { get }
    /// The main window is key (a session shown there is "being looked at").
    var isWindowKey: Bool { get }
    func confirm(title: String, message: String, button: String, completion: @escaping (Bool) -> Void)
    func showSessionSearch()
    func toggleFullscreen()
    func findAction(_ action: TerminalAction, terminal: TerminalSurface)
    /// Puts keyboard focus in `terminal` (moving between split panes).
    func focus(terminal: TerminalSurface?)
    /// Where the terminals on `owner`'s card are on screen (unit square, y down), the ones shown only.
    func cardBoxes(_ owner: UUID) -> [UUID: PaneBox]?
}

extension SessionUI {
    func focus(terminal: TerminalSurface?) {}
    func cardBoxes(_ owner: UUID) -> [UUID: PaneBox]? { nil }
}

/// Paths and outside-world effects, injectable so tests run against temp dirs and fakes.
public struct ManagerEnvironment {
    public var store: WorkspaceStore
    public var indexPath: String
    public var socketPath: String
    public var roots: SearchIndex.Roots
    public var jobsDir: URL
    public var claudeBinary: String?
    public var hookBinary: String?
    /// Posts notifications at all (a bundled app: Notification Center needs a bundle id).
    public var notifications: Bool
    /// Notification Center (Settings › Notifications). Tests swap in a recorder.
    public var notifier: Notifier = .system
    public var integrationPaths: Integrations.Paths
    /// The `claude-sessions` tracker (Ghostty restore tool) to import from, if installed.
    public var trackerBinary: String? = TrackerCLI.defaultBinary
    public var openURL: (URL) -> Void = { NSWorkspace.shared.open($0) }
    public var alert: (String, String) -> Void = { title, text in
        let a = NSAlert()
        a.messageText = title
        a.informativeText = text
        a.runModal()
    }
    public var appIsActive: () -> Bool = { NSApp?.isActive ?? false }
    public var setBadge: (String?) -> Void = { NSApp?.dockTile.badgeLabel = $0 }
    public var terminate: () -> Void = { NSApp?.terminate(nil) }
    /// The user's login shell; zsh gets the direct agent launch (`AgentLaunch`).
    public var loginShell: String = ManagerEnvironment.defaultLoginShell()
    /// Launch probe: how often a launching terminal's screen is checked, and when it counts as ready anyway.
    public var launchProbeInterval: TimeInterval = 0.1
    public var launchProbeCap: TimeInterval = 4
    /// Resumes and attaches: unchanged probes before the replayed screen counts as settled, and the
    /// longer cap (a long transcript takes a while to draw).
    public var launchSettleTicks = 2
    public var launchResumeCap: TimeInterval = 8
    /// Sessions resumed at once at app start (after the selected one). Each `claude --resume` is a
    /// Node process replaying its transcript; all at once starve each other.
    public var restoreConcurrency = 2
    /// Keeps the Mac from idle-sleeping (Settings › Keep awake). Tests swap in a fake.
    public var power: PowerAssertion = .system
    /// Seconds since boot (keep-awake re-arm throttle). Tests drive it.
    public var uptime: () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }
    /// Whether an agent is set up on this Mac (its config folder exists); integrations are only
    /// offered for those.
    public var agentPresent: (AgentKind, Integrations.Paths) -> Bool = { Integrations.toolPresent($0, paths: $1) }
    /// Whether an agent is installed (command or config folder); menus offer only those.
    public var agentInstalled: (AgentKind, Integrations.Paths) -> Bool = { Integrations.installed($0, paths: $1) }

    /// getpwuid's shell, else $SHELL, else /bin/zsh (the macOS default).
    public static func defaultLoginShell() -> String {
        if let pw = getpwuid(getuid()), let sh = pw.pointee.pw_shell {
            let s = String(cString: sh)
            if !s.isEmpty { return s }
        }
        if let s = ProcessInfo.processInfo.environment["SHELL"], !s.isEmpty { return s }
        return "/bin/zsh"
    }

    /// The app's: first the login shell's variables Corral needs (`ShellEnvironment`; an app opened from
    /// Finder has none of them), then `.standard` from them.
    public static func app() -> ManagerEnvironment {
        ShellEnvironment.shell = ShellEnvironment.resolve(
            shell: defaultLoginShell(), cache: CorralPaths.support.appendingPathComponent("shell-environment.json"))
        return .standard
    }

    public static var standard: ManagerEnvironment {
        ManagerEnvironment(
            store: WorkspaceStore(), indexPath: CorralPaths.index.path, socketPath: CorralPaths.socket.path,
            roots: .standard, jobsDir: BackgroundAgents.jobsDir, claudeBinary: BackgroundAgents.claudeBinary(),
            hookBinary: hookBinaryNextToExecutable(),
            notifications: Bundle.main.bundleIdentifier != nil && Bundle.main.bundleURL.pathExtension == "app",
            integrationPaths: .standard)
    }

    /// corral-hook next to the app binary (bundle) or in the SwiftPM build dir (dev). The executable's
    /// real location, not argv[0] (a bare name when started from PATH).
    static func hookBinaryNextToExecutable() -> String? {
        let exe = (Bundle.main.executableURL ?? URL(fileURLWithPath: CommandLine.arguments[0]))
            .resolvingSymlinksInPath().deletingLastPathComponent()
        let candidate = exe.appendingPathComponent("corral-hook").path
        return FileManager.default.isExecutableFile(atPath: candidate) ? candidate : nil
    }
}

/// Owns open sessions (terminal + live status), the persisted workspace, the hook socket,
/// the search index and background-agent tracking.
final class SessionManager: TerminalActionHandler {
    let terminals: TerminalFactory
    let env: ManagerEnvironment
    let index: SearchIndex
    private(set) var workspace: Workspace
    private(set) var live: [UUID: LiveSession] = [:]
    /// Split panes by pane id, the card layouts (`setLayout` only), and which terminal of a session has
    /// focus (its own or a pane on its card).
    private(set) var panes: [UUID: Pane] = [:]
    /// Index entries of forgotten closed shells, removed once the index is open.
    private var staleScrollback: [String] = []
    private(set) var paneLayouts: [UUID: PaneLayout] = [:]
    private(set) var focusedTerminalId: [UUID: UUID] = [:]
    private var paneCwd: [UUID: String] = [:]
    private(set) var background: [BackgroundAgent] = []
    private(set) var integrations: Integrations.Status
    weak var ui: SessionUI?

    private var observers: [(ManagerChange) -> Void] = []
    private var eventServer: EventServer?
    private var watchers: [String: FSWatcher] = [:]
    private var backgroundLoading = false
    private var backgroundDirty = false
    private var saveWork: DispatchWorkItem?
    private var terminating = false
    private var activationObserver: NSObjectProtocol?

    init(terminals: TerminalFactory, env: ManagerEnvironment = .standard) {
        self.terminals = terminals
        self.env = env
        index = SearchIndex(path: env.indexPath)
        workspace = env.store.load()
        // The index opens in start(); their old scrollback leaves it then.
        staleScrollback = workspace.forgetClosedShells().map { "corral:\($0.uuidString)" }
        integrations = Integrations.status(paths: env.integrationPaths)
        installedAgents = Self.detectInstalled(env)
        terminals.actionHandler = self
        // Closed sessions whose conversation doesn't exist ("No conversation found") can't be resumed.
        let transcripts = Self.claudeTranscripts(root: env.roots.claudeProjects)
        for r in workspace.closedSessions where missingTranscript(r, claude: transcripts) { workspace.forget(r.id) }
    }

    deinit {
        if let activationObserver { NotificationCenter.default.removeObserver(activationObserver) }
        eventServer?.stop()
    }

    func observe(_ fn: @escaping (ManagerChange) -> Void) { observers.append(fn) }
    private func emit(_ c: ManagerChange) {
        switch c {
        case .status, .background, .structure, .settings: updateKeepAwake()
        default: break
        }
        observers.forEach { $0(c) }
    }

    // MARK: Keep awake

    /// The assertion lapses this long after the last sign of work: a turn interrupted with Esc or a
    /// background job that died can leave a status at "working" with nothing to end it.
    static let keepAwakeTimeout: TimeInterval = 2 * 3600
    /// While wanted, the timeout is pushed out on activity, at most this often.
    static let keepAwakeRearm: TimeInterval = 60
    static let keepAwakeReason = "Corral: agents are working"
    private var awakeAssertion: UInt32?
    private var awakeArmedAt = -TimeInterval.infinity
    private var awakeFailedAt = -TimeInterval.infinity
    var isKeepingAwake: Bool { awakeAssertion != nil }

    /// Hooked agent sessions in a turn (a tool, a script, a subagent). Without hooks "working" is a
    /// terminal guess; waiting for permission or a prompt never counts.
    private func isWorking(_ ls: LiveSession) -> Bool {
        ls.status.agent != .shell && ls.status.activity == .working && ls.status.hooksSeen
    }

    private var hasWorkingAgent: Bool {
        live.values.contains(where: isWorking) || background.contains { $0.activity == .working }
    }

    /// Working sessions plus working background jobs (a job attached to a counted session once).
    var workingAgents: Int {
        var counted = Set<String>()
        var n = 0
        for ls in live.values where isWorking(ls) {
            n += 1
            if let job = workspace.sessions[ls.id]?.bgJobId { counted.insert(job) }
        }
        return n + background.filter { $0.activity == .working && !counted.contains($0.id) }.count
    }

    func setNotifications(_ n: NotificationSettings) {
        guard workspace.settings.notifications != n else { return }
        workspace.settings.notifications = n
        scheduleSave()
        emit(.settings)
    }

    /// Hooks the user removed aren't offered by the sidebar again; installing them clears it.
    func setHooksRemoved(_ agent: AgentKind, _ removed: Bool) {
        guard workspace.settings.hooksRemoved.contains(agent) != removed else { return }
        if removed { workspace.settings.hooksRemoved.insert(agent) } else { workspace.settings.hooksRemoved.remove(agent) }
        scheduleSave()
        emit(.integrations)
    }

    func setKeepAwake(_ on: Bool) {
        guard workspace.settings.keepAwake != on else { return }
        workspace.settings.keepAwake = on
        scheduleSave()
        emit(.settings)
    }

    /// Holds the assertion while the setting is on and some agent works. Event-driven: runs on every
    /// status, background, structure and settings change, never on a timer.
    private func updateKeepAwake() {
        guard workspace.settings.keepAwake || awakeAssertion != nil else { return }
        let want = workspace.settings.keepAwake && !terminating && hasWorkingAgent
        let now = env.uptime()
        if !want {
            if let id = awakeAssertion { env.power.release(id) }
            awakeAssertion = nil
        } else if let id = awakeAssertion {
            guard now - awakeArmedAt >= Self.keepAwakeRearm else { return }
            awakeArmedAt = now
            // Gone (timed out after a quiet stretch): work is back, take a new one.
            if !env.power.rearm(id, Self.keepAwakeTimeout) {
                awakeAssertion = env.power.acquire(Self.keepAwakeReason, Self.keepAwakeTimeout)
            }
        } else if now - awakeFailedAt >= Self.keepAwakeRearm {
            awakeAssertion = env.power.acquire(Self.keepAwakeReason, Self.keepAwakeTimeout)
            awakeArmedAt = now
            if awakeAssertion == nil { awakeFailedAt = now }
        }
    }

    /// Agents set up on this Mac whose status hooks are missing (the sidebar banner offers them).
    var missingIntegrations: [AgentKind] {
        [AgentKind.claude, .opencode, .pi].filter {
            env.agentPresent($0, env.integrationPaths) && !integrations.installed($0) && !workspace.settings.hooksRemoved.contains($0)
        }
    }

    /// The shell and the agents installed on this Mac. New-session menus, the empty window and folder
    /// menus offer only these; Settings greys out the others.
    private(set) var installedAgents: Set<AgentKind> = [.shell]

    static func detectInstalled(_ env: ManagerEnvironment) -> Set<AgentKind> {
        Set(AgentKind.allCases.filter { $0 == .shell || env.agentInstalled($0, env.integrationPaths) })
    }

    /// Re-checks which agents are installed (cheap: a few file lookups). Emits `.integrations` on a change.
    func refreshInstalledAgents() {
        let now = Self.detectInstalled(env)
        guard now != installedAgents else { return }
        installedAgents = now
        emit(.integrations)
    }

    // MARK: Startup

    func start() {
        let order = workspace.openSessionsInOrder
        if workspace.selected == nil { workspace.selected = order.first }
        // Cards shared by sessions of the last run (only open ones; shells in panes aren't kept).
        for (owner, layout) in workspace.openSplits { setLayout(layout, for: owner) }
        saveSplits()
        // Before restoring: the index names the conversations of sessions saved without an id.
        do {
            try index.open()
            staleScrollback.forEach(index.removeSession(key:))
            staleScrollback = []
            recoverSessionIds()
            index.refresh(roots: env.roots)
        } catch {
            NSLog("Corral: search index unavailable: \(error)")
        }
        // The session on screen first (with the sessions sharing its card), the rest a few at a
        // time (see `restoreConcurrency`).
        pendingRestore = order
        if let sel = workspace.selected, order.contains(sel) { restore(sel) }
        pumpRestores()

        eventServer = EventServer(path: env.socketPath) { [weak self] msg in self?.handleHook(msg) }
        do { try eventServer?.start() } catch { NSLog("Corral: hook socket failed: \(error)") }

        ensureWatchers()
        reloadBackground()

        activationObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main
        ) { [weak self] _ in
            self?.markSelectedViewed()
            self?.ensureWatchers()
        }
        emit(.structure)
        emit(.selection)
    }

    /// FSEvents needs existing paths; agents installed after launch get picked up on next activation.
    func ensureWatchers() {
        // Background jobs appear in Claude's config folder: watched only where Claude is set up (creating
        // ~/.claude for someone without it would count as "Claude set up here" and nag about its hooks).
        if FileManager.default.fileExists(atPath: env.jobsDir.deletingLastPathComponent().path) {
            try? FileManager.default.createDirectory(at: env.jobsDir, withIntermediateDirectories: true)
        }
        let roots = env.roots
        let ocDir = roots.opencodeDB.deletingLastPathComponent().path
        let wanted: [(String, ([String]) -> Void)] = [
            (roots.claudeProjects.path, { [weak self] _ in self?.refreshIndex([.claude]) }),
            (ocDir, { [weak self] paths in
                if paths.contains(where: { $0.contains("opencode.db") }) { self?.refreshIndex([.opencode]) }
            }),
            (roots.piSessions.path, { [weak self] _ in self?.refreshIndex([.pi]) }),
            (env.jobsDir.path, { [weak self] paths in self?.backgroundChanged(paths) }),
        ]
        var added: Set<SearchIndex.Source> = []
        for (path, handler) in wanted where watchers[path] == nil {
            guard FileManager.default.fileExists(atPath: path) else { continue }
            watchers[path] = FSWatcher(paths: [path], latency: 2, handler: handler)
            if path == ocDir { added.insert(.opencode) }
            if path == roots.piSessions.path { added.insert(.pi) }
        }
        if !added.isEmpty { refreshIndex(added) }
    }

    var watchedPaths: Set<String> { Set(watchers.keys) }

    func refreshIndex(_ sources: Set<SearchIndex.Source>) {
        index.refresh(sources, roots: env.roots)
    }

    func prepareForTermination() {
        terminating = true
        updateKeepAwake()
        for (id, ls) in live { syncRecord(id, from: ls.status) }
        saveNow(wait: true)
        eventServer?.stop()
    }

    // MARK: Session lifecycle

    @discardableResult
    private func spawn(_ record: SessionRecord, input: String?, resuming: Bool) -> LiveSession {
        if let old = live[record.id] {
            old.terminal.destroy()
            old.terminal.view.removeFromSuperview()
        }
        var cwd = record.launchDirectory(resuming: resuming)
        var isDir: ObjCBool = false
        if !FileManager.default.fileExists(atPath: cwd, isDirectory: &isDir) || !isDir.boolValue {
            cwd = NSHomeDirectory()
        }
        var vars = ["CORRAL_SOCKET": env.socketPath]
        if let hook = env.hookBinary { vars["CORRAL_HOOK"] = hook }
        var spec = LaunchSpec(cwd: cwd, agentInput: input, env: vars)
        var launch: LaunchState?
        if let input, record.agent != .shell,
           let command = AgentLaunch.command(input: input, shell: env.loginShell, agent: record.agent) {
            spec.command = command
            launch = LaunchState(kind: AgentLaunch.kind(resuming: resuming, backgroundJob: record.bgJobId != nil),
                                 agent: record.agent, started: ProcessInfo.processInfo.systemUptime)
        } else {
            // Typed fallback (non-zsh login shell): the shell's prompt shows, then the command.
            spec.initialInput = input
        }
        let terminal = terminals.makeTerminal(sessionId: record.id, launch: spec)
        let ls = LiveSession(id: record.id, terminal: terminal)
        ls.status.cwd = cwd
        ls.launch = launch
        if resuming {
            ls.status.agent = record.agent
            ls.status.agentSessionId = record.agentSessionId
            ls.status.agentCwd = record.agentCwd
        } else if launch != nil {
            // The terminal's process is the agent from the start (no shell prompt to detect it from).
            ls.status.agent = record.agent
        }
        wire(ls)
        live[record.id] = ls
        if launch != nil { scheduleLaunchProbe() }
        return ls
    }

    // MARK: Launch reveal

    private(set) var launchProbeScheduled = false

    /// What the session's direct launch is doing, nil once the agent shows (or for typed launches).
    func launchKind(_ id: UUID) -> AgentLaunch.Kind? { live[id]?.launch?.kind }

    var launchingCount: Int { live.values.lazy.filter { $0.launch != nil }.count }

    /// The agent showed (first output, hook, title, key press, exit…): drop the launch cover.
    func launchReady(_ id: UUID) {
        guard let ls = live[id], ls.launch != nil else { return }
        ls.launch = nil
        emit(.status(id))
        pumpRestores()
    }

    /// A hint the agent is up (a hook, a title). Enough for a fresh start; a resume or attach is
    /// still replaying its transcript then, so its cover waits for the screen to settle.
    func launchHint(_ id: UUID) {
        if live[id]?.launch?.kind == .starting { launchReady(id) }
    }

    // MARK: Restore at start

    /// Open sessions not started yet; they start a few at a time, or right away when selected.
    private(set) var pendingRestore: [UUID] = []

    func isPendingRestore(_ id: UUID) -> Bool { pendingRestore.contains(id) }

    /// Starts queued sessions: agent resumes while fewer than `restoreConcurrency` are launching,
    /// plain shells (cheap, nothing to replay) right away.
    private func pumpRestores() {
        var i = 0
        while i < pendingRestore.count {
            let id = pendingRestore[i]
            let resumes = workspace.sessions[id]?.restoreInput != nil && AgentLaunch.supportsDirect(shell: env.loginShell)
            if !resumes || launchingCount < env.restoreConcurrency {
                // Leaves the queue, with any partners on its card (also ones before `i`): rescan.
                restore(id)
                i = 0
            } else {
                i += 1
            }
        }
    }

    private func restore(_ id: UUID) {
        pendingRestore.removeAll { $0 == id }
        guard live[id] == nil, let record = workspace.sessions[id], record.closedAt == nil else { return }
        let (input, resuming) = relaunch(record, input: record.restoreInput)
        spawn(record, input: input, resuming: resuming)
        // Into the window now (hidden, at its real size): replaying at a default size would redraw
        // the whole transcript again when it is first shown.
        emit(.structure)
        // Sessions sharing a card start together, so the card never shows with a hole.
        if let owner = layoutOwnerOf[id], let layout = paneLayouts[owner] {
            for other in layout.leaves where live[other] == nil && isPendingRestore(other) { restore(other) }
            emit(.panes(owner))
        }
    }

    /// Bounded probe, the one exception to "no polling": libghostty's Metal renderer has no output
    /// callback, so a launching terminal's screen is checked every `launchProbeInterval`, only while
    /// some session is launching, each for at most `launchProbeCap`. One-shot, re-armed per tick.
    private func scheduleLaunchProbe() {
        guard !launchProbeScheduled, !terminating, live.values.contains(where: { $0.launch != nil }) else { return }
        launchProbeScheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + env.launchProbeInterval) { [weak self] in
            guard let self else { return }
            self.launchProbeScheduled = false
            self.probeLaunches()
        }
    }

    /// Fresh starts show on their first output. Resumes and attaches replay a transcript (drawn top
    /// to bottom, slowly when several start together): their cover stays until the screen has been
    /// unchanged for `launchSettleTicks` probes, so the finished screen appears at once.
    func probeLaunches(now: TimeInterval = ProcessInfo.processInfo.systemUptime) {
        guard !terminating else { return }
        for (id, ls) in live {
            guard let l = ls.launch else { continue }
            let replays = l.kind != .starting
            if now - l.started >= (replays ? env.launchResumeCap : env.launchProbeCap) { launchReady(id); continue }
            let screen = ls.terminal.viewportText()
            guard Self.hasVisibleText(screen) else { continue }
            guard replays else { launchReady(id); continue }
            let h = screen.hashValue
            ls.launch?.stableTicks = h == l.lastScreen ? l.stableTicks + 1 : 0
            ls.launch?.lastScreen = h
            if (ls.launch?.stableTicks ?? 0) >= env.launchSettleTicks { launchReady(id) }
        }
        scheduleLaunchProbe()
    }

    /// Claude sessions saved without their conversation's id (started before the status hooks were
    /// installed, or `claude` typed by hand without them) get it back from the conversation that has
    /// the session's title, when exactly one has it and no other session holds that id. They resume.
    func recoverSessionIds() {
        var held = Set(workspace.sessions.values.compactMap(\.agentSessionId))
        for id in workspace.openSessionsInOrder {
            guard var r = workspace.sessions[id], r.agent == .claude, r.agentSessionId == nil, r.bgJobId == nil else { continue }
            let titles = [r.customName, r.autoTitle].compactMap { $0 }
            guard let found = titles.lazy.compactMap(index.claudeSession(titled:)).first,
                  !held.contains(found.sessionId) else { continue }
            r.agentSessionId = found.sessionId
            r.agentCwd = found.cwd.isEmpty ? r.cwd : found.cwd
            r.agentRunning = true
            workspace.sessions[id] = r
            held.insert(found.sessionId)
            scheduleSave()
        }
    }

    /// What a restored or reopened session runs: its resume command, or for a Claude session that never
    /// wrote its conversation (opened, nothing typed) a fresh start under the same id, since resuming
    /// it would only print "No conversation found".
    func relaunch(_ record: SessionRecord, input: String?) -> (input: String?, resuming: Bool) {
        if input != nil, record.bgJobId == nil, let sid = record.agentSessionId, missingTranscript(record),
           let fresh = record.agent.startCommand(sessionId: sid) {
            return (fresh, false)
        }
        return (input, input != nil)
    }

    static func hasVisibleText(_ text: String) -> Bool {
        text.unicodeScalars.contains { !CharacterSet.whitespacesAndNewlines.contains($0) }
    }

    func newSession(agent: AgentKind, cwd: String? = nil, folder: UUID?? = nil, title: String = "",
                    input: String? = nil, agentSessionId: String? = nil, bgJobId: String? = nil) {
        let (targetFolder, index, dir) = workspace.placement(for: agent, folder: folder, cwd: cwd,
                                                             currentDirectory: currentDirectory, home: NSHomeDirectory())
        let resuming = agentSessionId != nil
        var input = input, agentSessionId = agentSessionId
        // A fresh Claude session gets its id now, so it resumes after a relaunch even without hooks.
        if input == nil, agentSessionId == nil {
            let sid = UUID().uuidString.lowercased()
            if let command = agent.startCommand(sessionId: sid) { (input, agentSessionId) = (command, sid) }
        }
        var record = SessionRecord(cwd: dir, agent: agent, title: title, agentSessionId: agentSessionId)
        record.bgJobId = bgJobId
        if agentSessionId != nil { record.agentCwd = dir }
        workspace.addSession(record, in: targetFolder, at: index)
        spawn(record, input: input ?? agent.launchCommand, resuming: resuming)
        emit(.structure)
        select(record.id)
    }

    var currentDirectory: String? {
        guard let sel = workspace.selected else { return nil }
        return live[sel]?.status.cwd ?? workspace.sessions[sel]?.cwd
    }

    func requestClose(_ id: UUID) {
        guard let ls = live[id] else {
            if isPendingRestore(id) { close(id) }
            return
        }
        let busy = ls.status.activity == .working || ls.status.activity == .needsInput
        // Shells on a card shared with other sessions stay with them.
        let paneBusy = sideBySide(id).count == 1 && panes.values.contains { $0.owner == id && $0.terminal.needsConfirmQuit }
        guard busy || ls.terminal.needsConfirmQuit || paneBusy else { close(id); return }
        let name = workspace.sessions[id]?.displayTitle ?? "this session"
        ui?.confirm(title: "Close “\(name)”?",
                    message: "A process is still running. It stays searchable and can be reopened from Closed.",
                    button: "Close") { [weak self] ok in
            if ok { self?.close(id) }
        }
    }

    func close(_ id: UUID) {
        pendingRestore.removeAll { $0 == id }
        if let ls = live[id] {
            syncRecord(id, from: ls.status)
            // Plain shells vanish on close (below); agent sessions keep their final screen searchable.
            if let record = workspace.sessions[id], record.agent != .shell, record.agentSessionId == nil {
                let text = ls.terminal.screenText()
                if !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    index.addScrollback(session: id, title: record.displayTitle, cwd: record.cwd, text: text,
                                        created: record.createdAt, closed: Date())
                }
            }
            ls.terminal.destroy()
            ls.terminal.view.removeFromSuperview()
            live[id] = nil
        }
        let partners = sideBySide(id).filter { $0 != id }
        // Also one still waiting to be restored can be on a saved shared card.
        closePanes(of: id)
        // Also for one still waiting to be restored: its last run's notification may be up.
        removeNotification(id)
        let order = workspace.openSessionsInOrder
        let wasSelected = workspace.selected == id
        // Only sessions that ran an agent go to Closed; a plain terminal is simply gone, and so is a
        // session whose conversation doesn't exist (a resume that found nothing).
        if let r = workspace.sessions[id], r.agent == .shell || missingTranscript(r) {
            workspace.forget(id)
        } else {
            workspace.close(id)
        }
        emit(.structure)
        if wasSelected, let partner = partners.first(where: { live[$0] != nil }) {
            // Stay on the card.
            select(partner)
        } else if wasSelected, let i = order.firstIndex(of: id) {
            let remaining = order.filter { $0 != id }
            select(remaining.isEmpty ? nil : remaining[min(i, remaining.count - 1)])
        }
        updateBadge()
        scheduleSave()
    }

    func reopen(_ id: UUID, folder: UUID?? = nil, at index: Int? = nil) {
        guard let record = workspace.sessions[id], record.closedAt != nil else {
            if live[id] != nil { select(id) }
            return
        }
        workspace.reopen(id, in: folder, at: index)
        guard let reopened = workspace.sessions[id] else { return }
        let (input, resuming) = relaunch(reopened, input: reopened.reopenInput)
        spawn(reopened, input: input, resuming: resuming)
        emit(.structure)
        select(id)
    }

    /// Undo-close: only for something closed moments ago, never a days-old session.
    @discardableResult
    func reopenLastClosed(within window: TimeInterval? = nil) -> Bool {
        guard let last = workspace.closedSessions.first else { return false }
        if let window, let closed = last.closedAt, Date().timeIntervalSince(closed) > window { return false }
        reopen(last.id)
        return true
    }

    func forget(_ id: UUID) {
        guard live[id] == nil else { return }
        workspace.forget(id)
        index.removeSession(key: "corral:\(id.uuidString)")
        emit(.structure)
        scheduleSave()
    }

    func forgetAllClosed() {
        for r in workspace.closedSessions {
            workspace.forget(r.id)
            index.removeSession(key: "corral:\(r.id.uuidString)")
        }
        emit(.structure)
        scheduleSave()
    }

    /// Opens a search result: focus it if open, reopen if closed, otherwise resume it in a new session.
    func open(hit: SearchHit) {
        if let corral = hit.corralSessionId, workspace.sessions[corral] != nil {
            if live[corral] != nil { select(corral) } else { reopen(corral) }
            return
        }
        if let match = workspace.sessions.values
            .filter({ $0.agentSessionId == hit.sessionId && $0.agent == hit.agent })
            .sorted(by: { ($0.closedAt == nil ? 1 : 0, $0.lastActiveAt) > ($1.closedAt == nil ? 1 : 0, $1.lastActiveAt) })
            .first {
            if live[match.id] != nil { select(match.id) } else { reopen(match.id) }
            return
        }
        // hit.cwd is the transcript's own directory, which is where resume must run.
        newSession(agent: hit.agent, cwd: hit.cwd.isEmpty ? nil : hit.cwd, title: hit.title,
                   input: hit.agent.resumeCommand(sessionId: hit.sessionId), agentSessionId: hit.sessionId)
    }

    func attach(_ agent: BackgroundAgent) {
        if let existing = live.values.first(where: { workspace.sessions[$0.id]?.bgJobId == agent.id }) {
            select(existing.id)
            return
        }
        newSession(agent: .claude, cwd: agent.cwd, title: agent.name, input: agent.attachCommand,
                   agentSessionId: agent.sessionId, bgJobId: agent.id)
    }

    // MARK: Tree editing

    func rename(_ id: UUID, to name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if workspace.folders[id] != nil {
            workspace.folders[id]?.name = trimmed.isEmpty ? "Folder" : trimmed
        } else if var r = workspace.sessions[id] {
            r.customName = trimmed.isEmpty ? nil : trimmed
            workspace.sessions[id] = r
            if let sid = r.agentSessionId { index.setCustomTitle(key: "\(r.agent.rawValue):\(sid)", title: r.customName) }
        }
        emit(.structure)
        scheduleSave()
    }

    @discardableResult
    func newFolder(name: String = "New Folder", in parent: UUID? = nil, directory: String? = nil) -> UUID {
        let folder = Folder(name: name, directory: directory)
        workspace.addFolder(folder, in: parent)
        emit(.structure)
        scheduleSave()
        return folder.id
    }

    func setAgentDefaults(_ d: AgentDefaults, for agent: AgentKind) {
        workspace.setDefaults(d, for: agent)
        scheduleSave()
        emit(.structure)
    }

    func setFolderDirectory(_ id: UUID, _ dir: String?) {
        workspace.folders[id]?.directory = dir
        scheduleSave()
        emit(.structure)
    }

    func setExpanded(_ id: UUID, _ expanded: Bool) {
        guard let current = workspace.folders[id]?.expanded, current != expanded else { return }
        workspace.folders[id]?.expanded = expanded
        scheduleSave()
    }

    func deleteFolder(_ id: UUID) {
        workspace.deleteFolder(id)
        emit(.structure)
        scheduleSave()
    }

    @discardableResult
    func move(_ id: UUID, to folder: UUID?, at index: Int?) -> Bool {
        guard workspace.move(id, to: folder, at: index) else { return false }
        emit(.structure)
        scheduleSave()
        return true
    }

    func moveSelected(by delta: Int) {
        guard let sel = workspace.selected, let parent = workspace.parent(of: sel) else { return }
        let siblings = workspace.children(of: parent)
        guard let i = siblings.firstIndex(where: { $0.id == sel }) else { return }
        let target = max(0, min(siblings.count - 1, i + delta))
        guard target != i else { return }
        move(sel, to: parent, at: target > i ? target + 1 : target)
    }

    // MARK: Selection

    /// Whether the last selection change should move keyboard focus into the terminal.
    private(set) var selectionWantsFocus = true

    func select(_ id: UUID?, focus: Bool = true) {
        selectionWantsFocus = focus
        // Still queued from the app start: start it now, it's the one being looked at.
        if let id, isPendingRestore(id) { restore(id) }
        let changed = workspace.selected != id
        workspace.selected = id
        if let id, workspace.sessions[id] != nil {
            workspace.sessions[id]?.lastActiveAt = Date()
        }
        emit(.selection)
        markSelectedViewed()
        if changed { scheduleSave() }
    }

    /// Cmd+N: the Nth visible session (collapsed folders skipped); Int.max = last.
    func selectIndex(_ n: Int) {
        let order = workspace.visibleSessionsInOrder
        guard !order.isEmpty else { return }
        select(order[min(max(n, 0), order.count - 1)])
    }

    func selectRelative(_ delta: Int) {
        let order = workspace.openSessionsInOrder
        guard !order.isEmpty else { return }
        let i = workspace.selected.flatMap { order.firstIndex(of: $0) } ?? 0
        select(order[((i + delta) % order.count + order.count) % order.count])
    }

    /// Cycles through sessions that want attention: needs input first, then errors, then unread done.
    func selectNextAttention() {
        let order = workspace.openSessionsInOrder
        let start = workspace.selected.flatMap { order.firstIndex(of: $0) } ?? -1
        let rotated = order.indices.map { order[(start + 1 + $0) % order.count] }
        let ranked = rotated.compactMap { id -> (UUID, Int)? in
            guard let s = live[id]?.status else { return nil }
            let rank = s.activity == .needsInput ? 3 : (s.unread ? s.activity.attentionRank : 0)
            return rank > 0 ? (id, rank) : nil
        }
        if let best = ranked.max(by: { $0.1 < $1.1 }) {
            select(ranked.first { $0.1 == best.1 }?.0)
        } else if let bg = background.first(where: { $0.activity == .needsInput }) {
            attach(bg)
        }
    }

    /// Bottom-bar segments: cycle through sessions in one state (unread only for done).
    func selectNext(activity: Activity, unreadOnly: Bool = false) {
        let order = workspace.openSessionsInOrder
        guard !order.isEmpty else { return }
        let start = workspace.selected.flatMap { order.firstIndex(of: $0) } ?? -1
        for i in 0..<order.count {
            let id = order[(start + 1 + i) % order.count]
            guard let s = live[id]?.status, s.activity == activity, !unreadOnly || s.unread else { continue }
            select(id)
            return
        }
    }

    /// Counts per state for the status line and toolbar.
    var activityCounts: (needsInput: Int, working: Int, doneUnread: Int, error: Int, total: Int) {
        var c = (0, 0, 0, 0, live.count)
        for ls in live.values {
            switch ls.status.activity {
            case .needsInput: c.0 += 1
            case .working: c.1 += 1
            case .done where ls.status.unread: c.2 += 1
            case .error: c.3 += 1
            default: break
            }
        }
        c.0 += unattachedBackground.filter { $0.activity == .needsInput }.count
        return (c.0, c.1, c.2, c.3, c.4)
    }

    /// On screen in the key window of the active app: the selected session, or one sharing its card.
    func isFocused(_ id: UUID) -> Bool {
        guard let sel = workspace.selected, env.appIsActive(), ui?.isWindowKey ?? false else { return false }
        return sel == id || (layoutOwnerOf[id] != nil && layoutOwnerOf[id] == layoutOwnerOf[sel])
    }

    func markSelectedViewed() {
        guard let sel = workspace.selected, live[sel] != nil, isFocused(sel) else { return }
        for id in sideBySide(sel) where live[id] != nil {
            apply(.viewed, to: id)
            removeNotification(id)
        }
    }

    /// True when `responder` is one of the session terminals.
    func isTerminal(_ responder: NSResponder?) -> Bool {
        guard let view = responder as? NSView else { return false }
        return live.values.contains { $0.terminal.view === view }
    }

    // MARK: Status

    func status(_ id: UUID) -> LiveStatus? { live[id]?.status }

    func apply(_ signal: Signal, to id: UUID) {
        guard !terminating, let ls = live[id] else { return }
        let before = ls.status
        StatusReducer.reduce(&ls.status, signal, focused: isFocused(id))
        // A hook is a sign of life even when the status stays "working" (tool after tool in a long turn).
        if case .hook = signal, workspace.settings.keepAwake { updateKeepAwake() }
        guard ls.status != before else { return }
        syncRecord(id, from: ls.status)
        if ls.status.activity != before.activity || ls.status.unread != before.unread || ls.status.promptId != before.promptId {
            notifyIfNeeded(id, before: before, after: ls.status)
            updateBadge()
        }
        emit(.status(id))
    }

    private func syncRecord(_ id: UUID, from s: LiveStatus) {
        guard var r = workspace.sessions[id] else { return }
        let old = r
        if s.agent != .shell {
            // A plain shell turning into an agent session: its shell-era title (the command line that
            // started the agent) doesn't name it; the agent's own title or the directory does.
            if r.agent == .shell { r.autoTitle = "" }
            if r.agent != s.agent { r.agentSessionId = nil; r.agentCwd = nil; r.bgJobId = nil }
            r.agent = s.agent
            r.agentRunning = s.activity != .exited
            if let sid = s.agentSessionId { r.agentSessionId = sid }
            if let dir = s.agentCwd { r.agentCwd = dir }
        } else {
            r.agentRunning = false
        }
        if let t = s.title, !t.isEmpty, r.takesTerminalTitle(fromAgent: s.titleFromAgent) { r.autoTitle = t }
        if let c = s.cwd, !c.isEmpty { r.cwd = c }
        guard r != old else { return }
        workspace.sessions[id] = r
        scheduleSave()
    }

    /// Observes every hook event (benchmarks check the launch script's exit report).
    var onHook: ((HookWire.Message) -> Void)?

    func handleHook(_ msg: HookWire.Message) {
        onHook?(msg)
        // An agent started in a split pane becomes a session of its own.
        if panes[msg.surface] != nil, msg.event.agent != .shell { promotePane(msg.surface, agent: msg.event.agent) }
        apply(.hook(msg.event), to: msg.surface)
        // The exit report ends any launch; other hooks only a fresh start's.
        if msg.event.event == AgentLaunch.exitEvent { launchReady(msg.surface) } else { launchHint(msg.surface) }
        // Not on SessionEnd: the agent is still alive while its end hook runs.
        if msg.event.event == "SessionStart" { detectForeground(msg.surface) }
    }

    func handleKey(_ event: NSEvent, session id: UUID) {
        // Typing into a launching session (Ctrl-C included) shows the terminal; ⌘ shortcuts don't.
        if !event.modifierFlags.contains(.command) { launchReady(id) }
        // Shortcuts (Cmd+2 to look at another session, Cmd+N…) are not answers to a prompt.
        guard event.modifierFlags.isDisjoint(with: [.command, .control, .option]) else { return }
        let code = Int(event.keyCode)
        if code == kVK_Return || code == kVK_ANSI_KeypadEnter {
            apply(.userSubmitted, to: id)
            // A command may have started an agent; check once it had time to exec.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [weak self] in self?.detectForeground(id) }
        } else if code == kVK_Escape {
            apply(.userCancelled, to: id)
        } else if live[id]?.status.activity == .needsInput, let c = event.characters, c.count == 1,
                  let d = c.first, d.isNumber || d == "y" || d == "n" {
            apply(.userSubmitted, to: id)
        }
    }

    func detectForeground(_ id: UUID) {
        guard let ls = live[id] else { return }
        let pid = ls.terminal.foregroundPid
        guard pid > 0, let agent = ProcessInspector.agent(pid: pid) else { return }
        apply(.foregroundProcess(agent), to: id)
    }

    // MARK: Background agents

    /// Job state changes only touch state.json of known jobs: re-read those files directly.
    /// New or removed jobs need names from `claude agents`, so they trigger a full load.
    func backgroundChanged(_ paths: [String]) {
        let jobs = env.jobsDir.resolvingSymlinksInPath().path
        let known = Set(background.map(\.id))
        let onlyStates = paths.allSatisfy { raw in
            let p = URL(fileURLWithPath: raw).resolvingSymlinksInPath().path
            guard p.hasPrefix(jobs + "/"), p.hasSuffix("/state.json") else { return false }
            let id = p.dropFirst(jobs.count + 1).split(separator: "/").first.map(String.init) ?? ""
            return known.contains(id)
        }
        guard onlyStates, !paths.isEmpty else { reloadBackground(); return }
        applyBackground(background.map { BackgroundAgents.refreshState($0, jobsDir: env.jobsDir) })
    }

    private var backgroundCompletions: [() -> Void] = []

    /// Coalesces: a request during a running load schedules one more load; every completion
    /// runs after a load that started after it was requested.
    func reloadBackground(completion: (() -> Void)? = nil) {
        if let completion { backgroundCompletions.append(completion) }
        if backgroundLoading {
            backgroundDirty = true
            return
        }
        backgroundLoading = true
        let waiting = backgroundCompletions
        backgroundCompletions = []
        BackgroundAgents.load(binary: env.claudeBinary, jobsDir: env.jobsDir) { [weak self] agents in
            guard let self else { return }
            self.backgroundLoading = false
            self.applyBackground(agents)
            waiting.forEach { $0() }
            if self.backgroundDirty {
                self.backgroundDirty = false
                self.reloadBackground()
            }
        }
    }

    func applyBackground(_ agents: [BackgroundAgent]) {
        background = agents
        // A closed background session is named after its job unless the user renamed it (open ones
        // follow Claude's own title while attached).
        let names = Dictionary(agents.map { ($0.id, $0.name) }, uniquingKeysWith: { a, _ in a })
        var renamed = false
        for (id, r) in workspace.sessions where r.customName == nil && live[id] == nil {
            guard let job = r.bgJobId, let name = names[job], !name.isEmpty, name != job, r.autoTitle != name else { continue }
            workspace.sessions[id]?.autoTitle = name
            renamed = true
        }
        if renamed { scheduleSave() }
        for (id, ls) in live {
            guard let job = workspace.sessions[id]?.bgJobId, !ls.status.hooksSeen,
                  let agent = agents.first(where: { $0.id == job }) else { continue }
            apply(.backgroundJob(agent.activity, detail: agent.needs), to: id)
        }
        updateBadge()
        emit(.background)
    }

    /// Background agents not already shown as an attached session.
    var unattachedBackground: [BackgroundAgent] {
        let attached = Set(live.keys.compactMap { workspace.sessions[$0]?.bgJobId })
        return background.filter { !attached.contains($0.id) && $0.activity != .exited }
    }

    // MARK: Taking over claude-sessions

    /// Agent session ids Corral already knows (open or closed).
    var knownAgentSessionIds: Set<String> {
        Set(workspace.sessions.values.compactMap(\.agentSessionId))
    }

    /// Creates Corral sessions for the plan's actions (resume / background resume / attach).
    /// Returns the ids to forget in the tracker.
    @discardableResult
    func importTracked(_ plan: TrackerImport.Plan) -> [String] {
        var folder: UUID?? = nil
        if plan.actions.count > 1 {
            // Keep a big takeover together; the user can drag them anywhere afterwards.
            folder = .some(newFolder(name: "From Ghostty"))
        }
        for action in plan.actions {
            let row: TrackerImport.Row
            var job: String?
            switch action {
            case .resume(let r): row = r
            case .resumeBackground(let r), .attach(let r): row = r; job = r.jobId
            }
            newSession(agent: .claude, cwd: row.cwd, folder: folder, title: row.title,
                       input: TrackerImport.input(for: action), agentSessionId: row.sid, bgJobId: job)
            if let id = workspace.selected, !row.title.isEmpty { workspace.sessions[id]?.customName = row.title }
        }
        emit(.structure)
        scheduleSave()
        return plan.forgetIds
    }

    // MARK: Integrations

    func refreshIntegrations() {
        integrations = Integrations.status(paths: env.integrationPaths)
        installedAgents = Self.detectInstalled(env)
        emit(.integrations)
    }

    // MARK: Notifications & badge

    /// What a status change is worth telling the user about, if anything (pure, for tests).
    static func notificationKind(before: LiveStatus, after: LiveStatus) -> NotificationKind? {
        switch after.activity {
        case .needsInput where before.activity != .needsInput:
            return after.need == .permission ? .permission : .question
        case .needsInput where after.promptId != nil && after.promptId != before.promptId:
            // Another permission prompt before Corral saw the last one answered.
            return .permission
        case .done where after.agent == .shell && before.activity != .done,
             .error where after.agent == .shell && before.activity != .error:
            // A plain shell reaches done / error only through a command that ran for a while.
            return .command
        case .done where before.activity == .working && before.compactFrom == nil:
            // A `/compact` ending isn't a finished turn.
            return .finished
        case .error where before.activity != .error:
            return .failed
        default:
            return nil
        }
    }

    /// The notification for `kind`: the session's name as title, what happened below it, the
    /// prompt's text (or the directory) as body.
    static func note(_ kind: NotificationKind, session id: UUID, record: SessionRecord, status: LiveStatus,
                     sound: Bool, details: Bool = true) -> CorralNote {
        let agent = status.agent.displayName
        let subtitle: String
        switch kind {
        case .permission: subtitle = "\(agent) needs permission"
        case .question: subtitle = "\(agent) needs your input"
        case .finished: subtitle = "\(agent) finished"
        case .failed: subtitle = "\(agent) failed"
        case .command: subtitle = status.activity == .error ? "Command failed" : "Command finished"
        }
        let place = RelativeTime.abbreviatePath(status.cwd ?? record.cwd)
        let body = details ? status.detail ?? place : place
        return CorralNote(id: id.uuidString, title: record.displayTitle, subtitle: subtitle, body: body,
                          sound: sound, session: id, prompt: kind == .permission && details ? promptToken(status) : nil)
    }

    /// Identifies the Claude permission prompt up now (`LiveStatus.promptId`, new for every
    /// PermissionRequest); nil when there is none Allow / Deny could answer.
    static func promptToken(_ s: LiveStatus) -> String? {
        guard s.activity == .needsInput, s.need == .permission, s.agent == .claude else { return nil }
        return s.promptId?.uuidString
    }

    enum PromptAnswer { case allow, deny }

    /// Answers the permission prompt a notification was posted for, typing into the session what the
    /// user would: 1 (Yes) or Esc (No, tell Claude what to do instead). Nothing is typed, and false
    /// returned, when that prompt is gone (answered, another one up, session closed).
    @discardableResult
    func answerPrompt(_ answer: PromptAnswer, session id: UUID?, prompt: String?) -> Bool {
        guard let id, let ls = live[id], let prompt, Self.promptToken(ls.status) == prompt,
              ls.terminal.perform(binding: answer == .allow ? "text:1" : "text:\\x1b") else { return false }
        apply(answer == .allow ? .userSubmitted : .userCancelled, to: id)
        return true
    }

    /// A notification clicked or one of its buttons: true when Corral should come forward on the
    /// session (a click, Deny, or Allow for a prompt that is no longer up).
    func respondToNotification(action: String, session id: UUID?, prompt: String?) -> Bool {
        switch action {
        case Notifier.allowAction: return !answerPrompt(.allow, session: id, prompt: prompt)
        case Notifier.denyAction:
            answerPrompt(.deny, session: id, prompt: prompt)
            return true
        default: return true
        }
    }

    private func notifyIfNeeded(_ id: UUID, before: LiveStatus, after: LiveStatus) {
        guard env.notifications else { return }
        let prefs = workspace.settings.notifications
        if let kind = Self.notificationKind(before: before, after: after), prefs[kind].on, !isFocused(id),
           prefs.whileActive || !env.appIsActive(), let record = workspace.sessions[id] {
            env.notifier.post(Self.note(kind, session: id, record: record, status: after, sound: prefs[kind].sound,
                                        details: prefs.showDetails))
        } else if before.activity == .needsInput, after.activity != .needsInput {
            // Answered or gone: its question leaves Notification Center too.
            removeNotification(id)
        }
    }

    private func removeNotification(_ id: UUID) {
        guard env.notifications else { return }
        env.notifier.withdraw([id.uuidString])
    }

    static let testNote = CorralNote(id: "corral-test", title: "Corral", subtitle: "Notifications are on",
                                     body: "Click one to jump straight to its session.", sound: true, session: nil)

    /// Settings › Notifications › Send Test.
    func sendTestNotification() {
        guard env.notifications else { return }
        var note = Self.testNote
        note.sound = NotificationKind.allCases.contains { workspace.settings.notifications[$0].sound }
        env.notifier.post(note)
    }

    /// A clicked notification: select its session and bring it into view in the sidebar.
    func reveal(_ id: UUID) {
        guard let record = workspace.sessions[id], record.closedAt == nil else { return }
        select(id)
        emit(.reveal(id))
    }

    var needsInputCount: Int {
        live.values.filter { $0.status.activity == .needsInput }.count
            + unattachedBackground.filter { $0.activity == .needsInput }.count
    }

    private func updateBadge() {
        let n = needsInputCount
        env.setBadge(n > 0 ? "\(n)" : nil)
    }

    // MARK: Persistence

    func scheduleSave() {
        saveWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.saveNow() }
        saveWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: work)
    }

    private let saveQueue = DispatchQueue(label: "corral.save", qos: .utility)

    /// Encodes and writes off the main thread (Workspace is a value: the snapshot is cheap).
    func saveNow(wait: Bool = false) {
        saveWork?.cancel()
        let snapshot = workspace
        let store = env.store
        let write = {
            do { try store.save(snapshot) } catch { NSLog("Corral: save failed: \(error)") }
        }
        if wait { saveQueue.sync(execute: write) } else { saveQueue.async(execute: write) }
    }

    // MARK: TerminalActionHandler

    /// Observes every terminal action (benchmarks measure shell-ready and command round trips).
    var onTerminalAction: ((UUID?, TerminalAction) -> Void)?

    func perform(_ action: TerminalAction, terminal: TerminalSurface?) -> Bool {
        if let terminal, let pane = panes[terminal.sessionId], let handled = performInPane(action, pane: pane) {
            onTerminalAction?(terminal.sessionId, action)
            return handled
        }
        let id = terminal?.sessionId
        onTerminalAction?(id, action)
        switch action {
        case .newSession:
            newSession(agent: .shell)
        case .closeSession:
            guard let id else { return false }
            requestClose(id)
        case .gotoSession(let n):
            switch n {
            case -1: selectRelative(-1)
            case -2: selectRelative(1)
            case -3: selectIndex(Int.max)
            default: selectIndex(n - 1)
            }
        case .moveSession(let amount):
            moveSelected(by: amount)
        case .toggleFullscreen:
            ui?.toggleFullscreen()
        case .commandPalette:
            ui?.showSessionSearch()
        case .setTitle(let t):
            guard let id else { return false }
            let before = live[id]?.status.title
            apply(.terminalTitle(t), to: id)
            launchHint(id)
            // Shell integration retitles on every command start: a cheap hint an agent may have started.
            if live[id]?.status.title != before { detectForeground(id) }
        case .pwd(let p):
            guard let id else { return false }
            apply(.pwd(p), to: id)
        case .desktopNotification(let title, let body):
            guard let id else { return false }
            apply(.desktopNotification(title: title, body: body), to: id)
        case .bell:
            guard let id else { return false }
            apply(.bell, to: id)
        case .progress(let state):
            guard let id else { return false }
            apply(.progress(state), to: id)
        case .commandFinished(let code, let seconds):
            guard let id else { return false }
            apply(.commandFinished(exitCode: code, seconds: seconds), to: id)
            detectForeground(id)
        case .childExited:
            if let id {
                apply(.processExited, to: id)
                launchReady(id)
            }
            // Let Ghostty print its own exit / abnormal-exit message into the terminal.
            return false
        case .openURL(let s, let kind):
            // Ghostty calls this with the surface's renderer lock held: any modal UI here would
            // freeze that terminal (and can deadlock). Decide on the next runloop turn.
            DispatchQueue.main.async { [weak self] in self?.openURL(s, kind: kind) }
        case .openConfig:
            let path = terminals.configPath
            if !path.isEmpty { env.openURL(URL(fileURLWithPath: path)) }
        case .reloadConfig:
            reloadTerminalConfig()
        case .startSearch, .endSearch, .searchTotal, .searchSelected:
            guard let terminal else { return false }
            ui?.findAction(action, terminal: terminal)
        case .undoClose:
            return reopenLastClosed(within: 600)
        case .quit:
            env.terminate()
        case .configChanged:
            emit(.appearance)
        case .newSplit(let direction):
            guard let id else { return false }
            split(id, direction: direction)
        case .gotoSplit(let target):
            guard let id else { return false }
            moveFocus(target, in: id)
        }
        return true
    }

    /// Actions from a split pane: its own life cycle, splitting and focus, and agent detection.
    /// Nil hands the rest (new session, links, search, config…) to the normal handling.
    private func performInPane(_ action: TerminalAction, pane: Pane) -> Bool? {
        switch action {
        case .closeSession:
            // Ghostty is inside this surface's key handling: never free it from here.
            DispatchQueue.main.async { [weak self] in self?.requestClosePane(pane.id) }
        case .childExited:
            // Ghostty closes the surface itself after this callback; the close request closes the pane.
            return false
        case .newSplit(let direction):
            split(pane.owner, from: pane.id, direction: direction)
        case .gotoSplit(let target):
            moveFocus(target, in: focusKey(onCardOf: pane.owner), from: pane.id)
        case .pwd(let p):
            paneCwd[pane.id] = p
        case .setTitle, .commandFinished:
            // Shell integration retitles on command start: an agent may have started in the pane.
            let pid = pane.terminal.foregroundPid
            if pid > 0, let agent = ProcessInspector.agent(pid: pid) { promotePane(pane.id, agent: agent) }
        case .desktopNotification, .bell, .progress:
            break
        default:
            return nil
        }
        return true
    }

    /// The record names an agent session whose transcript is definitely not there (Claude: no
    /// `<projects>/*/<id>.jsonl`; PI: no session file). Anything uncertain keeps the record: an
    /// unreadable or missing projects folder (e.g. CLAUDE_CONFIG_DIR only set in the shell), a
    /// background job (reopen attaches; its id may be the job's), OpenCode (its own database).
    /// `claude`: a listing from `claudeTranscripts` when checking many records at once.
    func missingTranscript(_ r: SessionRecord, claude: Set<String>?? = .none) -> Bool {
        guard let sid = r.agentSessionId, !sid.isEmpty, r.bgJobId == nil else { return false }
        switch r.agent {
        case .claude:
            if let listing = claude {
                guard let names = listing else { return false }
                return !names.contains("\(sid).jsonl")
            }
            // One record (a close): look for the one file in each project folder.
            let root = env.roots.claudeProjects
            let fm = FileManager.default
            guard let dirs = try? fm.contentsOfDirectory(atPath: root.path) else { return false }
            return !dirs.contains { fm.fileExists(atPath: root.appendingPathComponent($0).appendingPathComponent("\(sid).jsonl").path) }
        case .pi: return sid.hasPrefix("/") && !FileManager.default.fileExists(atPath: sid)
        case .opencode, .shell: return false
        }
    }

    /// File names of all Claude transcripts (`<id>.jsonl` in each project folder), or nil when the
    /// projects folder can't be read (then nothing may be called missing).
    static func claudeTranscripts(root: URL) -> Set<String>? {
        let fm = FileManager.default
        guard let dirs = try? fm.contentsOfDirectory(atPath: root.path) else { return nil }
        var names = Set<String>()
        for d in dirs {
            guard let files = try? fm.contentsOfDirectory(atPath: root.appendingPathComponent(d).path) else { continue }
            names.formUnion(files.lazy.filter { $0.hasSuffix(".jsonl") })
        }
        return names
    }

    // MARK: Split panes and side-by-side sessions

    /// Leaf → the session whose card holds it (the holder maps to itself), for every split card.
    private var layoutOwnerOf: [UUID: UUID] = [:]

    /// The session whose card shows `id` (a session or a pane) split with others; nil when alone.
    func layoutOwner(of id: UUID) -> UUID? { layoutOwnerOf[id] }

    /// The sessions on `id`'s card in reading order (itself included), just `[id]` when alone.
    func sideBySide(_ id: UUID) -> [UUID] {
        guard let owner = layoutOwnerOf[id], let layout = paneLayouts[owner] else { return [id] }
        return layout.leaves.filter { panes[$0] == nil }
    }

    /// The only place card layouts change: keeps the leaf index and the saved side-by-side state in step.
    private func setLayout(_ layout: PaneLayout?, for owner: UUID) {
        for leaf in paneLayouts[owner]?.leaves ?? [] where layoutOwnerOf[leaf] == owner { layoutOwnerOf[leaf] = nil }
        let kept = layout?.isSplit == true ? layout : nil
        paneLayouts[owner] = kept
        for leaf in kept?.leaves ?? [] { layoutOwnerOf[leaf] = owner }
        saveSplits()
    }

    /// Persists which sessions share a card (shells in panes are throwaway and not kept).
    private func saveSplits() {
        let splits = paneLayouts.compactMapValues { $0.filtered { panes[$0] == nil } }
        guard splits.filter({ $0.value.isSplit }) != workspace.splits else { return }
        workspace.setSplits(splits)
        scheduleSave()
    }

    /// Whose focus memory a terminal on `owner`'s card writes: the selected session's when it is on
    /// that card, else the holder's.
    private func focusKey(onCardOf owner: UUID) -> UUID {
        if let sel = workspace.selected, (layoutOwnerOf[sel] ?? sel) == owner { return sel }
        return owner
    }

    /// The leaf of `session`'s card that has (or last had) focus for it: a pane, else its own terminal.
    private func focusedLeaf(_ session: UUID) -> UUID {
        if let id = focusedTerminalId[session], panes[id] != nil, layoutOwnerOf[id] == layoutOwnerOf[session] { return id }
        return session
    }

    /// The terminal of `session` that has (or last had) keyboard focus: the session's own or a pane.
    func focusedTerminal(_ session: UUID) -> TerminalSurface? {
        panes[focusedLeaf(session)]?.terminal ?? live[session]?.terminal
    }

    /// Pane whose terminal view contains `view` (keyboard focus), if any.
    func pane(containing view: NSView) -> Pane? {
        panes.values.first { view === $0.terminal.view || view.isDescendant(of: $0.terminal.view) }
    }

    /// Splits the focused terminal on `session`'s card (or `from`) with a new shell in its directory.
    func split(_ session: UUID, from target: UUID? = nil, direction: SplitDirection) {
        guard live[session] != nil else { return }
        let owner = layoutOwnerOf[session] ?? session
        let target = target ?? focusedLeaf(session)
        let layout = paneLayouts[owner] ?? .leaf(owner)
        guard layout.contains(target) else { return }
        let id = UUID()
        let cwd = paneCwd[target] ?? live[target]?.status.cwd ?? workspace.sessions[target]?.cwd ?? NSHomeDirectory()
        var vars = ["CORRAL_SOCKET": env.socketPath]
        if let hook = env.hookBinary { vars["CORRAL_HOOK"] = hook }
        let terminal = terminals.makeTerminal(sessionId: id, launch: LaunchSpec(cwd: cwd, env: vars))
        terminal.onFocus = { [weak self] in self?.paneFocused(id) }
        panes[id] = Pane(id: id, owner: owner, terminal: terminal)
        paneCwd[id] = cwd
        setLayout(layout.splitting(target, with: id, direction: direction), for: owner)
        focusedTerminalId[focusKey(onCardOf: owner)] = id
        emit(.panes(owner))
    }

    private func paneFocused(_ id: UUID) {
        guard let owner = panes[id]?.owner else { return }
        focusedTerminalId[focusKey(onCardOf: owner)] = id
    }

    /// Closes a pane, asking first when something runs in it.
    func requestClosePane(_ id: UUID) {
        guard let pane = panes[id] else { return }
        guard pane.terminal.needsConfirmQuit else { closePane(id); return }
        ui?.confirm(title: "Close this pane?", message: "A process is still running in it.", button: "Close") { [weak self] ok in
            if ok { self?.closePane(id) }
        }
    }

    func closePane(_ id: UUID) {
        guard let pane = detachPane(id) else { return }
        paneCwd[id] = nil
        pane.terminal.destroy()
        pane.terminal.view.removeFromSuperview()
        emit(.panes(pane.owner))
    }

    /// Moves focus `offset` terminals along `session`'s card (⌘] / ⌘[). Landing on another session
    /// selects it.
    func focusPane(in session: UUID, offset: Int) {
        guard let owner = layoutOwnerOf[session], let layout = paneLayouts[owner],
              let next = layout.neighbor(of: focusedLeaf(session), offset: offset) else { return }
        focus(leaf: next, from: session)
    }

    /// ⌘] / ⌘[ along the card, ⌥⌘ arrows to the terminal on that side of the focused one (`from`, else
    /// the session's focused leaf). Off the card's top or bottom edge, or with no card, ↑ / ↓ go on to
    /// the previous / next session in the sidebar; ← / → stop at the edge.
    /// `focusTerminal` false (the sidebar has the keyboard): only the selection moves, across sessions
    /// (panes are skipped), and the keyboard stays where it is.
    func moveFocus(_ target: SplitFocus, in session: UUID, from leaf: UUID? = nil, focusTerminal: Bool = true) {
        switch target {
        case .previous: focusPane(in: session, offset: -1)
        case .next: focusPane(in: session, offset: 1)
        case .toward(let direction):
            if let next = cardNeighbor(of: session, from: leaf, toward: direction, sessionsOnly: !focusTerminal) {
                if focusTerminal { focus(leaf: next, from: session) } else { select(next, focus: false) }
            } else if direction == .up || direction == .down {
                selectAdjacentSession(to: session, forward: direction == .down, focus: focusTerminal)
            }
        }
    }

    /// Where focus was on each card before the last arrow move: a tie goes back there (a round trip
    /// returns where it started).
    private var cameFrom: [UUID: UUID] = [:]

    private func cardNeighbor(of session: UUID, from leaf: UUID?, toward direction: SplitDirection, sessionsOnly: Bool) -> UUID? {
        guard let owner = layoutOwnerOf[session], var layout = paneLayouts[owner] else { return nil }
        let start = sessionsOnly ? session : leaf ?? focusedLeaf(session)
        if sessionsOnly, let sessions = layout.filtered({ panes[$0] == nil }) { layout = sessions }
        let next = layout.neighbor(of: start, toward: direction, boxes: ui?.cardBoxes(owner), prefer: cameFrom[owner])
        if next != nil { cameFrom[owner] = start }
        return next
    }

    /// The previous / next session in the sidebar among the rows on screen (collapsed folders skipped),
    /// passing over the sessions on `session`'s own card. No wrap-around: an arrow stops at the end.
    func selectAdjacentSession(to session: UUID, forward: Bool, focus: Bool = true) {
        let order = workspace.openSessionsInOrder
        guard let i = order.firstIndex(of: session) else { return }
        let shown = Set(workspace.visibleSessionsInOrder)
        let card = Set(sideBySide(session))
        let rest = forward ? Array(order[(i + 1)...]) : Array(order[..<i].reversed())
        guard let target = rest.first(where: { shown.contains($0) && !card.contains($0) }) else { return }
        select(target, focus: focus)
    }

    /// Puts keyboard focus on `leaf` of `session`'s card: a pane, the session itself, or another session
    /// on the card (which becomes the selected one).
    private func focus(leaf next: UUID, from session: UUID) {
        if let pane = panes[next] {
            focusedTerminalId[session] = next
            ui?.focus(terminal: pane.terminal)
        } else if next == session {
            focusedTerminalId[session] = session
            ui?.focus(terminal: live[session]?.terminal)
        } else {
            focusedTerminalId[next] = next
            select(next)
        }
    }

    /// An agent started in a pane: the pane becomes a session of its own (listed right after the
    /// card's holder, its status in the sidebar like any agent's) and stays where it is on the card.
    func promotePane(_ id: UUID, agent: AgentKind) {
        guard agent != .shell, let pane = panes.removeValue(forKey: id) else { return }
        let owner = pane.owner
        let cwd = paneCwd.removeValue(forKey: id) ?? live[owner]?.status.cwd ?? NSHomeDirectory()
        let record = SessionRecord(id: id, cwd: cwd, agent: agent)
        let parent = workspace.parent(of: owner) ?? nil
        let index = workspace.children(of: parent).firstIndex { $0.id == owner }.map { $0 + 1 }
        workspace.addSession(record, in: parent, at: index)
        let ls = LiveSession(id: id, terminal: pane.terminal)
        ls.status.cwd = cwd
        wire(ls)
        live[id] = ls
        apply(.foregroundProcess(agent), to: id)
        for (key, leaf) in focusedTerminalId where leaf == id { focusedTerminalId[key] = key }
        focusedTerminalId[id] = id
        saveSplits()
        // The user is on this card when the agent started where they typed: follow it.
        let here = workspace.selected.map { (layoutOwnerOf[$0] ?? $0) == owner } ?? false
        emit(.panes(owner))
        emit(.structure)
        if here { select(id) }
        scheduleSave()
    }

    /// Shows open session `id` on `target`'s card, on its `direction` side (a half of the whole card),
    /// and selects it. A session alone with its shells brings them along; one sharing a card with
    /// other sessions leaves that card to them.
    func showBeside(_ id: UUID, of target: UUID, direction: SplitDirection = .right) {
        guard id != target, live[id] != nil, live[target] != nil else { return }
        let owner = layoutOwnerOf[target] ?? target
        guard layoutOwnerOf[id] != owner else { return }
        var moving = PaneLayout.leaf(id)
        if let own = paneLayouts[id], !own.leaves.contains(where: { $0 != id && panes[$0] == nil }) {
            moving = own
            setLayout(nil, for: id)
            for (pid, p) in panes where p.owner == id { panes[pid]?.owner = owner }
        } else {
            leaveCard(id)
        }
        let base = paneLayouts[owner] ?? .leaf(owner)
        setLayout(base.adding(moving, direction: direction), for: owner)
        focusedTerminalId[id] = moving == .leaf(id) ? id : focusedTerminalId[id]
        emit(.panes(owner))
        emit(.panes(id))
        select(id)
    }

    /// Takes session `id` off a card it shares with other sessions: it shows alone again (with no
    /// panes), the card goes on without it.
    func showSeparately(_ id: UUID) {
        guard sideBySide(id).count > 1 else { return }
        leaveCard(id)
        focusedTerminalId[id] = id
        if workspace.selected == id { emit(.selection) }
    }

    /// Takes `id` out of its card. A holder hands the card (and its shells) to the next session on it;
    /// with none left, false: the card is the holder's own (only its shells).
    @discardableResult
    private func leaveCard(_ id: UUID) -> Bool {
        guard let owner = layoutOwnerOf[id], let layout = paneLayouts[owner] else { return false }
        let rest = layout.removing(id)
        if owner != id {
            setLayout(rest, for: owner)
            emit(.panes(owner))
            return true
        }
        guard let next = rest?.leaves.first(where: { panes[$0] == nil }) else { return false }
        setLayout(nil, for: id)
        setLayout(rest, for: next)
        for (pid, p) in panes where p.owner == id { panes[pid]?.owner = next }
        if let f = focusedTerminalId[id], panes[f] != nil { focusedTerminalId[next] = f }
        emit(.panes(next))
        emit(.panes(id))
        return true
    }

    /// Takes a pane out of its card and the registry (the terminal stays alive).
    private func detachPane(_ id: UUID) -> Pane? {
        guard let pane = panes.removeValue(forKey: id) else { return nil }
        let rest = paneLayouts[pane.owner]?.removing(id)
        setLayout(rest, for: pane.owner)
        for (key, leaf) in focusedTerminalId where leaf == id {
            focusedTerminalId[key] = rest?.leaves.last { panes[$0] != nil } ?? key
        }
        return pane
    }

    /// A session closes: it leaves a card it shares; alone (or with only its shells), its panes close.
    private func closePanes(of session: UUID) {
        if leaveCard(session) {
            focusedTerminalId[session] = nil
            return
        }
        for pane in panes.values where pane.owner == session {
            panes[pane.id] = nil
            paneCwd[pane.id] = nil
            pane.terminal.destroy()
            pane.terminal.view.removeFromSuperview()
        }
        focusedTerminalId[session] = nil
        // The window drops the session's split host (else a reopen would find the stale one).
        if paneLayouts[session] != nil {
            setLayout(nil, for: session)
            emit(.panes(session))
        }
    }

    /// Callbacks every session terminal gets (also a promoted pane's).
    private func wire(_ ls: LiveSession) {
        let id = ls.id
        ls.terminal.onKeyDown = { [weak self] event in self?.handleKey(event, session: id) }
        ls.terminal.onFocus = { [weak self] in
            guard let self else { return }
            self.focusedTerminalId[id] = id
            if let sel = self.workspace.selected, sel != id, let owner = self.layoutOwnerOf[id], self.layoutOwnerOf[sel] == owner {
                // Clicked into another session on the card: the selection follows the keyboard.
                self.select(id, focus: false)
                return
            }
            guard self.workspace.selected == id else { return }
            self.apply(.viewed, to: id)
        }
    }

    /// Links printed by programs (OSC 8) or detected in output are untrusted: same policy as
    /// Ghostty.app (allow web/mail, confirm other schemes, refuse executables and odd characters).
    func openURL(_ raw: String, kind: URLKind) {
        var target = raw
        if URL(string: raw)?.scheme == nil, !UntrustedURL.containsUnsafeCharacters(raw) {
            target = URL(fileURLWithPath: (raw as NSString).standardizingPath).absoluteString
        }
        if kind == .text || kind == .html, let url = URL(string: target) {
            env.openURL(url)
            return
        }
        let untrusted = UntrustedURL(target)
        switch untrusted.decision {
        case .allow(let url):
            env.openURL(url)
        case .confirm(let url):
            ui?.confirm(title: "Open this link?", message: untrusted.displayString, button: "Open") { [env] ok in
                if ok { env.openURL(url) }
            }
        case .deny(let reason):
            env.alert("Link blocked", "\(untrusted.displayString)\n\n\(reason.message)")
        }
    }

    func reloadTerminalConfig() {
        terminals.reloadConfig()
        emit(.appearance)
    }

    func closeRequested(_ terminal: TerminalSurface, processAlive: Bool) {
        if panes[terminal.sessionId] != nil {
            if processAlive { requestClosePane(terminal.sessionId) } else { closePane(terminal.sessionId) }
            return
        }
        guard live[terminal.sessionId] != nil else { return }
        if processAlive { requestClose(terminal.sessionId) } else { close(terminal.sessionId) }
    }
}
