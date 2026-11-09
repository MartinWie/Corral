import Foundation

/// Unix domain socket that receives newline-delimited JSON from agent hooks.
/// Event-driven via DispatchSource; each client writes one or more lines and closes.
public final class EventServer {
    public let path: String
    private var fd: Int32 = -1
    private var source: DispatchSourceRead?
    /// Serial: hook events must reach the reducer in the order they were sent (PostToolUse → Stop).
    private let queue = DispatchQueue(label: "corral.events")
    private let handler: (HookWire.Message) -> Void

    /// `handler` runs on the main queue.
    public init(path: String = CorralPaths.socket.path, handler: @escaping (HookWire.Message) -> Void) {
        self.path = path
        self.handler = handler
    }

    deinit { stop() }

    public func start() throws {
        try FileManager.default.createDirectory(
            atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        unlink(path)

        fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw POSIXError(.init(rawValue: errno) ?? .EIO) }
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8)
        guard bytes.count < MemoryLayout.size(ofValue: addr.sun_path) else {
            close(fd); fd = -1
            throw POSIXError(.ENAMETOOLONG)
        }
        withUnsafeMutableBytes(of: &addr.sun_path) { buf in
            buf.copyBytes(from: bytes)
            buf[bytes.count] = 0
        }
        let len = socklen_t(MemoryLayout<sockaddr_un>.size)
        let rc = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, len) }
        }
        guard rc == 0 else {
            let err = errno
            close(fd); fd = -1
            throw POSIXError(.init(rawValue: err) ?? .EIO)
        }
        chmod(path, 0o600)
        guard listen(fd, 64) == 0 else {
            let err = errno
            close(fd); fd = -1
            throw POSIXError(.init(rawValue: err) ?? .EIO)
        }
        _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)

        let src = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        let listenFD = fd
        src.setEventHandler { [weak self] in self?.acceptPending() }
        src.setCancelHandler { close(listenFD) }
        src.resume()
        source = src
    }

    public func stop() {
        if let source {
            source.cancel()  // closes the fd in its cancel handler
        } else if fd >= 0 {
            close(fd)
        }
        source = nil
        fd = -1
        unlink(path)
    }

    private func acceptPending() {
        while true {
            let client = accept(fd, nil, nil)
            if client < 0 { return }
            serve(client)
        }
    }

    private func serve(_ client: Int32) {
        defer { close(client) }
        // Blocking read with a timeout so a stuck client can't pin a thread.
        _ = fcntl(client, F_SETFL, fcntl(client, F_GETFL) & ~O_NONBLOCK)
        var tv = timeval(tv_sec: 2, tv_usec: 0)
        setsockopt(client, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        var data = Data()
        var buf = [UInt8](repeating: 0, count: 16 * 1024)
        while data.count < 4 * 1024 * 1024 {
            let n = read(client, &buf, buf.count)
            if n <= 0 { break }
            data.append(buf, count: n)
        }
        let messages = data.split(separator: 0x0A).compactMap { HookWire.decode(line: Data($0)) }
        guard !messages.isEmpty else { return }
        DispatchQueue.main.async { [handler] in messages.forEach(handler) }
    }
}

/// Swift client for the socket (tests and tooling; the hook itself is C). Never throws.
public enum EventClient {
    @discardableResult
    public static func send(_ data: Data, to path: String) -> Bool {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return false }
        defer { close(fd) }
        var tv = timeval(tv_sec: 1, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        var noSigPipe: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &noSigPipe, socklen_t(MemoryLayout<Int32>.size))
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8)
        guard bytes.count < MemoryLayout.size(ofValue: addr.sun_path) else { return false }
        withUnsafeMutableBytes(of: &addr.sun_path) { buf in
            buf.copyBytes(from: bytes)
            buf[bytes.count] = 0
        }
        let rc = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard rc == 0 else { return false }
        return data.withUnsafeBytes { raw in
            var off = 0
            while off < raw.count {
                let n = write(fd, raw.baseAddress! + off, raw.count - off)
                if n <= 0 { return false }
                off += n
            }
            return true
        }
    }
}
