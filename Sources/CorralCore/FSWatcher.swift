import CoreServices
import Foundation

/// FSEvents watcher: calls `handler` (main queue) with changed paths, coalesced by `latency`.
public final class FSWatcher {
    private var stream: FSEventStreamRef?
    private let handler: ([String]) -> Void

    public init(paths: [String], latency: TimeInterval = 2.0, handler: @escaping ([String]) -> Void) {
        self.handler = handler
        let existing = paths.filter { FileManager.default.fileExists(atPath: $0) }
        guard !existing.isEmpty else { return }

        var context = FSEventStreamContext(
            version: 0, info: Unmanaged.passUnretained(self).toOpaque(),
            retain: nil, release: nil, copyDescription: nil)
        let callback: FSEventStreamCallback = { _, info, count, paths, _, _ in
            guard let info else { return }
            let watcher = Unmanaged<FSWatcher>.fromOpaque(info).takeUnretainedValue()
            let cfPaths = unsafeBitCast(paths, to: NSArray.self)
            let list = (0..<count).compactMap { cfPaths[$0] as? String }
            watcher.handler(list)
        }
        let flags = UInt32(kFSEventStreamCreateFlagUseCFTypes | kFSEventStreamCreateFlagFileEvents
                           | kFSEventStreamCreateFlagNoDefer)
        stream = FSEventStreamCreate(nil, callback, &context, existing as CFArray,
                                     FSEventStreamEventId(kFSEventStreamEventIdSinceNow), latency, flags)
        if let stream {
            FSEventStreamSetDispatchQueue(stream, .main)
            FSEventStreamStart(stream)
        }
    }

    deinit {
        if let stream {
            FSEventStreamStop(stream)
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
        }
    }
}
