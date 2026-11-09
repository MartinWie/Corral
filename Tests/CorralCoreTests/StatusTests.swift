import Foundation
import Testing
@testable import CorralCore

struct StatusTests {
    func hook(_ agent: AgentKind, _ event: String, type: String? = nil, status: String? = nil,
              sid: String? = nil, message: String? = nil) -> Signal {
        .hook(HookEvent(agent: agent, event: event, sessionId: sid, message: message, notificationType: type, status: status))
    }

    @Test func claudeLifecycle() {
        var s = LiveStatus()
        StatusReducer.reduce(&s, hook(.claude, "SessionStart", sid: "abc"), focused: true)
        #expect(s.agent == .claude)
        #expect(s.activity == .idle)
        #expect(s.agentSessionId == "abc")

        StatusReducer.reduce(&s, hook(.claude, "UserPromptSubmit"), focused: true)
        #expect(s.activity == .working)

        StatusReducer.reduce(&s, hook(.claude, "Notification", type: "permission_prompt", message: "Claude needs your permission to use Bash"), focused: false)
        #expect(s.activity == .needsInput)
        #expect(s.unread)
        #expect(s.detail == "Claude needs your permission to use Bash")

        StatusReducer.reduce(&s, .userSubmitted, focused: true)
        #expect(s.activity == .working)

        StatusReducer.reduce(&s, hook(.claude, "Stop"), focused: false)
        #expect(s.activity == .done)
        #expect(s.unread)

        StatusReducer.reduce(&s, .viewed, focused: true)
        #expect(!s.unread)

        StatusReducer.reduce(&s, hook(.claude, "SessionEnd"), focused: true)
        #expect(s.agent == .shell)
        #expect(s.activity == .idle)
    }

    @Test func idlePromptDoesNotOverrideNeedsInput() {
        var s = LiveStatus()
        StatusReducer.reduce(&s, hook(.claude, "PermissionRequest"), focused: false)
        #expect(s.activity == .needsInput)
        StatusReducer.reduce(&s, hook(.claude, "Notification", type: "idle_prompt"), focused: false)
        #expect(s.activity == .needsInput)
    }

    @Test func doneWhileFocusedIsRead() {
        var s = LiveStatus()
        StatusReducer.reduce(&s, hook(.claude, "UserPromptSubmit"), focused: true)
        StatusReducer.reduce(&s, hook(.claude, "Stop"), focused: true)
        #expect(s.activity == .done)
        #expect(!s.unread)
    }

    @Test func escapeDismissesPrompt() {
        var s = LiveStatus()
        StatusReducer.reduce(&s, hook(.claude, "PermissionRequest"), focused: true)
        StatusReducer.reduce(&s, .userCancelled, focused: true)
        #expect(s.activity == .idle)
    }

    @Test func openCodeEvents() {
        var s = LiveStatus()
        StatusReducer.reduce(&s, hook(.opencode, "session.status", status: "busy", sid: "ses_1"), focused: false)
        #expect(s.agent == .opencode)
        #expect(s.activity == .working)
        StatusReducer.reduce(&s, hook(.opencode, "permission.asked", message: "bash: rm -rf"), focused: false)
        #expect(s.activity == .needsInput)
        StatusReducer.reduce(&s, hook(.opencode, "permission.replied"), focused: false)
        #expect(s.activity == .working)
        StatusReducer.reduce(&s, hook(.opencode, "session.idle"), focused: false)
        #expect(s.activity == .done)
        #expect(s.unread)
    }

    @Test func subSessionEventsIgnored() {
        var s = LiveStatus()
        var e = HookEvent(agent: .opencode, event: "session.status", status: "busy")
        e.isSubSession = true
        StatusReducer.reduce(&s, .hook(e), focused: false)
        #expect(s.activity == .idle)
    }

    @Test func piEvents() {
        var s = LiveStatus()
        StatusReducer.reduce(&s, hook(.pi, "agent_start", sid: "/s.jsonl"), focused: false)
        #expect(s.activity == .working)
        StatusReducer.reduce(&s, hook(.pi, "agent_end"), focused: false)
        #expect(s.activity == .done)
        StatusReducer.reduce(&s, hook(.pi, "session_shutdown"), focused: false)
        #expect(s.agent == .shell)
    }

    @Test func terminalFallbackWithoutHooks() {
        var s = LiveStatus()
        StatusReducer.reduce(&s, .foregroundProcess(.claude), focused: false)
        #expect(s.agent == .claude)
        StatusReducer.reduce(&s, .progress(.active), focused: false)
        #expect(s.activity == .working)
        StatusReducer.reduce(&s, .desktopNotification(title: "Claude Code", body: "Claude needs your permission"), focused: false)
        #expect(s.activity == .needsInput)
        StatusReducer.reduce(&s, .userSubmitted, focused: true)
        StatusReducer.reduce(&s, .progress(.removed), focused: false)
        #expect(s.activity == .done)
        #expect(s.unread)
    }

    /// Claude's idle notice ends the turn (background shells may still run); it never asks anything.
    @Test func idleNoticeIsDoneNotNeedsInput() {
        var s = LiveStatus()
        StatusReducer.reduce(&s, .foregroundProcess(.claude), focused: false)
        StatusReducer.reduce(&s, .progress(.active), focused: false)
        StatusReducer.reduce(&s, .desktopNotification(title: "Claude Code", body: "Claude is waiting for your input"), focused: false)
        #expect(s.activity == .done)
        #expect(s.unread)
        // A real question stays a question; a later idle notice doesn't clear it.
        StatusReducer.reduce(&s, .desktopNotification(title: "Claude Code", body: "Claude needs your permission to use Bash"), focused: false)
        #expect(s.activity == .needsInput)
        StatusReducer.reduce(&s, .desktopNotification(title: "Claude Code", body: "Claude is waiting for your input"), focused: false)
        #expect(s.activity == .needsInput)
        #expect(StatusReducer.isIdleNotice("CLAUDE IS WAITING FOR YOUR INPUT"))
        #expect(!StatusReducer.isIdleNotice("Allow Bash?"))
    }

    @Test func hooksSilenceTerminalHeuristics() {
        var s = LiveStatus()
        StatusReducer.reduce(&s, hook(.claude, "UserPromptSubmit"), focused: false)
        StatusReducer.reduce(&s, .progress(.removed), focused: false)
        StatusReducer.reduce(&s, .desktopNotification(title: "x", body: "y"), focused: false)
        #expect(s.activity == .working)
    }

    @Test func agentExitDetectedByForegroundShell() {
        var s = LiveStatus()
        StatusReducer.reduce(&s, hook(.opencode, "session.status", status: "busy"), focused: false)
        StatusReducer.reduce(&s, .foregroundProcess(.shell), focused: false)
        #expect(s.agent == .shell)
        #expect(s.activity == .idle)
    }

    @Test func longShellCommands() {
        var s = LiveStatus()
        StatusReducer.reduce(&s, .commandFinished(exitCode: 0, seconds: 1), focused: false)
        #expect(s.activity == .idle)
        StatusReducer.reduce(&s, .commandFinished(exitCode: 0, seconds: 42), focused: false)
        #expect(s.activity == .done)
        #expect(s.unread)
        StatusReducer.reduce(&s, .commandFinished(exitCode: 2, seconds: 42), focused: false)
        #expect(s.activity == .error)
        #expect(s.detail == "exit 2")
    }

    @Test func titleCleanup() {
        #expect(StatusReducer.cleanTitle("✳ Fix login bug") == "Fix login bug")
        #expect(StatusReducer.cleanTitle("⠋ ⠙ Working") == "Working")
        #expect(StatusReducer.cleanTitle("plain") == "plain")
    }

    @Test func sinceUpdatesOnlyOnActivityChange() {
        var s = LiveStatus()
        let t0 = Date(timeIntervalSince1970: 100)
        StatusReducer.reduce(&s, hook(.claude, "UserPromptSubmit"), focused: false, now: t0)
        StatusReducer.reduce(&s, hook(.claude, "PostToolUse"), focused: false, now: Date(timeIntervalSince1970: 200))
        #expect(s.since == t0)
    }

    @Test func agentDetection() {
        #expect(AgentDetector.detect(path: "/Users/x/.local/share/claude/versions/2.1.318", args: []) == .claude)
        #expect(AgentDetector.detect(path: "/Users/x/.opencode/bin/opencode", args: []) == .opencode)
        #expect(AgentDetector.detect(path: "/opt/homebrew/bin/node", args: ["node", "/opt/homebrew/bin/pi"]) == .pi)
        #expect(AgentDetector.detect(path: "/bin/zsh", args: ["-zsh"]) == .shell)
        #expect(AgentDetector.detect(path: "/usr/bin/vim", args: ["vim"]) == nil)
    }

    @Test func processInspectorSeesSelf() {
        let pid = getpid()
        #expect(ProcessInspector.executablePath(pid: pid) != nil)
        #expect(!ProcessInspector.arguments(pid: pid).isEmpty)
    }
}
