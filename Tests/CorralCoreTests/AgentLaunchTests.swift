import Foundation
import Testing
@testable import CorralCore

struct AgentLaunchTests {
    @Test func directLaunchOnlyForZsh() {
        for shell in ["/bin/zsh", "/opt/homebrew/bin/zsh", "zsh"] {
            #expect(AgentLaunch.supportsDirect(shell: shell), "\(shell)")
        }
        for shell in ["/bin/bash", "/opt/homebrew/bin/fish", "/bin/sh", "", "/usr/local/bin/zsh5"] {
            #expect(!AgentLaunch.supportsDirect(shell: shell), "\(shell)")
        }
        #expect(AgentLaunch.command(input: "claude", shell: "/bin/bash", agent: .claude) == nil)
        #expect(AgentLaunch.command(input: "claude", shell: "/usr/bin/fish", agent: .claude) == nil)
    }

    @Test func commandIsOneQuotedOuterScript() throws {
        let cmd = try #require(AgentLaunch.command(input: "claude --resume 'a b'", shell: "/bin/zsh", agent: .claude))
        #expect(cmd.hasPrefix("/bin/zsh -fc '"))
        #expect(cmd.hasSuffix("'"))
        // A shell path with spaces is quoted too.
        let spaced = try #require(AgentLaunch.command(input: "pi", shell: "/Applications/My Tools/zsh", agent: .pi))
        #expect(spaced.hasPrefix("'/Applications/My Tools/zsh' -fc '"))
        #expect(AgentLaunch.outerScript(input: "pi", shell: "/Applications/My Tools/zsh", agent: .pi)
            .hasSuffix("exec '/Applications/My Tools/zsh' -l"))
    }

    @Test func scriptShape() {
        let outer = AgentLaunch.outerScript(input: "opencode -s ses_1", shell: "/bin/zsh", agent: .opencode)
        let lines = outer.components(separatedBy: "\n")
        #expect(lines.first == "trap : INT QUIT TSTP")
        let run = "trap : INT QUIT TSTP\n/bin/zsh -lic " + shellQuote(AgentLaunch.innerScript(input: "opencode -s ses_1"))
        #expect(outer.hasPrefix(run + "\n__corral_rc=$?\n"))
        #expect(outer.contains(#"| "$CORRAL_HOOK" opencode CorralAgentExit"#))
        #expect(lines.last == "exec /bin/zsh -l")
        // No ZDOTDIR juggling: the follow-up shell gets the terminal's own environment.
        #expect(!outer.contains("ZDOTDIR"))

        let inner = AgentLaunch.innerScript(input: "opencode -s ses_1").components(separatedBy: "\n")
        // The gitstatus exit hook is registered before the agent runs.
        #expect(inner[0].hasPrefix("__corral_reap() {"))
        #expect(inner[1] == "zshexit_functions+=(__corral_reap)")
        // Top level, not inside `{ }`: a suspended agent must stay a job of this shell.
        #expect(inner[2] == "opencode -s ses_1")
        #expect(inner[3] == "__corral_rc=$?")
        #expect(inner.last == "exit $__corral_rc")
    }

    @Test func kindsAndLabels() {
        #expect(AgentLaunch.kind(resuming: false, backgroundJob: false) == .starting)
        #expect(AgentLaunch.kind(resuming: true, backgroundJob: false) == .resuming)
        #expect(AgentLaunch.kind(resuming: true, backgroundJob: true) == .attaching)
        #expect(AgentLaunch.Kind.starting.title(agent: .claude) == "Starting Claude Code")
        #expect(AgentLaunch.Kind.resuming.title(agent: .opencode) == "Resuming OpenCode")
        #expect(AgentLaunch.Kind.attaching.title(agent: .claude) == "Attaching to background agent")
        #expect(AgentLaunch.Kind.starting.rowSubtitle == "Starting…")
        #expect(AgentLaunch.Kind.resuming.rowSubtitle == "Resuming…")
        #expect(AgentLaunch.Kind.attaching.rowSubtitle == "Attaching…")
        #expect(AgentLaunch.Kind.starting.accessibilityState == "Starting")
        #expect(AgentLaunch.Kind.resuming.accessibilityState == "Resuming")
        #expect(AgentLaunch.Kind.attaching.accessibilityState == "Attaching")
    }

    // MARK: Exit report

    @Test func exitEventDecodesExitCode() throws {
        let surface = UUID()
        let line = Data(#"{"surface":"\#(surface.uuidString)","agent":"claude","event":"CorralAgentExit","payload":{"exit":130}}"#.utf8)
        let msg = try #require(HookWire.decode(line: line))
        #expect(msg.event.event == AgentLaunch.exitEvent)
        #expect(msg.event.exitCode == 130)
        let noPayload = try #require(HookWire.decode(line: Data(#"{"surface":"\#(surface.uuidString)","agent":"pi","event":"CorralAgentExit","payload":null}"#.utf8)))
        #expect(noPayload.event.exitCode == nil)
        let bool = try #require(HookWire.decode(line: Data(#"{"surface":"\#(surface.uuidString)","agent":"pi","event":"CorralAgentExit","payload":{"exit":true}}"#.utf8)))
        #expect(bool.event.exitCode == nil)
        // Other events never carry an exit code.
        let stop = try #require(HookWire.decode(line: Data(#"{"surface":"\#(surface.uuidString)","agent":"claude","event":"Stop","payload":{"exit":1}}"#.utf8)))
        #expect(stop.event.exitCode == nil)
    }

    @Test func exitEventEndsTheAgentWithoutCountingAsHooks() {
        var s = LiveStatus()
        s.agent = .opencode
        s.agentSessionId = "ses_1"
        s.activity = .working
        let exit = Signal.hook(HookEvent(agent: .opencode, event: AgentLaunch.exitEvent, exitCode: 1))
        StatusReducer.reduce(&s, exit, focused: false)
        #expect(s.agent == .shell)
        #expect(s.activity == .idle)
        #expect(!s.hooksSeen)
        // Kept for resume, like the foreground-process path.
        #expect(s.agentSessionId == "ses_1")

        // Same outcome as the terminal noticing the agent quit.
        var viaForeground = LiveStatus()
        viaForeground.agent = .opencode
        viaForeground.agentSessionId = "ses_1"
        viaForeground.activity = .working
        StatusReducer.reduce(&viaForeground, .foregroundProcess(.shell), focused: false)
        #expect(viaForeground.agent == s.agent && viaForeground.activity == s.activity && viaForeground.hooksSeen == s.hooksSeen)

        // After real hooks, the report still ends the agent and hands back to terminal heuristics.
        var hooked = LiveStatus()
        StatusReducer.reduce(&hooked, .hook(HookEvent(agent: .claude, event: "SessionStart", sessionId: "c1")), focused: true)
        #expect(hooked.hooksSeen)
        StatusReducer.reduce(&hooked, exit, focused: true)
        #expect(hooked.agent == .shell)
        #expect(!hooked.hooksSeen)

        // A plain shell stays as it is.
        var shell = LiveStatus()
        shell.activity = .done
        StatusReducer.reduce(&shell, exit, focused: true)
        #expect(shell.activity == .done)
        #expect(!shell.hooksSeen)
    }

    // MARK: Executing the scripts

    /// Runs the launch command the way Ghostty does (`bash --noprofile --norc -c "exec -l <command>"`)
    /// on a pseudo-terminal (`script`, whose stdin is a pipe so tests can type Ctrl-C / Ctrl-Z), with a
    /// stand-in "zsh": `-fc` runs the outer script in a real zsh, `-lic` runs the inner one in a real
    /// interactive zsh without rc files (after `FAKE_RC`, standing in for slow rc files), and the
    /// follow-up `-l` prints what it inherited and exits. The tty matters: job control, Ctrl-C/Ctrl-Z
    /// and zsh aborting its command list after SIGINT only happen with one.
    final class Harness: @unchecked Sendable {
        let dir: URL
        let shell: String
        let hookLog: URL
        private let lock = NSLock()
        private var buffer = Data()

        init() throws {
            dir = FileManager.default.temporaryDirectory.appendingPathComponent("corral-launch-\(UUID().uuidString)")
            let bin = dir.appendingPathComponent("bin")
            try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
            shell = bin.appendingPathComponent("zsh").path
            hookLog = dir.appendingPathComponent("hook.log")
            try Self.script(shell, """
            #!/bin/sh
            case "$1" in
              -fc) exec /bin/zsh -f -c "$2" ;;
              -lic) exec /bin/zsh -f -ic "${FAKE_RC:-:}
            $2" ;;
            esac
            printf 'FOLLOWUP args=%s ZDOTDIR=%s GZ=%s RC=%s\\n' "$*" "${ZDOTDIR-unset}" "${GHOSTTY_ZSH_ZDOTDIR-unset}" "${RC_VAR-unset}"
            """)
            try Self.script(bin.appendingPathComponent("corral-hook").path, """
            #!/bin/sh
            printf '%s %s ' "$1" "$2" >> "\(hookLog.path)"
            cat >> "\(hookLog.path)"
            """)
            // A hook slow enough to be interrupted while it reports.
            try Self.script(bin.appendingPathComponent("slow-hook").path, """
            #!/bin/sh
            printf 'HOOK-UP\\n'
            sleep 3
            printf '%s %s ' "$1" "$2" >> "\(hookLog.path)"
            cat >> "\(hookLog.path)"
            """)
            // Stand-in agent for the background attach-or-resume chain.
            try Self.script(bin.appendingPathComponent("claude").path, """
            #!/bin/sh
            echo "claude $*"
            [ "$1" = "attach" ] && exit 1
            exit 0
            """)
        }

        static func script(_ path: String, _ body: String) throws {
            try body.write(toFile: path, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: path)
        }

        var output: String {
            lock.withLock { String(decoding: buffer, as: UTF8.self) }.replacingOccurrences(of: "\r", with: "")
        }

        /// Runs `input` as the agent. Each key is typed 0.2 s after the output shows its marker (the
        /// process printing it is then blocked in its `sleep`, not between commands).
        func run(_ input: String, agent: AgentKind = .claude, keys: [(after: String, bytes: String)] = [],
                 env extra: [String: String] = [:]) throws -> (out: String, hook: String) {
            let command = try #require(AgentLaunch.command(input: input, shell: shell, agent: agent))
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/script")
            p.arguments = ["-q", "/dev/null", "/bin/bash", "--noprofile", "--norc", "-c", "exec -l \(command)"]
            var env = [
                "PATH": dir.appendingPathComponent("bin").path + ":/usr/bin:/bin",
                "HOME": dir.path,
                "CORRAL_HOOK": dir.appendingPathComponent("bin/corral-hook").path,
            ]
            env.merge(extra) { $1 }
            p.environment = env
            p.currentDirectoryURL = dir
            let out = Pipe()
            let stdin = Pipe()
            p.standardOutput = out
            p.standardError = FileHandle.nullDevice
            p.standardInput = stdin
            lock.withLock { buffer = Data() }
            let eof = DispatchSemaphore(value: 0)
            let reader = out.fileHandleForReading
            Thread.detachNewThread { [self] in
                while case let d = reader.availableData, !d.isEmpty { lock.withLock { buffer.append(d) } }
                eof.signal()
            }
            try p.run()
            var pending = keys[...]
            var seen: Date?
            let deadline = Date().addingTimeInterval(30)
            while p.isRunning, Date() < deadline {
                if let k = pending.first, output.contains(k.after) {
                    if seen == nil { seen = Date() }
                    if let s = seen, Date().timeIntervalSince(s) >= 0.2 {
                        stdin.fileHandleForWriting.write(Data(k.bytes.utf8))
                        pending.removeFirst()
                        seen = nil
                    }
                }
                usleep(10_000)
            }
            if p.isRunning { p.terminate() }
            p.waitUntilExit()
            _ = eof.wait(timeout: .now() + 5)
            try? stdin.fileHandleForWriting.close()
            #expect(pending.isEmpty, "markers never showed: \(pending.map(\.after)) in \(output)")
            let hook = (try? String(contentsOf: hookLog, encoding: .utf8)) ?? ""
            try? FileManager.default.removeItem(at: hookLog)
            return (output, hook)
        }

        func cleanup() { try? FileManager.default.removeItem(at: dir) }
    }

    @Test func handoverRunsAfterTheAgentIsKilledBySIGINT() throws {
        let h = try Harness()
        defer { h.cleanup() }
        // The agent dying from SIGINT makes the interactive zsh drop the rest of its list; the outer
        // shell still reports and starts the follow-up shell.
        let r = try h.run(#"echo AGENT; sh -c 'kill -INT $$'; echo NOT-REACHED"#)
        #expect(r.out.contains("AGENT"))
        #expect(!r.out.contains("NOT-REACHED"))
        #expect(r.hook == #"claude CorralAgentExit {"exit":130}"#)
        #expect(r.out.contains("FOLLOWUP args=-l "))
    }

    @Test func ctrlCKillsTheAgentNotTheHandover() throws {
        let h = try Harness()
        defer { h.cleanup() }
        // A real Ctrl-C on the tty: the caught INT in the outer shell is back to default in the agent.
        let r = try h.run("sh -c 'echo AGENT-UP; sleep 5; echo NOT-REACHED'", keys: [("AGENT-UP", "\u{03}")])
        #expect(!r.out.contains("NOT-REACHED"))
        #expect(r.hook == #"claude CorralAgentExit {"exit":130}"#)
        #expect(r.out.contains("FOLLOWUP args=-l "))
    }

    @Test func ctrlZResumesTheAgentInsteadOfLosingIt() throws {
        let h = try Harness()
        defer { h.cleanup() }
        // Suspended agents are resumed (there is no prompt to `fg` from); the report is the real exit.
        let r = try h.run("sh -c 'echo AGENT-UP; sleep 2; echo AGENT-DONE; exit 4'", keys: [("AGENT-UP", "\u{1A}")])
        #expect(r.out.contains("suspended"))
        let done = try #require(r.out.range(of: "AGENT-DONE"))
        let followup = try #require(r.out.range(of: "FOLLOWUP"))
        #expect(done.upperBound <= followup.lowerBound)
        #expect(r.hook == #"claude CorralAgentExit {"exit":4}"#)
    }

    /// The background attach-or-resume chain: the agent that gets Ctrl-Z is the second attach, inside
    /// a list. It must stay a job of the launch shell (no `{ }` in the chain) and be resumed.
    @Test func ctrlZResumesTheAgentInTheAttachOrResumeChain() throws {
        let h = try Harness()
        defer { h.cleanup() }
        let attached = h.dir.appendingPathComponent("attached").path
        try Harness.script(h.dir.appendingPathComponent("bin/claude").path, """
        #!/bin/sh
        if [ "$1" = "attach" ]; then
          [ -e "\(attached)" ] || { touch "\(attached)"; exit 1; }
          echo AGENT-UP; sleep 2; echo AGENT-DONE; exit 4
        fi
        echo "claude $*"
        """)
        let r = try h.run(SessionRecord.attachOrResume(job: "j1", sessionId: "s1"), keys: [("AGENT-UP", "\u{1A}")])
        #expect(r.out.contains("claude --bg --resume s1"))
        #expect(r.out.contains("suspended"))
        let done = try #require(r.out.range(of: "AGENT-DONE"))
        let followup = try #require(r.out.range(of: "FOLLOWUP"))
        #expect(done.upperBound <= followup.lowerBound)
        #expect(r.hook == #"claude CorralAgentExit {"exit":4}"#)
    }

    @Test func ctrlCWhileRcFilesLoadStillHandsOver() throws {
        let h = try Harness()
        defer { h.cleanup() }
        let r = try h.run("echo AGENT-RAN", keys: [("RC-START", "\u{03}")], env: ["FAKE_RC": "echo RC-START; sleep 5"])
        #expect(!r.out.contains("AGENT-RAN"))
        // The exit code depends on where the interrupt lands; the handover is what matters.
        #expect(r.hook.hasPrefix("claude CorralAgentExit {\"exit\":"))
        #expect(r.out.contains("FOLLOWUP args=-l "))
    }

    @Test func ctrlCDuringTheReportStillHandsOver() throws {
        let h = try Harness()
        defer { h.cleanup() }
        let slow = h.dir.appendingPathComponent("bin/slow-hook").path
        let r = try h.run("true", keys: [("HOOK-UP", "\u{03}")], env: ["CORRAL_HOOK": slow])
        #expect(r.out.contains("FOLLOWUP args=-l "))
    }

    /// gitstatus (p10k) starts its daemon in the rc files and only cleans up after a first prompt,
    /// which this shell never shows: the launch must stop it itself on every way out.
    @Test func stopsPromptlessGitstatusOnEveryExit() throws {
        let h = try Harness()
        defer { h.cleanup() }
        let log = h.dir.appendingPathComponent("gitstatus.log")
        let rc = #"gitstatus_stop_p9k_() { print -r -- "STOP $1" >> "\#(log.path)" }; "#
            + "typeset -g GITSTATUS_DAEMON_PID_POWERLEVEL9K=1 GITSTATUS_DAEMON_PID_MINE=2"
        func stops(_ input: String, keys: [(after: String, bytes: String)] = []) throws -> [String] {
            _ = try h.run(input, keys: keys, env: ["FAKE_RC": rc])
            defer { try? FileManager.default.removeItem(at: log) }
            return ((try? String(contentsOf: log, encoding: .utf8)) ?? "").split(separator: "\n").map(String.init).sorted()
        }
        let both = ["STOP MINE", "STOP POWERLEVEL9K"]
        let normal = try stops("(exit 3)")
        #expect(normal == both)
        #expect(try stops(#"echo AGENT; sh -c 'kill -INT $$'"#) == both)
        #expect(try stops("sh -c 'echo AGENT-UP; sleep 5'", keys: [("AGENT-UP", "\u{03}")]) == both)
        #expect(try stops("sh -c 'echo AGENT-UP; sleep 1; exit 4'", keys: [("AGENT-UP", "\u{1A}")]) == both)
        // Without gitstatus the hook is a no-op.
        let plain = try h.run("true")
        #expect(plain.hook == #"claude CorralAgentExit {"exit":0}"#)
        #expect(plain.out.contains("FOLLOWUP"))
    }

    @Test func reportsTheAgentsExitStatus() throws {
        let h = try Harness()
        defer { h.cleanup() }
        #expect(try h.run("(exit 3)", agent: .opencode).hook == #"opencode CorralAgentExit {"exit":3}"#)
        #expect(try h.run("true", agent: .pi).hook == #"pi CorralAgentExit {"exit":0}"#)
        // Not installed: the shell's 127, and the follow-up shell still starts.
        let missing = try h.run("corral-no-such-agent --resume x")
        #expect(missing.hook == #"claude CorralAgentExit {"exit":127}"#)
        #expect(missing.out.contains("FOLLOWUP"))
    }

    @Test func noReportOutsideCorral() throws {
        let h = try Harness()
        defer { h.cleanup() }
        let r = try h.run("true", env: ["CORRAL_HOOK": ""])
        #expect(r.hook.isEmpty)
        #expect(r.out.contains("FOLLOWUP"))
    }

    @Test func trickyInputsSurviveQuoting() throws {
        let h = try Harness()
        defer { h.cleanup() }
        let r = try h.run(#"printf '%s|%s\n' "it's" 'a && b || c' && echo "$((1+1))" # trailing comment"#)
        #expect(r.out.contains("it's|a && b || c\n2\n"))
        #expect(r.hook == #"claude CorralAgentExit {"exit":0}"#)

        // The attach-or-resume chain: attach fails, background resume, attach again (fails again here).
        let chain = SessionRecord.attachOrResume(job: "job 1", sessionId: "sid'1")
        let c = try h.run(chain)
        #expect(c.out.contains("claude attach job 1\nclaude --bg --resume sid'1\nclaude attach job 1\n"))
        #expect(c.hook == #"claude CorralAgentExit {"exit":1}"#)
        #expect(c.out.contains("FOLLOWUP"))
    }

    @Test func followUpShellGetsTheTerminalsOwnEnvironment() throws {
        let h = try Harness()
        defer { h.cleanup() }
        // Whatever the rc files / integration .zshenv change stays in the agent's shell; Ghostty's
        // ZDOTDIR injection reaches the follow-up shell as for any new terminal.
        let mutate = "unset ZDOTDIR; export GHOSTTY_ZSH_ZDOTDIR=changed RC_VAR=set; true"
        let on = try h.run(mutate, env: ["ZDOTDIR": "/res/shell-integration/zsh", "GHOSTTY_ZSH_ZDOTDIR": "/Users/me/zsh dir"])
        #expect(on.out.contains("ZDOTDIR=/res/shell-integration/zsh GZ=/Users/me/zsh dir RC=unset"))
        // Integration disabled (Ghostty set no ZDOTDIR): nothing is injected.
        let off = try h.run(mutate)
        #expect(off.out.contains("ZDOTDIR=unset GZ=unset RC=unset"))
    }
}
