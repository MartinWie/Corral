import Foundation

/// Variables from the user's login shell that an app opened from Finder doesn't get (launchd hands it a
/// minimal PATH and none of the rc files' exports): PATH (to find `claude` and the `node` an npm shim
/// runs), CLAUDE_CONFIG_DIR and XDG_*. Read through `$SHELL -lic`, cached for the next launch, and used
/// only where Corral looks things up itself. Never exported: terminals start login shells of their own.
public enum ShellEnvironment {
    public static let keys = ["PATH", "CLAUDE_CONFIG_DIR", "XDG_CONFIG_HOME", "XDG_DATA_HOME", "XDG_STATE_HOME", "XDG_CACHE_HOME"]

    private static let lock = NSLock()
    private static var values: [String: String] = [:]

    /// What the login shell reported (set once at launch by `ManagerEnvironment.app()`).
    public static var shell: [String: String] {
        get { lock.lock(); defer { lock.unlock() }; return values }
        set { lock.lock(); values = newValue; lock.unlock() }
    }

    /// The value Corral uses for `key`: its own environment's, else the shell's. PATH is the shell's
    /// (an app's own PATH is launchd's /usr/bin:/bin:/usr/sbin:/sbin).
    public static func value(_ key: String, process: [String: String] = ProcessInfo.processInfo.environment,
                             shell: [String: String] = ShellEnvironment.shell) -> String? {
        if key == "PATH" { return nonEmpty(shell["PATH"]) ?? nonEmpty(process["PATH"]) }
        return nonEmpty(process[key]) ?? nonEmpty(shell[key])
    }

    /// Environment for a CLI Corral runs (`claude agents`): its own, with the shell's PATH and variables,
    /// and `first` (the CLI's own folder: `node` usually sits next to an npm shim) leading PATH.
    public static func childEnvironment(first: String? = nil, process: [String: String] = ProcessInfo.processInfo.environment,
                                        shell: [String: String] = ShellEnvironment.shell) -> [String: String] {
        var env = process
        for key in keys { if let v = value(key, process: process, shell: shell) { env[key] = v } }
        if let first, !first.isEmpty {
            env["PATH"] = ([first] + (env["PATH"] ?? "").split(separator: ":").map(String.init).filter { $0 != first })
                .joined(separator: ":")
        }
        return env
    }

    /// The values for this launch: the cache, refreshed in the background for the next one. Without a
    /// cache (first launch) a probe, waited for at most `wait`; a slower shell still finishes in the
    /// background and fills the cache for next time (empty when it failed: later launches then never
    /// wait, and the background refresh keeps trying).
    public static func resolve(shell path: String, cache: URL, wait: TimeInterval = 3, cap: TimeInterval = 10,
                               environment: [String: String] = ProcessInfo.processInfo.environment) -> [String: String] {
        if let cached = load(cache) {
            DispatchQueue.global(qos: .utility).async {
                if let fresh = probe(shell: path, timeout: cap, environment: environment), fresh != cached { save(fresh, to: cache) }
            }
            return cached
        }
        let done = DispatchSemaphore(value: 0)
        let box = Box()
        DispatchQueue.global(qos: .userInitiated).async {
            let fresh = probe(shell: path, timeout: cap, environment: environment)
            save(fresh ?? [:], to: cache)
            box.set(fresh)
            done.signal()
        }
        guard done.wait(timeout: .now() + wait) == .success else { return [:] }
        return box.get() ?? [:]
    }

    private final class Box {
        private let lock = NSLock()
        private var value: [String: String]?
        func set(_ v: [String: String]?) { lock.lock(); value = v; lock.unlock() }
        func get() -> [String: String]? { lock.lock(); defer { lock.unlock() }; return value }
    }

    /// Runs `shell` as an interactive login shell and returns `keys` from its environment, or nil
    /// (unknown shell, error, or slower than `timeout`). In a session of its own (no controlling
    /// terminal: an interactive zsh started from a terminal would stop on SIGTTOU), with none of
    /// Corral's open files and a clean signal mask (daemons an rc file starts live on), stdio on
    /// /dev/null, output to a file (a daemon would hold a pipe open); its process group is killed once
    /// it is done or out of time.
    public static func probe(shell: String, timeout: TimeInterval,
                             environment: [String: String] = ProcessInfo.processInfo.environment) -> [String: String]? {
        let name = URL(fileURLWithPath: shell).lastPathComponent
        let out = FileManager.default.temporaryDirectory.appendingPathComponent("corral-shell-env-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: out) }
        // The path as a literal: an rc file may reset the positional parameters.
        let quoted = "'" + out.path.replacingOccurrences(of: "'", with: #"'\''"#) + "'"
        let script: String
        switch name {
        case "zsh", "bash", "sh", "ksh", "dash": script = "/usr/bin/env -0 >| \(quoted)"
        case "fish": script = "/usr/bin/env -0 > \(quoted)"
        default: return nil
        }
        var env = environment
        env["TERM"] = "dumb"
        guard let pid = spawn(shell, ["-l", "-i", "-c", script], env) else { return nil }
        guard let status = wait(pid, timeout: timeout), status == 0, let data = try? Data(contentsOf: out) else { return nil }
        return parse(data)
    }

    // <spawn.h> flags Swift doesn't import.
    private static let setsid: Int16 = 0x0400, cloexecDefault: Int16 = 0x4000, setSigDefault: Int16 = 0x0004,
                       setSigMask: Int16 = 0x0008

    /// posix_spawn in a new session, every inherited descriptor closed but stdio (on /dev/null), all
    /// signals unblocked and at their defaults (a GCD worker thread blocks most of them).
    private static func spawn(_ path: String, _ args: [String], _ env: [String: String]) -> pid_t? {
        var attr: posix_spawnattr_t?
        posix_spawnattr_init(&attr)
        defer { posix_spawnattr_destroy(&attr) }
        posix_spawnattr_setflags(&attr, setsid | cloexecDefault | setSigDefault | setSigMask)
        var none = sigset_t()
        sigemptyset(&none)
        posix_spawnattr_setsigmask(&attr, &none)
        var all = sigset_t()
        sigfillset(&all)
        posix_spawnattr_setsigdefault(&attr, &all)
        var files: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&files)
        defer { posix_spawn_file_actions_destroy(&files) }
        posix_spawn_file_actions_addopen(&files, 0, "/dev/null", O_RDONLY, 0)
        posix_spawn_file_actions_addopen(&files, 1, "/dev/null", O_WRONLY, 0)
        posix_spawn_file_actions_addopen(&files, 2, "/dev/null", O_WRONLY, 0)
        let argv = ([path] + args).map { strdup($0) } + [nil]
        let envp = env.map { strdup("\($0.key)=\($0.value)") } + [nil]
        defer { (argv + envp).forEach { free($0) } }
        var pid: pid_t = 0
        guard posix_spawn(&pid, path, &files, &attr, argv, envp) == 0 else { return nil }
        return pid
    }

    /// The exit status, or nil when out of time (or killed by a signal). The shell leads its own process
    /// group: whatever its rc files left running in it goes too, while the exited shell isn't reaped
    /// yet (so its group id can't belong to anyone else).
    private static func wait(_ pid: pid_t, timeout: TimeInterval) -> Int32? {
        let deadline = ProcessInfo.processInfo.systemUptime + timeout
        var exited = false
        while !exited {
            var info = siginfo_t()
            let r = waitid(P_PID, id_t(pid), &info, WEXITED | WNOHANG | WNOWAIT)
            if r == 0, info.si_pid == pid {
                exited = true
            } else if (r == -1 && errno != EINTR) || ProcessInfo.processInfo.systemUptime >= deadline {
                break
            } else {
                usleep(10_000)
            }
        }
        kill(-pid, SIGKILL)
        var status: Int32 = 0
        while waitpid(pid, &status, 0) == -1, errno == EINTR {}
        // WIFEXITED / WEXITSTATUS.
        return exited && status & 0x7F == 0 ? (status >> 8) & 0xFF : nil
    }

    /// `env -0` output: NUL-separated `KEY=value`, only `keys` kept.
    public static func parse(_ data: Data) -> [String: String] {
        var out: [String: String] = [:]
        for entry in data.split(separator: 0) {
            guard let s = String(data: Data(entry), encoding: .utf8), let eq = s.firstIndex(of: "=") else { continue }
            let key = String(s[..<eq])
            if keys.contains(key) { out[key] = String(s[s.index(after: eq)...]) }
        }
        return out
    }

    static func load(_ url: URL) -> [String: String]? {
        guard let data = try? Data(contentsOf: url),
              let values = try? JSONDecoder().decode([String: String].self, from: data) else { return nil }
        return values
    }

    static func save(_ values: [String: String], to url: URL) {
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? JSONEncoder().encode(values).write(to: url, options: .atomic)
    }

    private static func nonEmpty(_ s: String?) -> String? {
        guard let s, !s.isEmpty else { return nil }
        return s
    }
}
