import Foundation

/// Runtime state of an open session (not persisted).
public struct LiveStatus: Equatable, Sendable {
    public var agent: AgentKind = .shell
    public var activity: Activity = .idle
    /// Finished or blocked while the user was looking elsewhere.
    public var unread = false
    /// Short reason, e.g. the permission prompt text.
    public var detail: String?
    public var agentSessionId: String?
    /// Directory the agent session started in; resume must run there.
    public var agentCwd: String?
    public var title: String?
    /// `title` is an agent's: set while one runs, or wearing an agent's status mark ("✳ …") when it
    /// arrives just before the agent is detected. A shell's titles (the directory, the command line)
    /// never name an agent session.
    public var titleFromAgent = false
    public var cwd: String?
    public var since = Date()
    /// Agent integration hooks reported for this session; terminal heuristics then stay quiet.
    public var hooksSeen = false
    /// What the session waits for while `needsInput`.
    public var need: Need = .input
    /// A Claude PermissionRequest prompt up now (new for every one): what a notification's Allow /
    /// Deny may answer. Nil for prompts known only from heuristics or Claude's generic notice.
    public var promptId: UUID?
    /// Activity before a compaction that started between turns (Claude's idle compaction, `/compact`):
    /// the compaction's SessionStart returns to it, as no Stop follows.
    public var compactFrom: Activity?

    public init() {}
}

/// Why a session needs the user: an agent asking to use a tool, or anything else that waits on them
/// (a question, a plan to review, a prompt).
public enum Need: Equatable, Sendable { case permission, input }

/// Everything that can change a session's status: integration hooks and terminal signals.
public enum Signal: Equatable, Sendable {
    case hook(HookEvent)
    case terminalTitle(String)
    case pwd(String)
    case desktopNotification(title: String, body: String)
    case bell
    case progress(ProgressState)
    case commandFinished(exitCode: Int?, seconds: Double)
    case foregroundProcess(AgentKind)
    case processExited
    /// User answered in the terminal (Return or a menu digit).
    case userSubmitted
    /// User pressed Escape, which dismisses an agent's prompt.
    case userCancelled
    /// Session became visible and focused.
    case viewed
    /// State of the Claude background job this session is attached to (`claude attach`).
    case backgroundJob(Activity, detail: String?)
    /// The turn ended with commands still running in the background: Claude goes on once they end.
    case backgroundCommands

    public enum ProgressState: Equatable, Sendable { case active, removed, error }
}

/// Hook payload normalized across Claude Code, OpenCode and PI.
public struct HookEvent: Codable, Equatable, Sendable {
    public var agent: AgentKind
    public var event: String
    public var sessionId: String?
    public var cwd: String?
    public var title: String?
    public var message: String?
    public var notificationType: String?
    public var status: String?
    /// Claude SessionStart source: startup, resume, clear, compact.
    public var source: String?
    /// Claude PreCompact trigger: manual (`/compact`), auto, idle.
    public var trigger: String?
    /// Claude PermissionRequest tool (AskUserQuestion and ExitPlanMode ask, they don't need permission).
    public var tool: String?
    public var isSubSession: Bool
    /// Agent exit status (`CorralAgentExit`, sent by the direct launch script).
    public var exitCode: Int?

    public init(agent: AgentKind, event: String, sessionId: String? = nil, cwd: String? = nil,
                title: String? = nil, message: String? = nil, notificationType: String? = nil,
                status: String? = nil, source: String? = nil, trigger: String? = nil, tool: String? = nil,
                isSubSession: Bool = false, exitCode: Int? = nil) {
        self.agent = agent
        self.event = event
        self.sessionId = sessionId
        self.cwd = cwd
        self.title = title
        self.message = message
        self.notificationType = notificationType
        self.status = status
        self.source = source
        self.trigger = trigger
        self.tool = tool
        self.isSubSession = isSubSession
        self.exitCode = exitCode
    }
}

public enum StatusReducer {
    /// Long-running shell commands get a "done" marker; quick ones do not.
    public static let shellCommandThreshold: Double = 10

    /// Applies a signal. `focused` = session is visible in a key window right now.
    public static func reduce(_ s: inout LiveStatus, _ signal: Signal, focused: Bool, now: Date = Date()) {
        let before = s.activity
        switch signal {
        case .hook(let e) where e.event == AgentLaunch.exitEvent:
            // Reported by Corral's own launch script, not an agent integration: same outcome as the
            // terminal noticing the agent quit, and it must not switch terminal heuristics off.
            agentQuit(&s)
        case .hook(let e):
            guard accepts(s, e) else { break }
            s.hooksSeen = true
            applyHook(&s, e, focused: focused)
        case .terminalTitle(let t):
            let clean = cleanTitle(t)
            if !clean.isEmpty {
                s.title = clean
                s.titleFromAgent = s.agent != .shell || clean != t.trimmingCharacters(in: .whitespacesAndNewlines)
            }
        case .pwd(let p):
            s.cwd = p
        case .desktopNotification(_, let body):
            // Without hooks, an agent's terminal notification is the best "needs you" signal we get.
            // Claude's idle notice ("Claude is waiting for your input") only says the turn is over,
            // also while its background shells run: done, not a question.
            if !s.hooksSeen && s.agent != .shell {
                if isIdleNotice(body) {
                    if s.activity != .needsInput { finish(&s, focused: focused) }
                } else {
                    s.activity = .needsInput
                    s.detail = body.isEmpty ? nil : body
                    s.need = body.range(of: "permission", options: .caseInsensitive) != nil ? .permission : .input
                }
            }
            if !focused { s.unread = true }
        case .bell:
            if !focused { s.unread = true }
            if !s.hooksSeen, s.agent != .shell, s.activity == .working {
                s.activity = .needsInput
                s.need = .input
            }
        case .progress(let p):
            guard !s.hooksSeen else { break }
            switch p {
            case .active: s.activity = .working
            case .error: s.activity = .error
            case .removed:
                if s.activity == .working {
                    s.activity = .done
                    if !focused { s.unread = true }
                }
            }
        case .commandFinished(let code, let seconds):
            guard s.agent == .shell else { break }
            if let code, code != 0, seconds >= shellCommandThreshold {
                s.activity = .error
                s.detail = "exit \(code)"
                if !focused { s.unread = true }
            } else if seconds >= shellCommandThreshold {
                s.activity = .done
                s.detail = nil
                if !focused { s.unread = true }
            } else if s.activity == .working {
                s.activity = .idle
            }
        case .foregroundProcess(let kind):
            if kind == .shell {
                // Agent quit without telling us (OpenCode/PI have no exit hook).
                agentQuit(&s)
            } else if s.agent != kind {
                s.agent = kind
                s.activity = .idle
                s.detail = nil
                s.agentSessionId = nil
                s.agentCwd = nil
                s.compactFrom = nil
                // The new agent may not have an integration installed.
                s.hooksSeen = false
            }
        case .processExited:
            s.activity = .exited
            s.detail = nil
            s.compactFrom = nil
        case .userSubmitted:
            // Answering a permission prompt: assume the agent continues until a hook says otherwise.
            if s.activity == .needsInput {
                s.activity = .working
                s.detail = nil
            } else if s.agent == .shell, s.activity == .done || s.activity == .error {
                // The next command: its own end (if long) is news again.
                s.activity = .idle
                s.detail = nil
            } else if s.agent != .shell, s.activity == .done || s.activity == .idle, !s.hooksSeen {
                s.activity = .working
            }
        case .userCancelled:
            if s.activity == .needsInput {
                s.activity = .idle
                s.detail = nil
            } else if let back = s.compactFrom, s.agent == .claude, s.hooksSeen, s.activity == .working {
                // Esc stops a `/compact`: no SessionStart follows.
                s.activity = back
                s.compactFrom = nil
            }
        case .viewed:
            s.unread = false
        case .backgroundCommands:
            s.activity = .working
            s.detail = "Background command"
            s.unread = false
        case .backgroundJob(let activity, let detail):
            guard !s.hooksSeen, s.activity != activity else { break }
            s.activity = activity
            s.detail = activity == .needsInput ? detail : nil
            s.need = .input
            if !focused, activity == .needsInput || activity == .done || activity == .error { s.unread = true }
        }
        if s.activity != before { s.since = now }
    }

    /// Session-lifecycle events that legitimately switch the terminal to another agent session.
    static let sessionSwitchSources: Set<String> = ["resume", "clear", "compact"]

    /// Rejects events from a different session of the same agent while one is active, e.g. a
    /// nested `claude -p` run by the agent's own Bash tool, which inherits CORRAL_SURFACE_ID.
    static func accepts(_ s: LiveStatus, _ e: HookEvent) -> Bool {
        if e.isSubSession { return false }
        // Only Claude gets nested runs in practice (`claude -p` from Bash, skills). OpenCode and PI
        // switch sessions inside one process (/sessions, /new), so their events always apply.
        guard e.agent == .claude, s.agent == .claude, let current = s.agentSessionId,
              let incoming = e.sessionId, !incoming.isEmpty, incoming != current else { return true }
        return e.event == "SessionStart" && sessionSwitchSources.contains(e.source ?? "")
    }

    private static func applyHook(_ s: inout LiveStatus, _ e: HookEvent, focused: Bool) {
        if e.agent != .shell, s.agent != e.agent {
            s.agent = e.agent
            // Never carry the previous agent's session over to the new one.
            s.agentSessionId = nil
            s.agentCwd = nil
        }
        if let sid = e.sessionId, !sid.isEmpty {
            if sid != s.agentSessionId || s.agentCwd == nil { s.agentCwd = e.cwd ?? s.agentCwd ?? s.cwd }
            s.agentSessionId = sid
        }
        if let cwd = e.cwd, !cwd.isEmpty { s.cwd = cwd }
        if let t = e.title, !t.isEmpty { s.title = t }
        let compactFrom = s.compactFrom
        if e.event != "PreCompact" { s.compactFrom = nil }

        switch (e.agent, e.event) {
        // Claude Code
        case (.claude, "SessionStart"):
            if e.source == "compact" {
                // Inside a turn the agent keeps working; a compaction between turns goes back to
                // what the session showed before (done, idle, waiting), unread kept.
                if let compactFrom { s.activity = compactFrom }
            } else {
                s.activity = .idle
                s.detail = nil
            }
        case (.claude, "PreCompact"):
            if e.trigger == "manual" {
                // `/compact` runs between turns (typed during one, it waits for the turn to end), so
                // "working" here is only its own UserPromptSubmit, and the user typing it is at the
                // prompt (any earlier question is gone).
                s.compactFrom = compactFrom ?? (s.activity == .working || s.activity == .needsInput ? .idle : s.activity)
                s.activity = .working
                s.detail = nil
            } else if s.activity != .working {
                // Claude compacts idle sessions before the prompt cache expires: nothing runs for the
                // user, and no Stop follows. Mid-turn compaction is part of the work.
                s.compactFrom = compactFrom ?? s.activity
            }
        case (.claude, "UserPromptSubmit"), (.claude, "PreToolUse"), (.claude, "PostToolUse"),
             (.claude, "SubagentStart"):
            s.activity = .working
            s.detail = nil
            s.unread = false
        case (.claude, "PermissionRequest"):
            let asks = askingTools.contains(e.tool ?? "")
            block(&s, e.message ?? "Permission needed", need: asks ? .input : .permission, focused: focused)
            if !asks, e.tool != nil { s.promptId = UUID() }
        case (.claude, "Notification"):
            switch e.notificationType ?? "" {
            case "idle_prompt":
                if s.activity != .needsInput { finish(&s, focused: focused) }
            case "auth_success":
                break
            default:
                // Claude's own notice follows PermissionRequest a few seconds later: keep the
                // request's details ("Bash: git push") over its generic text.
                if s.activity == .needsInput, s.detail != nil { break }
                let permission = e.notificationType == "permission_prompt"
                block(&s, e.message ?? "Needs input", need: permission ? .permission : .input, focused: focused)
            }
        case (.claude, "Stop"):
            finish(&s, focused: focused)
        case (.claude, "StopFailure"):
            s.activity = .error
            s.detail = e.message
            if !focused { s.unread = true }
        case (.claude, "SessionEnd"):
            s.agent = .shell
            s.activity = .idle
            s.detail = nil
            s.hooksSeen = false

        // OpenCode plugin events
        case (.opencode, "session.status"):
            switch e.status {
            case "busy", "retry": s.activity = .working; s.detail = nil
            case "idle": if s.activity == .working { finish(&s, focused: focused) }
            default: break
            }
        case (.opencode, "session.idle"):
            if s.activity != .needsInput { finish(&s, focused: focused) }
        case (.opencode, "permission.asked"), (.opencode, "permission.updated"):
            block(&s, e.message ?? "Permission needed", need: .permission, focused: focused)
        case (.opencode, "question.asked"):
            block(&s, e.message ?? "Question", need: .input, focused: focused)
        case (.opencode, "permission.replied"), (.opencode, "question.replied"):
            s.activity = .working
            s.detail = nil
        case (.opencode, "session.error"):
            s.activity = .error
            s.detail = e.message
            if !focused { s.unread = true }
        case (.opencode, "exit"):
            s.agent = .shell
            s.activity = .idle
            s.hooksSeen = false

        // PI extension events
        case (.pi, "session_start"):
            if s.activity == .exited || s.activity == .error { s.activity = .idle }
        case (.pi, "agent_start"), (.pi, "turn_start"), (.pi, "tool_call"):
            s.activity = .working
            s.detail = nil
        case (.pi, "agent_end"):
            finish(&s, focused: focused)
        case (.pi, "needs_input"):
            block(&s, e.message ?? "Needs input", need: .input, focused: focused)
        case (.pi, "session_shutdown"):
            s.agent = .shell
            s.activity = .idle
            s.hooksSeen = false

        default:
            break
        }
    }

    /// An agent's "turn finished, your move" notice, as opposed to a question or permission prompt.
    public static func isIdleNotice(_ body: String) -> Bool {
        body.range(of: "waiting for your input", options: .caseInsensitive) != nil
    }

    /// Back at the shell: the agent is gone, its session id stays for resume.
    private static func agentQuit(_ s: inout LiveStatus) {
        guard s.agent != .shell else { return }
        s.agent = .shell
        s.activity = .idle
        s.detail = nil
        s.hooksSeen = false
        s.compactFrom = nil
    }

    /// PermissionRequest tools that put a question to the user rather than ask to act.
    static let askingTools: Set<String> = ["AskUserQuestion", "ExitPlanMode"]

    private static func block(_ s: inout LiveStatus, _ detail: String, need: Need, focused: Bool) {
        s.activity = .needsInput
        s.detail = detail
        s.need = need
        s.promptId = nil
        // Needs-input always counts as unread until the user looks at it.
        s.unread = !focused
    }

    private static func finish(_ s: inout LiveStatus, focused: Bool) {
        s.activity = .done
        s.detail = nil
        if !focused { s.unread = true }
    }

    /// Strips spinner glyphs and status prefixes agents put into the terminal title.
    public static func cleanTitle(_ raw: String) -> String {
        var t = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let decorations = CharacterSet(charactersIn: "✳✻✽✶✢·*⠁⠂⠄⡀⢀⠠⠐⠈⠋⠙⠹⠸⠼⠴⠦⠧⠇⠏◐◓◑◒●○•")
        while let first = t.unicodeScalars.first, decorations.contains(first) || first == " " {
            t.removeFirst()
        }
        return t
    }
}

/// Maps a process to the agent it runs. `path` = executable path, `args` = argv.
public enum AgentDetector {
    public static func detect(path: String, args: [String]) -> AgentKind? {
        let exe = (path as NSString).lastPathComponent.lowercased()
        if exe == "claude" || path.contains("/claude/versions/") { return .claude }
        if exe == "opencode" || path.contains("/.opencode/") { return .opencode }
        if exe == "pi" { return .pi }
        if exe == "node" || exe == "bun" || exe == "deno" {
            for arg in args.dropFirst().prefix(3) {
                let base = (arg as NSString).lastPathComponent.lowercased()
                if base == "pi" || arg.contains("pi-coding-agent") { return .pi }
                if base == "opencode" || arg.contains("opencode-ai") { return .opencode }
                if base == "claude" || arg.contains("@anthropic-ai/claude-code") { return .claude }
            }
        }
        let shells: Set<String> = ["zsh", "-zsh", "bash", "-bash", "fish", "-fish", "sh", "nu", "login"]
        if shells.contains(exe) { return .shell }
        return nil
    }
}
