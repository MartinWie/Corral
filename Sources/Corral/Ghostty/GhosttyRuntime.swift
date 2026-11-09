import AppKit
import CorralCore
import CorralKit
import GhosttyKit
import UniformTypeIdentifiers

/// Owns the libghostty app and config, and bridges C callbacks to Swift.
final class GhosttyRuntime: TerminalFactory {
    private(set) var app: ghostty_app_t?
    private(set) var config: ghostty_config_t?
    /// Resolved config from CONFIG_CHANGE (conditional light/dark themes); the file config can be unresolved.
    private var effectiveConfig: ghostty_config_t?
    weak var actionHandler: TerminalActionHandler?

    func makeTerminal(sessionId: UUID, launch: LaunchSpec) -> TerminalSurface {
        TerminalView(runtime: self, sessionId: sessionId, launch: launch)
    }

    init() {
        config = Self.loadConfig()
        guard let config else { return }

        var runtime = ghostty_runtime_config_s(
            userdata: Unmanaged.passUnretained(self).toOpaque(),
            supports_selection_clipboard: true,
            wakeup_cb: { userdata in
                guard let userdata else { return }
                let rt = Unmanaged<GhosttyRuntime>.fromOpaque(userdata).takeUnretainedValue()
                DispatchQueue.main.async { rt.tick() }
            },
            action_cb: { app, target, action in
                guard let app, let ud = ghostty_app_userdata(app) else { return false }
                let rt = Unmanaged<GhosttyRuntime>.fromOpaque(ud).takeUnretainedValue()
                return rt.handle(target: target, action: action)
            },
            read_clipboard_cb: { userdata, location, state, mimes, mimesLen, list in
                Clipboard.read(userdata, location: location, state: state, mimes: mimes, mimesLen: mimesLen, list: list)
            },
            confirm_read_clipboard_cb: { userdata, confirm, state, request in
                Clipboard.confirmRead(userdata, confirm: confirm, state: state, request: request)
            },
            write_clipboard_cb: { userdata, location, content, len, confirm in
                Clipboard.write(userdata, location: location, content: content, len: len, confirm: confirm)
            },
            close_surface_cb: { userdata, processAlive in
                guard let userdata else { return }
                // Never close inside the callback: it can run from within ghostty_surface_key
                // (Cmd+W binding) and freeing the surface there pulls it out from under its caller.
                let view = Unmanaged<TerminalView>.fromOpaque(userdata).takeUnretainedValue()
                DispatchQueue.main.async { [weak view] in
                    guard let view, view.surface != nil else { return }
                    view.runtime?.actionHandler?.closeRequested(view, processAlive: processAlive)
                }
            })

        app = ghostty_app_new(&runtime, config)
        if let app {
            ghostty_app_set_focus(app, NSApp.isActive)
            updateColorScheme()
        }

        let nc = NotificationCenter.default
        nc.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
            if let app = self?.app { ghostty_app_set_focus(app, true) }
        }
        nc.addObserver(forName: NSApplication.didResignActiveNotification, object: nil, queue: .main) { [weak self] _ in
            if let app = self?.app { ghostty_app_set_focus(app, false) }
        }
        nc.addObserver(forName: NSTextInputContext.keyboardSelectionDidChangeNotification, object: nil, queue: .main) { [weak self] _ in
            if let app = self?.app { ghostty_app_keyboard_changed(app) }
        }
        DistributedNotificationCenter.default().addObserver(
            forName: Notification.Name("AppleInterfaceThemeChangedNotification"), object: nil, queue: .main
        ) { [weak self] _ in self?.updateColorScheme() }
    }

    func tick() {
        if let app { ghostty_app_tick(app) }
    }

    func updateColorScheme() {
        guard let app else { return }
        let dark = NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        ghostty_app_set_color_scheme(app, dark ? GHOSTTY_COLOR_SCHEME_DARK : GHOSTTY_COLOR_SCHEME_LIGHT)
    }

    // MARK: Config

    /// `shell-integration-features` from the user's own config files (a separate pass: Corral's
    /// defaults depend on it).
    static func userShellFeatures() -> UInt32? {
        // Only for the field layout `GhosttyDefaults.shellFeatureNames` describes.
        guard shellFeatures(loadingUserFiles: false) == GhosttyDefaults.defaultShellFeatures else { return nil }
        return shellFeatures(loadingUserFiles: true)
    }

    private static func shellFeatures(loadingUserFiles: Bool) -> UInt32? {
        guard let cfg = ghostty_config_new() else { return nil }
        defer { ghostty_config_free(cfg) }
        if loadingUserFiles { loadLayers(cfg) }
        ghostty_config_finalize(cfg)
        var bits: UInt32 = 0
        let key = "shell-integration-features"
        return ghostty_config_get(cfg, &bits, key, UInt(key.utf8.count)) ? bits : nil
    }

    /// Every layer but the late fixes, the same for both passes: Ghostty's default files (only when one
    /// exists, else Ghostty writes a template config), Corral's defaults, the user's Corral overrides,
    /// then `config-file` includes.
    private static func loadLayers(_ cfg: ghostty_config_t) {
        if !GhosttyDefaults.userConfigFiles().isEmpty { ghostty_config_load_default_files(cfg) }
        if let defaults = GhosttyDefaults.write() { ghostty_config_load_file(cfg, defaults) }
        let override = GhosttyDefaults.overridesURL.path
        if FileManager.default.fileExists(atPath: override) { ghostty_config_load_file(cfg, override) }
        ghostty_config_load_recursive_files(cfg)
    }

    /// The user's Ghostty config (~/.config/ghostty/config and the macOS app-support path), then
    /// Corral's defaults (`GhosttyDefaults`), then optional overrides from ~/.config/corral/ghostty,
    /// then includes, then Corral's late fixes (ssh).
    static func loadConfig() -> ghostty_config_t? {
        GhosttyDefaults.userShellFeatures = userShellFeatures()
        guard let cfg = ghostty_config_new() else { return nil }
        loadLayers(cfg)
        if GhosttyDefaults.lateConfig != nil, let late = GhosttyDefaults.writeLate() { ghostty_config_load_file(cfg, late) }
        ghostty_config_finalize(cfg)
        let count = ghostty_config_diagnostics_count(cfg)
        for i in 0..<count {
            let diag = ghostty_config_get_diagnostic(cfg, i)
            if let msg = diag.message { NSLog("Ghostty config: \(String(cString: msg))") }
        }
        return cfg
    }

    func reloadConfig() {
        guard let app, let newConfig = Self.loadConfig() else { return }
        ghostty_app_update_config(app, newConfig)
        if let old = config { ghostty_config_free(old) }
        config = newConfig
        if let e = effectiveConfig { ghostty_config_free(e) }
        effectiveConfig = nil
        NotificationCenter.default.post(name: .ghosttyConfigReloaded, object: self)
    }

    var backgroundColor: NSColor? { color("background") }
    var foregroundColor: NSColor? { color("foreground") }

    var windowTheme: String? {
        guard let cfg = effectiveConfig ?? config else { return nil }
        var value: UnsafePointer<CChar>?
        let key = "window-theme"
        guard ghostty_config_get(cfg, &value, key, UInt(key.utf8.count)), let value else { return nil }
        return String(cString: value)
    }

    private func color(_ key: String) -> NSColor? {
        guard let cfg = effectiveConfig ?? config else { return nil }
        var color = ghostty_config_color_s()
        guard ghostty_config_get(cfg, &color, key, UInt(key.utf8.count)) else { return nil }
        return NSColor(srgbRed: CGFloat(color.r) / 255, green: CGFloat(color.g) / 255, blue: CGFloat(color.b) / 255, alpha: 1)
    }

    var configPath: String {
        let s = ghostty_config_open_path()
        defer { ghostty_string_free(s) }
        guard let ptr = s.ptr else { return "" }
        return String(decoding: UnsafeRawBufferPointer(start: ptr, count: Int(s.len)), as: UTF8.self)
    }

    // MARK: Actions

    private func handle(target: ghostty_target_s, action: ghostty_action_s) -> Bool {
        let surface = target.tag == GHOSTTY_TARGET_SURFACE ? target.target.surface : nil
        if Thread.isMainThread {
            // During ghostty_surface_new (cell size, first title) the view isn't registered yet but
            // is alive: we are inside its init. Its userdata is safe to use synchronously here.
            let view = surface.flatMap { s in
                TerminalView.live(for: s) ?? ghostty_surface_userdata(s).map {
                    Unmanaged<TerminalView>.fromOpaque($0).takeUnretainedValue()
                }
            }
            return dispatch(action, view: view)
        }
        // libghostty delivers actions on the main thread in practice; if not, resolve the view
        // on main through the registry so a freed surface is simply ignored. Strings are copied
        // into Swift values first because the C ones die with this callback.
        let key = surface.map { UInt(bitPattern: $0) }
        let mapped = Self.map(action)
        let viewLevel = Self.isViewLevel(action.tag)
        // Only plain values survive the hop (no C string pointers are read after this point).
        let copy = action
        DispatchQueue.main.async { [weak self] in
            let view = key.flatMap { UnsafeMutableRawPointer(bitPattern: $0) }.flatMap { TerminalView.live(for: $0) }
            if key != nil && view == nil { return }
            if viewLevel {
                _ = self?.dispatch(copy, view: view)
            } else if let mapped {
                _ = self?.actionHandler?.perform(mapped, terminal: view)
            }
        }
        return viewLevel || (mapped != nil && mapped != .childExited)
    }

    private static func isViewLevel(_ tag: ghostty_action_tag_e) -> Bool {
        tag == GHOSTTY_ACTION_MOUSE_SHAPE || tag == GHOSTTY_ACTION_MOUSE_VISIBILITY || tag == GHOSTTY_ACTION_CELL_SIZE
    }

    /// View-level actions stay here; everything else goes to the session manager.
    private func dispatch(_ action: ghostty_action_s, view: TerminalView?) -> Bool {
        switch action.tag {
        case GHOSTTY_ACTION_MOUSE_SHAPE:
            view?.setMouseShape(action.action.mouse_shape)
            return true
        case GHOSTTY_ACTION_MOUSE_VISIBILITY:
            NSCursor.setHiddenUntilMouseMoves(action.action.mouse_visibility != GHOSTTY_MOUSE_VISIBLE)
            return true
        case GHOSTTY_ACTION_CELL_SIZE:
            let c = action.action.cell_size
            view?.cellSize = CGSize(width: CGFloat(c.width), height: CGFloat(c.height))
            return true
        case GHOSTTY_ACTION_CONFIG_CHANGE:
            // The passed config is only valid during this callback: clone it.
            guard view == nil, let cfg = action.action.config_change.config, let clone = ghostty_config_clone(cfg) else { return false }
            if let old = effectiveConfig { ghostty_config_free(old) }
            effectiveConfig = clone
            return actionHandler?.perform(.configChanged, terminal: nil) ?? false
        default:
            guard let mapped = Self.map(action) else { return false }
            return actionHandler?.perform(mapped, terminal: view) ?? false
        }
    }

    private static func string(_ p: UnsafePointer<CChar>?) -> String {
        p.map { String(cString: $0) } ?? ""
    }

    static func map(_ action: ghostty_action_s) -> TerminalAction? {
        let a = action.action
        switch action.tag {
        case GHOSTTY_ACTION_NEW_TAB, GHOSTTY_ACTION_NEW_WINDOW: return .newSession
        case GHOSTTY_ACTION_CLOSE_TAB:
            // close_tab:other / :right have no sidebar equivalent; let Ghostty treat them as unhandled.
            return a.close_tab_mode == GHOSTTY_ACTION_CLOSE_TAB_MODE_THIS ? .closeSession : nil
        case GHOSTTY_ACTION_CLOSE_WINDOW: return .closeSession
        case GHOSTTY_ACTION_GOTO_TAB: return .gotoSession(Int(a.goto_tab.rawValue))
        case GHOSTTY_ACTION_MOVE_TAB: return .moveSession(Int(a.move_tab.amount))
        case GHOSTTY_ACTION_TOGGLE_FULLSCREEN: return .toggleFullscreen
        case GHOSTTY_ACTION_TOGGLE_COMMAND_PALETTE: return .commandPalette
        case GHOSTTY_ACTION_SET_TITLE: return .setTitle(string(a.set_title.title))
        case GHOSTTY_ACTION_PWD: return .pwd(string(a.pwd.pwd))
        case GHOSTTY_ACTION_DESKTOP_NOTIFICATION:
            return .desktopNotification(title: string(a.desktop_notification.title), body: string(a.desktop_notification.body))
        case GHOSTTY_ACTION_RING_BELL: return .bell
        case GHOSTTY_ACTION_PROGRESS_REPORT:
            switch a.progress_report.state {
            case GHOSTTY_PROGRESS_STATE_REMOVE: return .progress(.removed)
            case GHOSTTY_PROGRESS_STATE_ERROR: return .progress(.error)
            default: return .progress(.active)
            }
        case GHOSTTY_ACTION_COMMAND_FINISHED:
            let code = a.command_finished.exit_code
            return .commandFinished(exitCode: code < 0 ? nil : Int(code), seconds: Double(a.command_finished.duration) / 1e9)
        case GHOSTTY_ACTION_SHOW_CHILD_EXITED: return .childExited
        case GHOSTTY_ACTION_OPEN_URL:
            guard let p = a.open_url.url else { return nil }
            let data = Data(bytes: p, count: Int(a.open_url.len))
            let kind: URLKind
            switch a.open_url.kind {
            case GHOSTTY_ACTION_OPEN_URL_KIND_TEXT: kind = .text
            case GHOSTTY_ACTION_OPEN_URL_KIND_HTML: kind = .html
            case GHOSTTY_ACTION_OPEN_URL_KIND_OSC8: kind = .osc8
            default: kind = .unknown
            }
            return .openURL(String(decoding: data, as: UTF8.self), kind: kind)
        case GHOSTTY_ACTION_OPEN_CONFIG: return .openConfig
        case GHOSTTY_ACTION_RELOAD_CONFIG: return .reloadConfig
        case GHOSTTY_ACTION_START_SEARCH: return .startSearch(a.start_search.needle.map { String(cString: $0) })
        case GHOSTTY_ACTION_END_SEARCH: return .endSearch
        case GHOSTTY_ACTION_SEARCH_TOTAL: return .searchTotal(Int(a.search_total.total))
        case GHOSTTY_ACTION_SEARCH_SELECTED: return .searchSelected(Int(a.search_selected.selected))
        case GHOSTTY_ACTION_UNDO: return .undoClose
        case GHOSTTY_ACTION_NEW_SPLIT:
            switch a.new_split {
            case GHOSTTY_SPLIT_DIRECTION_DOWN: return .newSplit(.down)
            case GHOSTTY_SPLIT_DIRECTION_LEFT: return .newSplit(.left)
            case GHOSTTY_SPLIT_DIRECTION_UP: return .newSplit(.up)
            default: return .newSplit(.right)
            }
        case GHOSTTY_ACTION_GOTO_SPLIT:
            switch a.goto_split {
            case GHOSTTY_GOTO_SPLIT_PREVIOUS: return .gotoSplit(.previous)
            case GHOSTTY_GOTO_SPLIT_UP: return .gotoSplit(.toward(.up))
            case GHOSTTY_GOTO_SPLIT_DOWN: return .gotoSplit(.toward(.down))
            case GHOSTTY_GOTO_SPLIT_LEFT: return .gotoSplit(.toward(.left))
            case GHOSTTY_GOTO_SPLIT_RIGHT: return .gotoSplit(.toward(.right))
            default: return .gotoSplit(.next)
            }
        case GHOSTTY_ACTION_QUIT: return .quit
        default: return nil
        }
    }
}

extension Notification.Name {
    static let ghosttyConfigReloaded = Notification.Name("CorralGhosttyConfigReloaded")
}
