import Darwin
import Foundation

/// Executable path and argv of a process, used to tell which agent runs in a terminal.
public enum ProcessInspector {
    public static func executablePath(pid: pid_t) -> String? {
        var buf = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
        let n = proc_pidpath(pid, &buf, UInt32(buf.count))
        guard n > 0 else { return nil }
        return String(cString: buf)
    }

    public static func arguments(pid: pid_t) -> [String] {
        var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
        var size = 0
        guard sysctl(&mib, 3, nil, &size, nil, 0) == 0, size > 0 else { return [] }
        var buf = [UInt8](repeating: 0, count: size)
        guard sysctl(&mib, 3, &buf, &size, nil, 0) == 0, size > MemoryLayout<Int32>.size else { return [] }
        let argc = buf.withUnsafeBytes { $0.load(as: Int32.self) }
        var i = MemoryLayout<Int32>.size
        // Skip the executable path and the NUL padding after it.
        while i < size, buf[i] != 0 { i += 1 }
        while i < size, buf[i] == 0 { i += 1 }
        var args: [String] = []
        while args.count < argc, i < size {
            let start = i
            while i < size, buf[i] != 0 { i += 1 }
            args.append(String(decoding: buf[start..<i], as: UTF8.self))
            i += 1
        }
        return args
    }

    /// Direct children of `pid`.
    public static func children(of pid: pid_t) -> [pid_t] {
        guard pid > 0 else { return [] }
        var buf = [pid_t](repeating: 0, count: 256)
        let bytes = proc_listpids(UInt32(PROC_PPID_ONLY), UInt32(pid), &buf, Int32(buf.count * MemoryLayout<pid_t>.size))
        guard bytes > 0 else { return [] }
        return buf.prefix(Int(bytes) / MemoryLayout<pid_t>.size).filter { $0 > 0 }
    }

    /// Commands Claude Code still runs in the background under the agent process `pid`: its Bash tool's
    /// shells, started from Claude's shell snapshot. Foreground tool calls end before the turn does, so
    /// any left when a turn ends run in the background (and Claude goes on once they finish).
    public static func claudeBackgroundShells(agent pid: pid_t) -> [pid_t] {
        children(of: pid).filter { child in arguments(pid: child).contains { $0.contains("/shell-snapshots/snapshot-") } }
    }

    public static func agent(pid: pid_t) -> AgentKind? {
        guard pid > 0, let path = executablePath(pid: pid) else { return nil }
        return AgentDetector.detect(path: path, args: arguments(pid: pid))
    }
}
