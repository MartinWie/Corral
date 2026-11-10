import Foundation

/// Calls `exited` on the main queue once a process has exited (kqueue, no polling). Releasing the
/// watch stops it.
final class ProcessExitWatch {
    private let source: DispatchSourceProcess

    init(pid: pid_t, exited: @escaping () -> Void) {
        source = DispatchSource.makeProcessSource(identifier: pid, eventMask: .exit, queue: .main)
        source.setEventHandler(handler: exited)
        source.resume()
        // Gone before the source existed: kqueue would never report it.
        if kill(pid, 0) != 0, errno == ESRCH { DispatchQueue.main.async(execute: exited) }
    }

    deinit { source.cancel() }
}
