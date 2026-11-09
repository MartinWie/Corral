import AppKit
import CorralCore

/// What to start in a new terminal.
public struct LaunchSpec: Equatable {
    public var cwd: String
    /// Typed into the shell after it starts (typed fallback for non-zsh login shells).
    public var initialInput: String?
    /// Terminal command instead of the login shell (direct agent launch, see `AgentLaunch`).
    public var command: String?
    /// The agent command line this terminal starts, however it is delivered (e.g. "claude --resume …").
    public var agentInput: String?
    public var env: [String: String]

    public init(cwd: String, initialInput: String? = nil, command: String? = nil, agentInput: String? = nil,
                env: [String: String] = [:]) {
        self.cwd = cwd
        self.initialInput = initialInput
        self.command = command
        self.agentInput = agentInput
        self.env = env
    }
}

/// One terminal the session manager drives. The app implements it with libghostty
/// (TerminalView); tests use a fake, so everything above the terminal is testable headlessly.
public protocol TerminalSurface: AnyObject {
    var sessionId: UUID { get }
    var view: NSView { get }
    /// Process in the terminal's foreground (the shell or what it runs).
    var foregroundPid: pid_t { get }
    /// A process other than the idle shell is running.
    var needsConfirmQuit: Bool { get }
    /// Non-composing key presses that aren't shortcuts.
    var onKeyDown: ((NSEvent) -> Void)? { get set }
    var onFocus: (() -> Void)? { get set }
    /// Scrollback + screen as plain text.
    func screenText() -> String
    /// Just what is on screen (cheap: no scrollback), for the launch probe.
    func viewportText() -> String
    @discardableResult func perform(binding: String) -> Bool
    func setVisible(_ visible: Bool)
    /// Ends the terminal (kills its processes). Idempotent.
    func destroy()
}

public protocol TerminalFactory: AnyObject {
    var actionHandler: TerminalActionHandler? { get set }
    func makeTerminal(sessionId: UUID, launch: LaunchSpec) -> TerminalSurface
    var backgroundColor: NSColor? { get }
    /// Terminal foreground; the chrome's text colors derive from it.
    var foregroundColor: NSColor? { get }
    /// Ghostty `window-theme` (auto, system, light, dark, ghostty).
    var windowTheme: String? { get }
    var configPath: String { get }
    func reloadConfig()
}

public extension TerminalSurface {
    func viewportText() -> String { screenText() }
}

public extension TerminalFactory {
    var foregroundColor: NSColor? { nil }
    var windowTheme: String? { nil }
}

/// Ghostty settings Corral layers on top of the user's Ghostty config (loaded after it, before
/// ~/.config/corral/ghostty, which can undo them).
public enum GhosttyDefaults {
    /// Ghostty's *performable* bindings are handled by the terminal itself instead of the menu.
    /// Two collide with Corral's menu: ⌘K (`clear_screen`; Corral: Search All Sessions, Clear Screen
    /// is ⇧⌘K) and ⇧⌘T (`undo`; Corral: Reopen Closed Session). Files pulled in through a
    /// `config-file` include load after these and can bind the keys again.
    public static let base = """
    # Written by Corral on every launch; put your own overrides in ~/.config/corral/ghostty.
    keybind = super+k=unbind
    keybind = super+shift+t=unbind

    """

    /// The user's Corral-only Ghostty overrides, loaded after everything else.
    public static var overridesURL: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".config/corral/ghostty")
    }

    /// Ghostty triggers of keys a customized Corral shortcut moved to or away from (`ShortcutStore`).
    public static var unbinds: [String] = []

    /// The user's `shell-integration-features` as Ghostty reports it (bits in field order), read from
    /// their config before Corral's defaults load; nil when unknown.
    public static var userShellFeatures: UInt32?

    /// `shell-integration-features` fields in Ghostty's bit order.
    static let shellFeatureNames = ["cursor", "sudo", "title", "ssh-env", "ssh-terminfo", "path"]

    /// Ghostty's ssh-env / ssh-terminfo wrap `ssh` in `ghostty +ssh`, and Corral ships no `ghostty`
    /// CLI: every `ssh` would fail. With either on, the user's features minus those two (a value
    /// replaces all flags, so the others are spelled out as they were).
    public static func shellFeaturesLine(_ bits: UInt32?) -> String? {
        guard let bits, bits & (1 << 3 | 1 << 4) != 0 else { return nil }
        let parts = shellFeatureNames.enumerated().map { i, name in
            name.hasPrefix("ssh-") || bits & (1 << UInt32(i)) == 0 ? "no-\(name)" : name
        }
        return "shell-integration-features = " + parts.joined(separator: ",")
    }

    /// The `shell-integration-features` layout this code knows (`shellFeatureNames`): what Ghostty
    /// reports for an empty config. Another value means the fields changed: no override then.
    public static let defaultShellFeatures: UInt32 = 0b100101

    public static var config: String {
        guard !unbinds.isEmpty else { return base }
        return base + "# Customized Corral shortcuts (Settings › Shortcuts)\n"
            + unbinds.map { "keybind = \($0)=unbind\n" }.joined()
    }

    /// Loaded after everything else, `config-file` includes too: they could turn ssh-env back on.
    public static var lateConfig: String? {
        shellFeaturesLine(userShellFeatures).map { "# ssh would run `ghostty +ssh`, which Corral doesn't ship\n\($0)\n" }
    }

    /// Ghostty's default config files (it writes a template into Application Support when none exists:
    /// Corral then loads none, so a Mac without Ghostty gets no Ghostty folder).
    public static func userConfigFiles(home: URL = FileManager.default.homeDirectoryForCurrentUser,
                                       xdgConfig: String? = ProcessInfo.processInfo.environment["XDG_CONFIG_HOME"]) -> [String] {
        let xdg = xdgConfig.flatMap { $0.isEmpty ? nil : URL(fileURLWithPath: $0) } ?? home.appendingPathComponent(".config")
        let support = home.appendingPathComponent("Library/Application Support/com.mitchellh.ghostty")
        return [xdg.appendingPathComponent("ghostty"), support]
            .flatMap { [$0.appendingPathComponent("config"), $0.appendingPathComponent("config.ghostty")] }
            .map(\.path).filter { FileManager.default.fileExists(atPath: $0) }
    }

    /// The Ghostty config file to show and open, as Ghostty picks it (`edit.zig`: Application Support
    /// before XDG, `config.ghostty` before `config`, the first non-empty one, else the first that
    /// exists), without creating one; "" when there is none.
    public static func editableConfigPath(home: URL = FileManager.default.homeDirectoryForCurrentUser,
                                          xdgConfig: String? = ProcessInfo.processInfo.environment["XDG_CONFIG_HOME"]) -> String {
        let xdg = xdgConfig.flatMap { $0.isEmpty ? nil : URL(fileURLWithPath: $0) } ?? home.appendingPathComponent(".config")
        let support = home.appendingPathComponent("Library/Application Support/com.mitchellh.ghostty")
        let candidates = [support, xdg.appendingPathComponent("ghostty")]
            .flatMap { [$0.appendingPathComponent("config.ghostty"), $0.appendingPathComponent("config")] }.map(\.path)
        let existing = candidates.filter { FileManager.default.fileExists(atPath: $0) }
        let size = { (p: String) in (try? FileManager.default.attributesOfItem(atPath: p)[.size] as? Int) ?? 0 }
        return existing.first { size($0) > 0 } ?? existing.first ?? ""
    }

    /// Writes `config` into `dir` and returns its path, or nil when it can't be written.
    public static func write(to dir: URL = CorralPaths.support) -> String? {
        save(config, as: "ghostty-defaults", in: dir)
    }

    /// Writes `lateConfig` (empty when there is none) and returns its path.
    public static func writeLate(to dir: URL = CorralPaths.support) -> String? {
        save(lateConfig ?? "", as: "ghostty-late", in: dir)
    }

    private static func save(_ text: String, as name: String, in dir: URL) -> String? {
        let file = dir.appendingPathComponent(name)
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            if (try? String(contentsOf: file, encoding: .utf8)) != text {
                try text.write(to: file, atomically: true, encoding: .utf8)
            }
            return file.path
        } catch {
            NSLog("Corral: can't write Ghostty \(name): \(error)")
            return nil
        }
    }
}

public enum URLKind: Equatable, Sendable { case text, html, osc8, unknown }

/// Terminal requests the host handles (Ghostty actions translated to Corral's vocabulary).
public enum TerminalAction: Equatable {
    case newSession
    case closeSession
    /// 1-based index, or -1 previous, -2 next, -3 last.
    case gotoSession(Int)
    case moveSession(Int)
    case toggleFullscreen
    case commandPalette
    case setTitle(String)
    case pwd(String)
    case desktopNotification(title: String, body: String)
    case bell
    case progress(Signal.ProgressState)
    case commandFinished(exitCode: Int?, seconds: Double)
    case childExited
    case openURL(String, kind: URLKind)
    case openConfig
    case reloadConfig
    case startSearch(String?)
    case endSearch
    case searchTotal(Int)
    case searchSelected(Int)
    case undoClose
    case quit
    /// The effective terminal config changed (e.g. a light/dark conditional theme flipped).
    case configChanged
    /// Split the focused terminal (⌘D right, ⇧⌘D down) with a pane.
    case newSplit(SplitDirection)
    /// Move focus across the card: previous / next in reading order, or to a side.
    case gotoSplit(SplitFocus)
}

public protocol TerminalActionHandler: AnyObject {
    /// Returns whether the host handled the action (false lets the terminal fall back).
    func perform(_ action: TerminalAction, terminal: TerminalSurface?) -> Bool
    func closeRequested(_ terminal: TerminalSurface, processAlive: Bool)
}
