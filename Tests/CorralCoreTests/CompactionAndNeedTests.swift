import Foundation
import Testing
@testable import CorralCore

/// Compaction between turns (Claude's idle compaction, `/compact`) and why a session waits.
struct CompactionAndNeedTests {
    func claude(_ event: String, source: String? = nil, trigger: String? = nil, type: String? = nil,
                message: String? = nil, tool: String? = nil) -> Signal {
        .hook(HookEvent(agent: .claude, event: event, sessionId: "a", message: message, notificationType: type,
                        source: source, trigger: trigger, tool: tool))
    }

    func finished(unread: Bool = true) -> LiveStatus {
        var s = LiveStatus()
        StatusReducer.reduce(&s, claude("UserPromptSubmit"), focused: true)
        StatusReducer.reduce(&s, claude("Stop"), focused: !unread)
        return s
    }

    @Test func idleCompactionLeavesAFinishedSessionFinished() {
        // Claude compacts an idle session ~55 min after its turn; no Stop follows.
        for trigger in ["auto", "idle", nil] as [String?] {
            var s = finished()
            let since = s.since
            StatusReducer.reduce(&s, claude("PreCompact", trigger: trigger), focused: false,
                                 now: Date().addingTimeInterval(3300))
            #expect(s.activity == .done && s.unread)
            #expect(s.compactFrom == .done)
            StatusReducer.reduce(&s, claude("SessionStart", source: "compact"), focused: false)
            #expect(s.activity == .done && s.unread)
            #expect(s.compactFrom == nil)
            #expect(s.since == since)
        }
    }

    @Test func idleCompactionKeepsAWaitingPrompt() {
        var s = LiveStatus()
        StatusReducer.reduce(&s, claude("PermissionRequest", message: "Bash: rm -rf build"), focused: false)
        StatusReducer.reduce(&s, claude("PreCompact", trigger: "auto"), focused: false)
        StatusReducer.reduce(&s, claude("SessionStart", source: "compact"), focused: false)
        #expect(s.activity == .needsInput)
        #expect(s.detail == "Bash: rm -rf build")
        #expect(s.need == .permission)
    }

    @Test func midTurnCompactionKeepsWorkingUntilStop() {
        var s = LiveStatus()
        StatusReducer.reduce(&s, claude("UserPromptSubmit"), focused: false)
        StatusReducer.reduce(&s, claude("PreCompact", trigger: "auto"), focused: false)
        #expect(s.activity == .working && s.compactFrom == nil)
        StatusReducer.reduce(&s, claude("SessionStart", source: "compact"), focused: false)
        #expect(s.activity == .working)
        StatusReducer.reduce(&s, claude("Stop"), focused: false)
        #expect(s.activity == .done)
    }

    @Test func manualCompactShowsWorkingAndThenReturns() {
        // Typed `/compact` with no UserPromptSubmit: back to done.
        var s = finished(unread: false)
        StatusReducer.reduce(&s, claude("PreCompact", trigger: "manual"), focused: true)
        #expect(s.activity == .working)
        StatusReducer.reduce(&s, claude("SessionStart", source: "compact"), focused: true)
        #expect(s.activity == .done)

        // Its own UserPromptSubmit made it "working" first: the session waits for input afterwards.
        StatusReducer.reduce(&s, claude("UserPromptSubmit"), focused: true)
        StatusReducer.reduce(&s, claude("PreCompact", trigger: "manual"), focused: true)
        #expect(s.compactFrom == .idle)
        StatusReducer.reduce(&s, claude("SessionStart", source: "compact"), focused: true)
        #expect(s.activity == .idle && s.compactFrom == nil)

        // Typing `/compact` answers nothing, but the user is at the prompt: an old question is gone.
        StatusReducer.reduce(&s, claude("Notification", type: "elicitation_dialog", message: "Pick"), focused: true)
        StatusReducer.reduce(&s, claude("PreCompact", trigger: "manual"), focused: true)
        StatusReducer.reduce(&s, claude("SessionStart", source: "compact"), focused: true)
        #expect(s.activity == .idle)
    }

    @Test func aQuitAgentLeavesNoCompactionBehind() {
        for exit in [Signal.hook(HookEvent(agent: .shell, event: AgentLaunch.exitEvent)), .foregroundProcess(.shell),
                     .processExited, .foregroundProcess(.opencode)] {
            var s = finished(unread: false)
            StatusReducer.reduce(&s, claude("PreCompact", trigger: "manual"), focused: true)
            StatusReducer.reduce(&s, exit, focused: true)
            #expect(s.compactFrom == nil)
            // A shell tool's progress, then Esc in it: still working.
            StatusReducer.reduce(&s, .progress(.active), focused: true)
            let before = s.activity
            StatusReducer.reduce(&s, .userCancelled, focused: true)
            #expect(s.activity == before)
        }
    }

    @Test func returnInAFinishedShellStartsOver() {
        var s = LiveStatus()
        StatusReducer.reduce(&s, .commandFinished(exitCode: 0, seconds: 30), focused: false)
        #expect(s.activity == .done)
        StatusReducer.reduce(&s, .userSubmitted, focused: true)
        #expect(s.activity == .idle)
        StatusReducer.reduce(&s, .commandFinished(exitCode: 2, seconds: 30), focused: false)
        #expect(s.activity == .error && s.detail == "exit 2")
        StatusReducer.reduce(&s, .userSubmitted, focused: true)
        #expect(s.activity == .idle && s.detail == nil)
    }

    @Test func escapeEndsAManualCompact() {
        var s = finished(unread: false)
        StatusReducer.reduce(&s, claude("PreCompact", trigger: "manual"), focused: true)
        StatusReducer.reduce(&s, .userCancelled, focused: true)
        #expect(s.activity == .done && s.compactFrom == nil)
        // Esc mid-turn changes nothing.
        StatusReducer.reduce(&s, claude("UserPromptSubmit"), focused: true)
        StatusReducer.reduce(&s, .userCancelled, focused: true)
        #expect(s.activity == .working)
    }

    @Test func aNewTurnForgetsAnUnfinishedCompaction() {
        var s = finished()
        StatusReducer.reduce(&s, claude("PreCompact", trigger: "auto"), focused: false)
        StatusReducer.reduce(&s, claude("UserPromptSubmit"), focused: true)
        #expect(s.compactFrom == nil)
        StatusReducer.reduce(&s, claude("SessionStart", source: "compact"), focused: true)
        #expect(s.activity == .working)
    }

    @Test func permissionAndQuestionsAreTold() {
        var s = LiveStatus()
        StatusReducer.reduce(&s, claude("PermissionRequest", message: "Bash: git push", tool: "Bash"), focused: false)
        #expect(s.need == .permission)
        // Claude's generic notice a few seconds later keeps the request's details.
        StatusReducer.reduce(&s, claude("Notification", type: "permission_prompt",
                                        message: "Claude needs your permission to use Bash"), focused: false)
        #expect(s.detail == "Bash: git push" && s.need == .permission)

        for tool in ["AskUserQuestion", "ExitPlanMode"] {
            var q = LiveStatus()
            StatusReducer.reduce(&q, claude("PermissionRequest", message: "Which one?", tool: tool), focused: false)
            #expect(q.need == .input)
        }
        var e = LiveStatus()
        StatusReducer.reduce(&e, claude("Notification", type: "elicitation_dialog", message: "Pick a server"), focused: false)
        #expect(e.activity == .needsInput && e.need == .input && e.detail == "Pick a server")
        var p = LiveStatus()
        StatusReducer.reduce(&p, claude("Notification", type: "permission_prompt"), focused: false)
        #expect(p.need == .permission && p.detail == "Needs input")

        var oc = LiveStatus()
        StatusReducer.reduce(&oc, .hook(HookEvent(agent: .opencode, event: "permission.asked")), focused: false)
        #expect(oc.need == .permission && oc.detail == "Permission needed")
        StatusReducer.reduce(&oc, .hook(HookEvent(agent: .opencode, event: "permission.replied")), focused: false)
        StatusReducer.reduce(&oc, .hook(HookEvent(agent: .opencode, event: "question.asked")), focused: false)
        #expect(oc.need == .input && oc.detail == "Question")
        var pi = LiveStatus()
        StatusReducer.reduce(&pi, .hook(HookEvent(agent: .pi, event: "needs_input")), focused: false)
        #expect(pi.need == .input)
    }

    @Test func terminalSignalsWithoutHooksAreTold() {
        var s = LiveStatus()
        s.agent = .claude
        s.activity = .working
        StatusReducer.reduce(&s, .desktopNotification(title: "Claude Code", body: "Claude needs your permission to use Bash"),
                             focused: false)
        #expect(s.need == .permission)
        s.activity = .working
        StatusReducer.reduce(&s, .bell, focused: false)
        #expect(s.activity == .needsInput && s.need == .input)
        var bg = LiveStatus()
        bg.need = .permission
        StatusReducer.reduce(&bg, .backgroundJob(.needsInput, detail: "Approve?"), focused: false)
        #expect(bg.need == .input && bg.detail == "Approve?")
    }
}
