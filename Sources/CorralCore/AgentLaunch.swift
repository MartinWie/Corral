import Foundation

/// How a new terminal starts its agent.
///
/// With zsh as login shell the terminal's command runs the agent directly: nothing is typed or
/// echoed and the terminal opens straight into the agent. The user's rc files still load (aliases,
/// PATH), and the terminal hands over to a normal login shell with Ghostty shell integration when
/// the agent exits. Other shells keep the typed fallback (the command is typed into the shell's
/// first prompt).
public enum AgentLaunch {
    /// Hook event the launch script sends through corral-hook when the agent exits.
    public static let exitEvent = "CorralAgentExit"

    /// What the agent launch is doing, for the launch cover and the sidebar subtitle.
    public enum Kind: Equatable, Sendable {
        case starting, resuming, attaching

        public func title(agent: AgentKind) -> String {
            switch self {
            case .starting: return "Starting \(agent.displayName)"
            case .resuming: return "Resuming \(agent.displayName)"
            case .attaching: return "Attaching to background agent"
            }
        }

        public var rowSubtitle: String {
            switch self {
            case .starting: return "Starting…"
            case .resuming: return "Resuming…"
            case .attaching: return "Attaching…"
            }
        }

        /// The row's state for VoiceOver ("Starting", without the ellipsis).
        public var accessibilityState: String {
            switch self {
            case .starting: return "Starting"
            case .resuming: return "Resuming"
            case .attaching: return "Attaching"
            }
        }
    }

    /// Direct launch needs zsh (the scripts below are zsh; Ghostty's zsh integration reaches the
    /// follow-up shell through the untouched environment).
    public static func supportsDirect(shell: String) -> Bool {
        let leaf = shell.pathLeaf
        return leaf == "zsh"
    }

    /// The terminal command for a direct launch, or nil when `shell` needs the typed fallback.
    ///
    /// Ghostty runs it as `bash --noprofile --norc -c "exec -l <command>"`, so the outer script is
    /// passed as one POSIX single-quoted word. Ghostty detects zsh from arg0 and injects its
    /// integration through ZDOTDIR; `-f` keeps the outer zsh from consuming it.
    public static func command(input: String, shell: String, agent: AgentKind) -> String? {
        guard supportsDirect(shell: shell) else { return nil }
        return "\(shellQuote(shell)) -fc \(shellQuote(outerScript(input: input, shell: shell, agent: agent)))"
    }

    /// The outer, non-interactive zsh (no rc files, Ghostty's environment untouched): runs the agent in
    /// an interactive login zsh, reports how that ended, then `exec`s the follow-up login shell.
    ///
    /// - Being outside the interactive shell, the handover survives whatever kills or aborts it:
    ///   Ctrl-C while the rc files load, Ctrl-C killing the agent (an interactive `zsh -c` drops the
    ///   rest of its command list then), a crash.
    /// - INT/QUIT/TSTP are caught (not ignored, so the inner shell and the agent get the defaults
    ///   back on exec): a key landing in the few milliseconds the outer shell owns the terminal
    ///   must not kill or stop it.
    /// - The follow-up shell inherits the terminal's original environment, so Ghostty's ZDOTDIR
    ///   injection (or the user's choice to disable it) reaches it as for any new terminal.
    /// - corral-hook is a no-op outside Corral; `CORRAL_HOOK` is only set inside it.
    public static func outerScript(input: String, shell: String, agent: AgentKind) -> String {
        let sh = shellQuote(shell)
        return """
        trap : INT QUIT TSTP
        \(sh) -lic \(shellQuote(innerScript(input: input)))
        __corral_rc=$?
        [[ -n $CORRAL_HOOK ]] && printf '{"exit":%d}' $__corral_rc | "$CORRAL_HOOK" \(shellQuote(agent.rawValue)) \(exitEvent) 2>/dev/null
        exec \(sh) -l
        """
    }

    /// The interactive login zsh that runs the agent (rc files loaded, job control on, so the agent
    /// owns the terminal's foreground process group).
    ///
    /// - The agent input sits on its own lines at top level, so a trailing comment or `&&`/`||`
    ///   chain stays intact. It must not be wrapped in `{ }`/a function: a job suspended there is
    ///   forked off out of reach of `jobs`/`fg`.
    /// - Ctrl-Z suspends the agent like at a prompt; with no prompt to `fg` from, stopped jobs are
    ///   resumed right away, and the exit status is the resumed job's. Inputs must stay brace-free
    ///   (see `SessionRecord.attachOrResume`); an agent wrapped in a shell function by the user's rc
    ///   files can't be resumed (zsh drops it from the job table), an alias can.
    /// - gitstatus (powerlevel10k) starts its daemon while the rc files load and only finishes the
    ///   handshake, and registers its own cleanup, at the first prompt. This shell never prompts, so
    ///   without the exit hook every launch would leave a zsh blocked forever on gitstatus' FIFO.
    ///   The hook stops each started instance through gitstatus' own `gitstatus_stop*` (it kills
    ///   the daemon's process group and removes its files). It runs on every exit of this shell
    ///   except a Ctrl-C while the rc files are still loading (the hook isn't registered yet).
    public static func innerScript(input: String) -> String {
        """
        \(reapGitstatus)
        zshexit_functions+=(__corral_reap)
        \(input)
        __corral_rc=$?
        while (( ${#${(M)jobstates:#suspended:*}} )); do fg %${${(k)jobstates[(R)suspended:*]}[1]}; __corral_rc=$?; done
        exit $__corral_rc
        """
    }

    /// Exit hook of the inner shell (see `innerScript`). p10k loads gitstatus with a function suffix
    /// (`gitstatus_stop_p9k_`), so the stop function is looked up by prefix. Subshells run zshexit
    /// hooks too (`(exit 3)` in the agent input) and must leave the daemon alone.
    static let reapGitstatus = #"__corral_reap() { (( ZSH_SUBSHELL )) && return 0; local stop=${${(k)functions[(I)gitstatus_stop*]}[1]} v; [[ -n $stop ]] || return 0; for v in ${(k)parameters[(I)GITSTATUS_DAEMON_PID_*]}; do $stop ${v#GITSTATUS_DAEMON_PID_} 2>/dev/null; done; return 0 }"#

    /// Launch kind for a session that starts `input`.
    public static func kind(resuming: Bool, backgroundJob: Bool) -> Kind {
        backgroundJob ? .attaching : (resuming ? .resuming : .starting)
    }
}
