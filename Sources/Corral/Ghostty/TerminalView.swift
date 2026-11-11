import AppKit
import Carbon
import CorralKit
import GhosttyKit

/// NSView hosting one libghostty surface. Keyboard/IME/mouse handling follows Ghostty's own
/// macOS SurfaceView so terminal input behaves exactly like Ghostty.app.
final class TerminalView: NSView, NSTextInputClient, TerminalSurface {
    var view: NSView { self }

    weak var runtime: GhosttyRuntime?
    private(set) var surface: ghostty_surface_t?
    let sessionId: UUID

    /// Every non-composing key press (used to notice the user answering a prompt).
    var onKeyDown: ((NSEvent) -> Void)?
    var onFocus: (() -> Void)?

    private var markedText = NSMutableAttributedString()
    private var keyTextAccumulator: [String]?
    private var lastPerformKeyEvent: TimeInterval?
    private var focused = false
    private var contentSize: CGSize = .zero
    private var trackingArea: NSTrackingArea?
    var cellSize: CGSize = CGSize(width: 8, height: 16)
    private var currentCursor: NSCursor = .iBeam
    /// Set while a Ghostty key binding is being dispatched; such keys are not "typing".
    private var dispatchingBinding = false
    private var leadSurrogate: UInt16?

    /// Surfaces that are alive, so callbacks can never reach a view whose surface was freed.
    /// Weak: the registry must not keep views (and their shells) alive.
    private final class WeakView {
        weak var view: TerminalView?
        init(_ v: TerminalView) { view = v }
    }
    private static var registry: [UnsafeMutableRawPointer: WeakView] = [:]

    static func live(for surface: ghostty_surface_t) -> TerminalView? {
        registry[surface]?.view
    }

    init(runtime: GhosttyRuntime, sessionId: UUID, launch: LaunchSpec) {
        self.runtime = runtime
        self.sessionId = sessionId
        super.init(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
        wantsLayer = true
        guard let app = runtime.app else { return }

        var env = launch.env
        env["CORRAL_SURFACE_ID"] = sessionId.uuidString
        surface = Self.withCConfig(view: self, launch: launch, env: env) { cfg in
            ghostty_surface_new(app, &cfg)
        }
        if let surface { Self.registry[surface] = WeakView(self) }
        registerForDraggedTypes([.fileURL, .string])
        NotificationCenter.default.addObserver(self, selector: #selector(windowDidChangeScreen(_:)),
                                               name: NSWindow.didChangeScreenNotification, object: nil)
    }

    deinit {
        // Safety net: a view dropped without destroy() must not leave libghostty pointing at it.
        if let s = surface {
            Self.registry[s] = nil
            ghostty_surface_free(s)
        }
    }

    required init?(coder: NSCoder) { fatalError("not supported") }

    /// Frees the surface (kills the shell). Must be called before the view is released.
    func destroy() {
        guard let s = surface else { return }
        surface = nil
        Self.registry[s] = nil
        ghostty_surface_free(s)
    }

    private static func withCConfig<T>(view: TerminalView, launch: LaunchSpec, env: [String: String],
                                       _ body: (inout ghostty_surface_config_s) -> T) -> T {
        var cfg = ghostty_surface_config_new()
        cfg.userdata = Unmanaged.passUnretained(view).toOpaque()
        cfg.platform_tag = GHOSTTY_PLATFORM_MACOS
        cfg.platform = ghostty_platform_u(macos: ghostty_platform_macos_s(nsview: Unmanaged.passUnretained(view).toOpaque()))
        cfg.scale_factor = Double(NSScreen.main?.backingScaleFactor ?? 2)
        cfg.font_size = 0
        cfg.context = GHOSTTY_SURFACE_CONTEXT_TAB

        let keys = Array(env.keys)
        let cKeys = keys.map { strdup($0)! }
        let cValues = keys.map { strdup(env[$0]!)! }
        defer {
            cKeys.forEach { free($0) }
            cValues.forEach { free($0) }
        }
        var vars = zip(cKeys, cValues).map { ghostty_env_var_s(key: $0, value: $1) }
        return launch.cwd.withCString { cwd in
            cfg.working_directory = cwd
            // Direct agent launch runs `command` instead of the login shell; the typed fallback types
            // `initialInput` into the shell's first prompt. Stock libghostty forces wait-after-command
            // for any command (surface kept open after exit); patches/ghostty-corral.patch drops that,
            // so the session closes on `exit` like a plain shell.
            let input = launch.initialInput.map { $0.hasSuffix("\n") ? $0 : $0 + "\n" }
            return withOptionalCString(launch.command) { commandPtr in
                cfg.command = commandPtr
                return withOptionalCString(input) { inputPtr in
                    cfg.initial_input = inputPtr
                    return vars.withUnsafeMutableBufferPointer { buf in
                        cfg.env_vars = buf.baseAddress
                        cfg.env_var_count = buf.count
                        return body(&cfg)
                    }
                }
            }
        }
    }

    // MARK: Surface queries

    var foregroundPid: pid_t {
        guard let surface else { return 0 }
        return pid_t(truncatingIfNeeded: ghostty_surface_foreground_pid(surface))
    }

    var needsConfirmQuit: Bool {
        guard let surface else { return false }
        return ghostty_surface_needs_confirm_quit(surface)
    }

    /// Full scrollback + screen as plain text.
    func screenText() -> String {
        guard let surface else { return "" }
        var text = ghostty_text_s()
        let sel = ghostty_selection_s(
            top_left: ghostty_point_s(tag: GHOSTTY_POINT_SCREEN, coord: GHOSTTY_POINT_COORD_TOP_LEFT, x: 0, y: 0),
            bottom_right: ghostty_point_s(tag: GHOSTTY_POINT_SCREEN, coord: GHOSTTY_POINT_COORD_BOTTOM_RIGHT, x: 0, y: 0),
            rectangle: false)
        guard ghostty_surface_read_text(surface, sel, &text) else { return "" }
        defer { ghostty_surface_free_text(surface, &text) }
        guard let p = text.text else { return "" }
        return String(decoding: UnsafeRawBufferPointer(start: p, count: Int(text.text_len)), as: UTF8.self)
    }

    /// The visible screen only (the launch probe reads it every 100 ms; a resumed transcript's
    /// scrollback can be huge).
    func viewportText() -> String {
        guard let surface else { return "" }
        var text = ghostty_text_s()
        let sel = ghostty_selection_s(
            top_left: ghostty_point_s(tag: GHOSTTY_POINT_VIEWPORT, coord: GHOSTTY_POINT_COORD_TOP_LEFT, x: 0, y: 0),
            bottom_right: ghostty_point_s(tag: GHOSTTY_POINT_VIEWPORT, coord: GHOSTTY_POINT_COORD_BOTTOM_RIGHT, x: 0, y: 0),
            rectangle: false)
        guard ghostty_surface_read_text(surface, sel, &text) else { return "" }
        defer { ghostty_surface_free_text(surface, &text) }
        guard let p = text.text else { return "" }
        return String(decoding: UnsafeRawBufferPointer(start: p, count: Int(text.text_len)), as: UTF8.self)
    }

    @discardableResult
    func perform(binding: String) -> Bool {
        guard let surface else { return false }
        return binding.withCString { ghostty_surface_binding_action(surface, $0, UInt(binding.utf8.count)) }
    }

    func setVisible(_ visible: Bool) {
        guard let surface else { return }
        shown = visible
        // A hidden surface gives up its frame and draws again only through the display link: bind
        // it to the current display first (its id can change while hidden, e.g. after a lock).
        if visible { updateDisplayID() }
        ghostty_surface_set_occlusion(surface, visible)
        if visible { scheduleShowDraws() }
    }

    /// Whether the container shows this terminal (`setVisible`).
    private var shown = false

    /// Becoming visible makes the render thread draw, but that frame can be lost: it waits for a vsync
    /// tick, or is dropped for not matching the layer's size once layout has moved on. Nothing else
    /// draws while the program prints nothing (an idle agent, a background command), and the hidden
    /// surface gave up its old frame: a blank pane. So draw synchronously (presented on the spot) once
    /// layout settled, and again once the render thread caught up with output from while hidden.
    private func scheduleShowDraws() {
        for delay in [0.0, 0.25] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                MainActor.assumeIsolated { self?.drawIfShown() }
            }
        }
    }

    private func drawIfShown() {
        guard shown, let surface, window != nil, !isHiddenOrHasHiddenAncestor,
              bounds.width > 0, bounds.height > 0 else { return }
        ghostty_surface_draw(surface)
    }

    /// Types text as if pasted (used for drag and drop of paths).
    func insertPaste(_ s: String) {
        guard let surface else { return }
        s.withCString { ghostty_surface_text(surface, $0, UInt(s.utf8.count)) }
    }

    // MARK: Layout

    override var acceptsFirstResponder: Bool { true }
    override var isFlipped: Bool { false }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        contentSize = newSize
        updateSurfaceSize()
        updateTrackingAreas()
    }

    private func updateSurfaceSize() {
        guard let surface, contentSize.width > 0, contentSize.height > 0 else { return }
        let scaled = convertToBacking(contentSize)
        ghostty_surface_set_size(surface, UInt32(scaled.width), UInt32(scaled.height))
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        // A first responder that leaves its window loses that status without resignFirstResponder
        // (a split moves the terminal into its host that way): a stale `focused` would keep taking
        // key equivalents (⌘V) meant for the pane being typed in.
        setFocus(window?.firstResponder === self)
        guard window != nil else { return }
        updateDisplayID()
        viewDidChangeBackingProperties()
    }

    /// The display link (vsync) follows the window's display. Bound to one that went away (sleep,
    /// a monitor reconnecting), the terminal never draws again: Ghostty's SurfaceView does the same.
    @objc private func windowDidChangeScreen(_ notification: Notification) {
        guard let window, notification.object as? NSWindow === window else { return }
        updateDisplayID()
        // The new display may have another scale factor.
        DispatchQueue.main.async { [weak self] in self?.viewDidChangeBackingProperties() }
    }

    private func updateDisplayID() {
        guard let surface, let screen = window?.screen,
              let id = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else { return }
        ghostty_surface_set_display_id(surface, id.uint32Value)
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        if let window {
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            layer?.contentsScale = window.backingScaleFactor
            CATransaction.commit()
        }
        guard let surface, frame.width > 0, frame.height > 0 else { return }
        let fb = convertToBacking(frame)
        ghostty_surface_set_content_scale(surface, fb.width / frame.width, fb.height / frame.height)
        updateSurfaceSize()
    }

    override func updateTrackingAreas() {
        if let trackingArea { removeTrackingArea(trackingArea) }
        let area = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .mouseMoved, .inVisibleRect, .activeAlways, .cursorUpdate],
                                  owner: self, userInfo: nil)
        addTrackingArea(area)
        trackingArea = area
        super.updateTrackingAreas()
    }

    // MARK: Focus

    override func becomeFirstResponder() -> Bool {
        let ok = super.becomeFirstResponder()
        if ok { setFocus(true) }
        return ok
    }

    override func resignFirstResponder() -> Bool {
        let ok = super.resignFirstResponder()
        if ok { setFocus(false) }
        return ok
    }

    private func setFocus(_ f: Bool) {
        guard focused != f else { return }
        focused = f
        if let surface { ghostty_surface_set_focus(surface, f) }
        if f { onFocus?() }
    }

    // MARK: Mouse

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { false }

    override func mouseDown(with event: NSEvent) {
        if window?.firstResponder !== self { window?.makeFirstResponder(self) }
        guard let surface else { return }
        ghostty_surface_mouse_button(surface, GHOSTTY_MOUSE_PRESS, GHOSTTY_MOUSE_LEFT, Self.mods(event.modifierFlags))
    }

    override func mouseUp(with event: NSEvent) {
        guard let surface else { return }
        ghostty_surface_mouse_button(surface, GHOSTTY_MOUSE_RELEASE, GHOSTTY_MOUSE_LEFT, Self.mods(event.modifierFlags))
        ghostty_surface_mouse_pressure(surface, 0, 0)
    }

    override func rightMouseDown(with event: NSEvent) {
        guard let surface,
              ghostty_surface_mouse_button(surface, GHOSTTY_MOUSE_PRESS, GHOSTTY_MOUSE_RIGHT, Self.mods(event.modifierFlags))
        else { return super.rightMouseDown(with: event) }
    }

    override func rightMouseUp(with event: NSEvent) {
        guard let surface,
              ghostty_surface_mouse_button(surface, GHOSTTY_MOUSE_RELEASE, GHOSTTY_MOUSE_RIGHT, Self.mods(event.modifierFlags))
        else { return super.rightMouseUp(with: event) }
    }

    override func otherMouseDown(with event: NSEvent) {
        guard let surface else { return }
        ghostty_surface_mouse_button(surface, GHOSTTY_MOUSE_PRESS, Self.button(event.buttonNumber), Self.mods(event.modifierFlags))
    }

    override func otherMouseUp(with event: NSEvent) {
        guard let surface else { return }
        ghostty_surface_mouse_button(surface, GHOSTTY_MOUSE_RELEASE, Self.button(event.buttonNumber), Self.mods(event.modifierFlags))
    }

    override func mouseMoved(with event: NSEvent) {
        guard let surface else { return }
        let p = convert(event.locationInWindow, from: nil)
        ghostty_surface_mouse_pos(surface, p.x, frame.height - p.y, Self.mods(event.modifierFlags))
    }

    override func mouseDragged(with event: NSEvent) { mouseMoved(with: event) }
    override func rightMouseDragged(with event: NSEvent) { mouseMoved(with: event) }
    override func otherMouseDragged(with event: NSEvent) { mouseMoved(with: event) }
    override func mouseEntered(with event: NSEvent) { mouseMoved(with: event) }

    override func mouseExited(with event: NSEvent) {
        guard let surface, NSEvent.pressedMouseButtons == 0 else { return }
        ghostty_surface_mouse_pos(surface, -1, -1, Self.mods(event.modifierFlags))
    }

    override func scrollWheel(with event: NSEvent) {
        guard let surface else { return }
        var x = event.scrollingDeltaX
        var y = event.scrollingDeltaY
        let precise = event.hasPreciseScrollingDeltas
        if precise { x *= 2; y *= 2 }
        var mods: Int32 = precise ? 1 : 0
        let momentum: Int32
        switch event.momentumPhase {
        case .began: momentum = Int32(GHOSTTY_MOUSE_MOMENTUM_BEGAN.rawValue)
        case .stationary: momentum = Int32(GHOSTTY_MOUSE_MOMENTUM_STATIONARY.rawValue)
        case .changed: momentum = Int32(GHOSTTY_MOUSE_MOMENTUM_CHANGED.rawValue)
        case .ended: momentum = Int32(GHOSTTY_MOUSE_MOMENTUM_ENDED.rawValue)
        case .cancelled: momentum = Int32(GHOSTTY_MOUSE_MOMENTUM_CANCELLED.rawValue)
        case .mayBegin: momentum = Int32(GHOSTTY_MOUSE_MOMENTUM_MAY_BEGIN.rawValue)
        default: momentum = 0
        }
        mods |= momentum << 1
        ghostty_surface_mouse_scroll(surface, x, y, mods)
    }

    override func pressureChange(with event: NSEvent) {
        guard let surface else { return }
        ghostty_surface_mouse_pressure(surface, UInt32(event.stage), Double(event.pressure))
    }

    override func cursorUpdate(with event: NSEvent) {
        currentCursor.set()
    }

    func setMouseShape(_ shape: ghostty_action_mouse_shape_e) {
        switch shape {
        case GHOSTTY_MOUSE_SHAPE_DEFAULT: currentCursor = .arrow
        case GHOSTTY_MOUSE_SHAPE_TEXT: currentCursor = .iBeam
        case GHOSTTY_MOUSE_SHAPE_POINTER: currentCursor = .pointingHand
        case GHOSTTY_MOUSE_SHAPE_CROSSHAIR: currentCursor = .crosshair
        case GHOSTTY_MOUSE_SHAPE_GRAB: currentCursor = .openHand
        case GHOSTTY_MOUSE_SHAPE_GRABBING: currentCursor = .closedHand
        case GHOSTTY_MOUSE_SHAPE_NOT_ALLOWED, GHOSTTY_MOUSE_SHAPE_NO_DROP: currentCursor = .operationNotAllowed
        case GHOSTTY_MOUSE_SHAPE_COL_RESIZE, GHOSTTY_MOUSE_SHAPE_EW_RESIZE: currentCursor = .resizeLeftRight
        case GHOSTTY_MOUSE_SHAPE_ROW_RESIZE, GHOSTTY_MOUSE_SHAPE_NS_RESIZE: currentCursor = .resizeUpDown
        case GHOSTTY_MOUSE_SHAPE_VERTICAL_TEXT: currentCursor = .iBeamCursorForVerticalLayout
        case GHOSTTY_MOUSE_SHAPE_CONTEXT_MENU: currentCursor = .contextualMenu
        case GHOSTTY_MOUSE_SHAPE_COPY: currentCursor = .dragCopy
        case GHOSTTY_MOUSE_SHAPE_ALIAS: currentCursor = .dragLink
        default: currentCursor = .arrow
        }
        if window?.isKeyWindow == true { currentCursor.set() }
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        // Only reached when the terminal did not capture the right click.
        let menu = NSMenu()
        menu.addItem(withTitle: "Copy", action: #selector(copy(_:)), keyEquivalent: "")
        menu.addItem(withTitle: "Paste", action: #selector(paste(_:)), keyEquivalent: "")
        menu.addItem(.separator())
        menu.addItem(withTitle: "Clear", action: #selector(clearScreen(_:)), keyEquivalent: "")
        return menu
    }

    // MARK: Edit actions (menu / responder chain)

    @objc func copy(_ sender: Any?) { perform(binding: "copy_to_clipboard") }
    @objc func paste(_ sender: Any?) { perform(binding: "paste_from_clipboard") }
    @objc override func selectAll(_ sender: Any?) { perform(binding: "select_all") }
    @objc func clearScreen(_ sender: Any?) { perform(binding: "clear_screen") }
    @objc func findInTerminal(_ sender: Any?) { perform(binding: "start_search") }

    // MARK: Keyboard

    override func keyDown(with event: NSEvent) {
        guard let surface else {
            interpretKeyEvents([event])
            return
        }
        let translationModsGhostty = Self.flags(ghostty_surface_key_translation_mods(surface, Self.mods(event.modifierFlags)))
        var translationMods = event.modifierFlags
        for flag in [NSEvent.ModifierFlags.shift, .control, .option, .command] {
            if translationModsGhostty.contains(flag) { translationMods.insert(flag) } else { translationMods.remove(flag) }
        }
        let translationEvent: NSEvent
        if translationMods == event.modifierFlags {
            translationEvent = event
        } else {
            translationEvent = NSEvent.keyEvent(
                with: event.type, location: event.locationInWindow, modifierFlags: translationMods,
                timestamp: event.timestamp, windowNumber: event.windowNumber, context: nil,
                characters: event.characters(byApplyingModifiers: translationMods) ?? "",
                charactersIgnoringModifiers: event.charactersIgnoringModifiers ?? "",
                isARepeat: event.isARepeat, keyCode: event.keyCode) ?? event
        }
        let action = event.isARepeat ? GHOSTTY_ACTION_REPEAT : GHOSTTY_ACTION_PRESS

        keyTextAccumulator = []
        defer { keyTextAccumulator = nil }
        let markedTextBefore = markedText.length > 0
        let keyboardIdBefore = markedTextBefore ? nil : Self.keyboardLayoutId
        lastPerformKeyEvent = nil

        interpretKeyEvents([translationEvent])

        if !markedTextBefore && keyboardIdBefore != Self.keyboardLayoutId { return }
        syncPreedit(clearIfNeeded: markedTextBefore)
        let composing = markedText.length > 0 || markedTextBefore

        if markedTextBefore, let list = keyTextAccumulator, !list.isEmpty {
            for text in list where !Self.suppressComposingControl(text, composing: composing) {
                _ = committedText(action, text: text)
            }
            if Self.replayAfterCommit(translationEvent) {
                _ = keyAction(action, event: event, translationEvent: translationEvent, composing: false)
            }
            return
        }

        if let list = keyTextAccumulator, !list.isEmpty {
            for text in list where !Self.suppressComposingControl(text, composing: composing) {
                _ = keyAction(action, event: event, translationEvent: translationEvent, text: text)
            }
        } else {
            if Self.suppressComposingControl(event.characters, composing: composing) { return }
            _ = keyAction(action, event: event, translationEvent: translationEvent,
                          text: Self.ghosttyCharacters(translationEvent), composing: composing)
        }

        if !composing && !dispatchingBinding { onKeyDown?(event) }
    }

    override func keyUp(with event: NSEvent) {
        _ = keyAction(GHOSTTY_ACTION_RELEASE, event: event)
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard event.type == .keyDown, focused, window?.firstResponder === self, let surface else { return false }

        var ghosttyEvent = Self.keyEvent(event, action: GHOSTTY_ACTION_PRESS)
        var flags = ghostty_binding_flags_e(rawValue: 0)
        let isBinding = (event.characters ?? "").withCString { ptr -> Bool in
            ghosttyEvent.text = ptr
            return ghostty_surface_key_is_binding(surface, ghosttyEvent, &flags)
        }
        if isBinding {
            // Like Ghostty.app: a consumed, non-performable binding that also has a menu item
            // (Cmd+W, Cmd+T, Cmd+1…) goes through the menu so Corral's own handling runs
            // (e.g. the busy-agent confirmation on close).
            let raw = flags.rawValue
            let consumed = raw & GHOSTTY_BINDING_FLAGS_CONSUMED.rawValue != 0
            let special = raw & (GHOSTTY_BINDING_FLAGS_ALL.rawValue | GHOSTTY_BINDING_FLAGS_PERFORMABLE.rawValue) != 0
            if consumed, !special, NSApp.mainMenu?.performKeyEquivalent(with: event) == true {
                return true
            }
            dispatchingBinding = true
            defer { dispatchingBinding = false }
            keyDown(with: event)
            return true
        }

        let equivalent: String
        switch event.charactersIgnoringModifiers {
        case "\r":
            if !event.modifierFlags.contains(.control) { return false }
            equivalent = "\r"
        case "/":
            if !event.modifierFlags.contains(.control) || !event.modifierFlags.isDisjoint(with: [.shift, .command, .option]) {
                return false
            }
            equivalent = "_"
        default:
            if event.timestamp == 0 { return false }
            if !event.modifierFlags.contains(.command) && !event.modifierFlags.contains(.control) {
                lastPerformKeyEvent = nil
                return false
            }
            if let last = lastPerformKeyEvent {
                lastPerformKeyEvent = nil
                if last == event.timestamp {
                    equivalent = event.characters ?? ""
                    break
                }
            }
            // Give the menu a chance first; doCommand(by:) re-dispatches it to us if nobody wants it.
            lastPerformKeyEvent = event.timestamp
            return false
        }
        guard let final = NSEvent.keyEvent(
            with: .keyDown, location: event.locationInWindow, modifierFlags: event.modifierFlags,
            timestamp: event.timestamp, windowNumber: event.windowNumber, context: nil,
            characters: equivalent, charactersIgnoringModifiers: equivalent,
            isARepeat: event.isARepeat, keyCode: event.keyCode) else { return false }
        keyDown(with: final)
        return true
    }

    override func flagsChanged(with event: NSEvent) {
        let mod: UInt32
        switch Int(event.keyCode) {
        case kVK_CapsLock: mod = GHOSTTY_MODS_CAPS.rawValue
        case kVK_Shift, kVK_RightShift: mod = GHOSTTY_MODS_SHIFT.rawValue
        case kVK_Control, kVK_RightControl: mod = GHOSTTY_MODS_CTRL.rawValue
        case kVK_Option, kVK_RightOption: mod = GHOSTTY_MODS_ALT.rawValue
        case kVK_Command, kVK_RightCommand: mod = GHOSTTY_MODS_SUPER.rawValue
        default: return
        }
        if hasMarkedText() { return }
        let mods = Self.mods(event.modifierFlags)
        var action = GHOSTTY_ACTION_RELEASE
        if mods.rawValue & mod != 0 {
            let raw = event.modifierFlags.rawValue
            let sidePressed: Bool
            switch Int(event.keyCode) {
            case kVK_RightShift: sidePressed = raw & UInt(NX_DEVICERSHIFTKEYMASK) != 0
            case kVK_RightControl: sidePressed = raw & UInt(NX_DEVICERCTLKEYMASK) != 0
            case kVK_RightOption: sidePressed = raw & UInt(NX_DEVICERALTKEYMASK) != 0
            case kVK_RightCommand: sidePressed = raw & UInt(NX_DEVICERCMDKEYMASK) != 0
            default: sidePressed = true
            }
            if sidePressed { action = GHOSTTY_ACTION_PRESS }
        }
        _ = keyAction(action, event: event)
    }

    private func keyAction(_ action: ghostty_input_action_e, event: NSEvent, translationEvent: NSEvent? = nil,
                           text: String? = nil, composing: Bool = false) -> Bool {
        guard let surface else { return false }
        var ev = Self.keyEvent(event, action: action, translationMods: translationEvent?.modifierFlags)
        ev.composing = composing
        if let text = Self.keyEventText(text) {
            return text.withCString { ptr in
                ev.text = ptr
                return ghostty_surface_key(surface, ev)
            }
        }
        return ghostty_surface_key(surface, ev)
    }

    private func committedText(_ action: ghostty_input_action_e, text: String) -> Bool {
        guard let surface else { return false }
        var ev = ghostty_input_key_s()
        ev.action = action
        ev.mods = GHOSTTY_MODS_NONE
        ev.consumed_mods = GHOSTTY_MODS_NONE
        return text.withCString { ptr in
            ev.text = ptr
            return ghostty_surface_key(surface, ev)
        }
    }

    private func syncPreedit(clearIfNeeded: Bool = true) {
        guard let surface else { return }
        if markedText.length > 0 {
            let str = markedText.string
            str.withCString { ghostty_surface_preedit(surface, $0, UInt(str.utf8.count)) }
        } else if clearIfNeeded {
            ghostty_surface_preedit(surface, nil, 0)
        }
    }

    // MARK: NSTextInputClient

    func hasMarkedText() -> Bool { markedText.length > 0 }

    func markedRange() -> NSRange {
        markedText.length > 0 ? NSRange(location: 0, length: markedText.length) : NSRange()
    }

    // Empty NSRange() (not NSNotFound) like Ghostty: input methods use it to place their UI.
    func selectedRange() -> NSRange {
        guard let surface else { return NSRange() }
        var text = ghostty_text_s()
        guard ghostty_surface_read_selection(surface, &text) else { return NSRange() }
        defer { ghostty_surface_free_text(surface, &text) }
        return NSRange(location: Int(text.offset_start), length: Int(text.offset_len))
    }

    func setMarkedText(_ string: Any, selectedRange: NSRange, replacementRange: NSRange) {
        switch string {
        case let v as NSAttributedString: markedText = NSMutableAttributedString(attributedString: v)
        case let v as String: markedText = NSMutableAttributedString(string: v)
        default: return
        }
        if keyTextAccumulator == nil { syncPreedit() }
    }

    func unmarkText() {
        if markedText.length > 0 {
            markedText.mutableString.setString("")
            syncPreedit()
        }
    }

    func validAttributesForMarkedText() -> [NSAttributedString.Key] { [] }

    func attributedSubstring(forProposedRange range: NSRange, actualRange: NSRangePointer?) -> NSAttributedString? {
        guard let surface, range.length > 0 else { return nil }
        var text = ghostty_text_s()
        guard ghostty_surface_read_selection(surface, &text) else { return nil }
        defer { ghostty_surface_free_text(surface, &text) }
        guard let p = text.text else { return nil }
        return NSAttributedString(string: String(cString: p))
    }

    func characterIndex(for point: NSPoint) -> Int { 0 }

    func firstRect(forCharacterRange range: NSRange, actualRange: NSRangePointer?) -> NSRect {
        guard let surface else { return NSRect(origin: frame.origin, size: .zero) }
        var x: Double = 0, y: Double = 0, w: Double = cellSize.width, h: Double = cellSize.height
        ghostty_surface_ime_point(surface, &x, &y, &w, &h)
        if range.length == 0, w > 0 {
            w = 0
            x += cellSize.width * Double(range.location + range.length)
        }
        let viewRect = NSRect(x: x, y: frame.size.height - y, width: w, height: max(h, cellSize.height))
        let winRect = convert(viewRect, to: nil)
        return window?.convertToScreen(winRect) ?? winRect
    }

    func insertText(_ string: Any, replacementRange: NSRange) {
        guard NSApp.currentEvent != nil else { return }
        var chars: String
        switch string {
        case let v as NSAttributedString: chars = v.string
        case let v as String: chars = v
        default: return
        }
        // Some input methods deliver an astral character (emoji) as two lone UTF-16 surrogates.
        let units = Array(chars.utf16)
        if units.count == 1, UTF16.isLeadSurrogate(units[0]) {
            leadSurrogate = units[0]
            return
        }
        if units.count == 1, UTF16.isTrailSurrogate(units[0]) {
            guard let lead = leadSurrogate else { return }
            leadSurrogate = nil
            chars = String(decoding: [lead, units[0]], as: UTF16.self)
        } else {
            leadSurrogate = nil
        }
        unmarkText()
        if var acc = keyTextAccumulator {
            acc.append(chars)
            keyTextAccumulator = acc
            return
        }
        if !chars.isEmpty { _ = committedText(GHOSTTY_ACTION_PRESS, text: chars) }
    }

    override func doCommand(by selector: Selector) {
        // A Cmd/Ctrl key the menu did not want comes back here; send it on to the terminal.
        if let last = lastPerformKeyEvent, let current = NSApp.currentEvent, last == current.timestamp {
            NSApp.sendEvent(current)
        }
    }

    // MARK: Drag and drop (paths into the shell)

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation { .copy }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        let pb = sender.draggingPasteboard
        if let urls = pb.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL], !urls.isEmpty {
            insertPaste(urls.map { Clipboard.shellEscapePath($0.path) }.joined(separator: " "))
            return true
        }
        if let s = pb.string(forType: .string) {
            insertPaste(s)
            return true
        }
        return false
    }

    // MARK: Helpers

    static func mods(_ flags: NSEvent.ModifierFlags) -> ghostty_input_mods_e {
        var m = GHOSTTY_MODS_NONE.rawValue
        if flags.contains(.shift) { m |= GHOSTTY_MODS_SHIFT.rawValue }
        if flags.contains(.control) { m |= GHOSTTY_MODS_CTRL.rawValue }
        if flags.contains(.option) { m |= GHOSTTY_MODS_ALT.rawValue }
        if flags.contains(.command) { m |= GHOSTTY_MODS_SUPER.rawValue }
        if flags.contains(.capsLock) { m |= GHOSTTY_MODS_CAPS.rawValue }
        let raw = flags.rawValue
        if raw & UInt(NX_DEVICERSHIFTKEYMASK) != 0 { m |= GHOSTTY_MODS_SHIFT_RIGHT.rawValue }
        if raw & UInt(NX_DEVICERCTLKEYMASK) != 0 { m |= GHOSTTY_MODS_CTRL_RIGHT.rawValue }
        if raw & UInt(NX_DEVICERALTKEYMASK) != 0 { m |= GHOSTTY_MODS_ALT_RIGHT.rawValue }
        if raw & UInt(NX_DEVICERCMDKEYMASK) != 0 { m |= GHOSTTY_MODS_SUPER_RIGHT.rawValue }
        return ghostty_input_mods_e(m)
    }

    static func flags(_ mods: ghostty_input_mods_e) -> NSEvent.ModifierFlags {
        var f = NSEvent.ModifierFlags()
        if mods.rawValue & GHOSTTY_MODS_SHIFT.rawValue != 0 { f.insert(.shift) }
        if mods.rawValue & GHOSTTY_MODS_CTRL.rawValue != 0 { f.insert(.control) }
        if mods.rawValue & GHOSTTY_MODS_ALT.rawValue != 0 { f.insert(.option) }
        if mods.rawValue & GHOSTTY_MODS_SUPER.rawValue != 0 { f.insert(.command) }
        return f
    }

    static func button(_ number: Int) -> ghostty_input_mouse_button_e {
        switch number {
        case 0: return GHOSTTY_MOUSE_LEFT
        case 1: return GHOSTTY_MOUSE_RIGHT
        case 2: return GHOSTTY_MOUSE_MIDDLE
        case 3: return GHOSTTY_MOUSE_FOUR
        case 4: return GHOSTTY_MOUSE_FIVE
        case 5: return GHOSTTY_MOUSE_SIX
        case 6: return GHOSTTY_MOUSE_SEVEN
        case 7: return GHOSTTY_MOUSE_EIGHT
        default: return GHOSTTY_MOUSE_UNKNOWN
        }
    }

    static func keyEvent(_ event: NSEvent, action: ghostty_input_action_e,
                         translationMods: NSEvent.ModifierFlags? = nil) -> ghostty_input_key_s {
        var ev = ghostty_input_key_s()
        ev.action = action
        ev.keycode = UInt32(event.keyCode)
        ev.text = nil
        ev.composing = false
        ev.mods = mods(event.modifierFlags)
        // Control and command never contribute to text translation (same heuristic as Ghostty).
        ev.consumed_mods = mods((translationMods ?? event.modifierFlags).subtracting([.control, .command]))
        ev.unshifted_codepoint = 0
        if event.type == .keyDown || event.type == .keyUp,
           let chars = event.characters(byApplyingModifiers: []), let cp = chars.unicodeScalars.first {
            ev.unshifted_codepoint = cp.value
        }
        return ev
    }

    static func ghosttyCharacters(_ event: NSEvent) -> String? {
        guard let characters = event.characters else { return nil }
        if characters.count == 1, let scalar = characters.unicodeScalars.first {
            if scalar.value < 0x20 { return event.characters(byApplyingModifiers: event.modifierFlags.subtracting(.control)) }
            if scalar.value >= 0xF700 && scalar.value <= 0xF8FF { return nil }
        }
        return characters
    }

    /// Ghostty encodes control characters itself so the physical key stays available.
    static func keyEventText(_ s: String?) -> String? {
        guard let s, !s.isEmpty, let first = s.unicodeScalars.first else { return nil }
        if first.value < 0x20 || first.value == 0x7F { return nil }
        return s
    }

    static func suppressComposingControl(_ text: String?, composing: Bool) -> Bool {
        guard composing, let text else { return false }
        let scalars = Array(text.unicodeScalars)
        return scalars.count == 1 && scalars[0].value < 0x20
    }

    static func replayAfterCommit(_ event: NSEvent) -> Bool {
        switch Int(event.keyCode) {
        case kVK_DownArrow, kVK_RightArrow, kVK_UpArrow: return true
        case kVK_LeftArrow: return !event.modifierFlags.isDisjoint(with: [.shift, .control, .option, .command])
        default: return false
        }
    }

    static var keyboardLayoutId: String? {
        guard let source = TISCopyCurrentKeyboardInputSource()?.takeRetainedValue(),
              let ptr = TISGetInputSourceProperty(source, kTISPropertyInputSourceID) else { return nil }
        return Unmanaged<CFString>.fromOpaque(ptr).takeUnretainedValue() as String
    }
}

private func withOptionalCString<T>(_ s: String?, _ body: (UnsafePointer<CChar>?) -> T) -> T {
    guard let s else { return body(nil) }
    return s.withCString { body($0) }
}
