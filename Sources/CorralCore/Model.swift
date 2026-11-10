import Foundation

/// Program running in a session's terminal.
public enum AgentKind: String, Codable, CaseIterable, Sendable {
    case shell, claude, opencode, pi

    public var displayName: String {
        switch self {
        case .shell: return "Shell"
        case .claude: return "Claude Code"
        case .opencode: return "OpenCode"
        case .pi: return "PI"
        }
    }

    /// Command that starts the agent in a new session's terminal (see `AgentLaunch`).
    public var launchCommand: String? {
        switch self {
        case .shell: return nil
        case .claude: return "claude"
        case .opencode: return "opencode"
        case .pi: return "pi"
        }
    }

    /// Command that resumes an existing agent session; the terminal falls back to a shell when the
    /// agent exits.
    /// A fresh session under an id Corral picks, so it can be resumed without the status hooks
    /// (Claude Code only: the others choose their own ids).
    public func startCommand(sessionId: String) -> String? {
        self == .claude ? "claude --session-id \(shellQuote(sessionId))" : nil
    }

    public func resumeCommand(sessionId: String) -> String? {
        let id = shellQuote(sessionId)
        switch self {
        case .shell: return nil
        case .claude: return "claude --resume \(id)"
        case .opencode: return "opencode -s \(id)"
        case .pi: return "pi --session \(id)"
        }
    }
}

/// What a session is doing right now, as shown by the sidebar icon.
public enum Activity: String, Codable, Sendable {
    /// Shell prompt or agent waiting for its first prompt.
    case idle
    case working
    /// Agent blocked on the user: permission prompt, question, elicitation.
    case needsInput
    /// Agent finished its turn and waits for the next prompt.
    case done
    case error
    /// Terminal process exited.
    case exited

    /// Higher sorts first when jumping to the next session that wants attention.
    public var attentionRank: Int {
        switch self {
        case .needsInput: return 3
        case .error: return 2
        case .done: return 1
        default: return 0
        }
    }
}

public struct SessionRecord: Codable, Identifiable, Equatable, Sendable {
    public var id: UUID
    /// Name the user gave the session; wins over everything else.
    public var customName: String?
    /// Name set inside the agent (Claude's /rename, PI's session name); below `customName`. "" once
    /// synced while the conversation has none, nil before (`Workspace.setAgentName`).
    public var agentName: String?
    /// Latest title reported by the agent or terminal.
    public var autoTitle: String
    public var cwd: String
    /// Last agent seen in this session (kept after the agent exits so it can be resumed).
    public var agent: AgentKind
    public var agentSessionId: String?
    /// Directory the agent session started in. Claude finds conversations by project
    /// directory, so resume runs here even if the shell has moved on.
    public var agentCwd: String?
    /// Claude background job this session is attached to (`claude attach`).
    public var bgJobId: String?
    /// True while the agent process was running; decides whether restore resumes it.
    public var agentRunning: Bool
    public var createdAt: Date
    public var lastActiveAt: Date
    public var closedAt: Date?
    /// Folder the session sat in when it was closed, so reopening puts it back.
    public var lastFolder: UUID?

    public init(id: UUID = UUID(), cwd: String, agent: AgentKind = .shell, title: String = "",
                agentSessionId: String? = nil, now: Date = Date()) {
        self.id = id
        self.autoTitle = title
        self.cwd = cwd
        self.agent = agent
        self.agentSessionId = agentSessionId
        self.agentRunning = agent != .shell
        self.createdAt = now
        self.lastActiveAt = now
    }

    /// The search index's key for the agent conversation (Claude, OpenCode: session id; PI: session file).
    public var searchKey: String? {
        agentSessionId.map { "\(agent.rawValue):\($0)" }
    }

    /// A name someone picked: the user's in Corral, else the one given inside the agent.
    public var givenName: String? {
        if let customName, !customName.isEmpty { return customName }
        if let agentName, !agentName.isEmpty { return agentName }
        return nil
    }

    public var displayTitle: String {
        if let givenName { return givenName }
        if !autoTitle.isEmpty { return autoTitle }
        return cwd.pathLeaf
    }

    /// Whether a terminal title names this session. An agent's titles do. Once a session ran an agent,
    /// the shell around it doesn't: Ghostty's shell integration titles every prompt with the
    /// directory, which would rename the session "~/Documents/Code" as soon as the agent exits.
    public func takesTerminalTitle(fromAgent: Bool) -> Bool {
        fromAgent || agent == .shell
    }

    /// Agent command for a new terminal when this session is reopened or restored.
    public var restoreInput: String? {
        guard agentRunning else { return nil }
        if let job = bgJobId { return Self.attachOrResume(job: job, sessionId: agentSessionId) }
        guard let sid = agentSessionId else { return nil }
        return agent.resumeCommand(sessionId: sid)
    }

    /// Working directory for a new terminal that runs `input`.
    public func launchDirectory(resuming: Bool) -> String {
        resuming ? (agentCwd ?? cwd) : cwd
    }

    /// Like `restoreInput` but also resumes an agent that already exited (explicit reopen).
    public var reopenInput: String? {
        if let job = bgJobId { return Self.attachOrResume(job: job, sessionId: agentSessionId) }
        guard let sid = agentSessionId else { return nil }
        return agent.resumeCommand(sessionId: sid)
    }

    /// Attach to a background job; after a reboot the job is gone, so restart it in the background first.
    /// `a || ! b || a` is `a || { b && a; }` without the braces: a job suspended (Ctrl-Z) inside a
    /// `{ }` group can't be resumed by the launch script, the agent would be lost.
    static func attachOrResume(job: String, sessionId: String?) -> String {
        let attach = "claude attach \(shellQuote(job))"
        guard let sid = sessionId else { return attach }
        return "\(attach) || ! claude --bg --resume \(shellQuote(sid)) || \(attach)"
    }
}

public struct Folder: Codable, Identifiable, Equatable, Sendable {
    public var id: UUID
    public var name: String
    public var expanded: Bool
    /// Default working directory for sessions created inside this folder.
    public var directory: String?

    public init(id: UUID = UUID(), name: String, expanded: Bool = true, directory: String? = nil) {
        self.id = id
        self.name = name
        self.expanded = expanded
        self.directory = directory
    }
}

/// Defaults for new sessions of one agent kind ("default folder for agent sessions").
public struct AgentDefaults: Codable, Equatable, Sendable {
    /// Start directory, e.g. ~/Documents/Code.
    public var directory: String?
    /// Sidebar folder new sessions are placed in.
    public var folder: UUID?

    public init(directory: String? = nil, folder: UUID? = nil) {
        self.directory = directory
        self.folder = folder
    }

    public var isEmpty: Bool { directory == nil && folder == nil }
}

/// Sidebar order: sessions and (nestable) folders.
public indirect enum TreeItem: Codable, Equatable, Sendable {
    case session(UUID)
    case folder(UUID, [TreeItem])

    public var id: UUID {
        switch self {
        case .session(let id), .folder(let id, _): return id
        }
    }

    public var isFolder: Bool {
        if case .folder = self { return true }
        return false
    }
}

public func shellQuote(_ s: String) -> String {
    let safe = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_./:=@%+,")
    if !s.isEmpty, s.unicodeScalars.allSatisfy({ safe.contains($0) }) { return s }
    return "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
}

public extension String {
    /// `NSString.lastPathComponent` as a native Swift string. The bridged result (NSPathStore2)
    /// compares through Swift's slow normalizing path, which dominated sidebar refreshes.
    /// Works on UTF-8 bytes: a `/` followed by a combining mark is one Character in Swift, but
    /// still a separator for NSString.
    var pathLeaf: String {
        let u = utf8, slash = UInt8(ascii: "/")
        var end = u.endIndex
        while end != u.startIndex, u[u.index(before: end)] == slash { end = u.index(before: end) }
        if end == u.startIndex { return u.isEmpty ? "" : "/" }
        let start = u[..<end].lastIndex(of: slash).map { u.index(after: $0) } ?? u.startIndex
        return String(decoding: u[start..<end], as: UTF8.self)
    }
}
