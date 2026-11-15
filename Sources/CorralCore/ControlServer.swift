import Foundation

/// Unix socket the `corral` command talks to: one JSON line in, one JSON line back. Unlike the hook
/// socket a reply may come much later (`corral wait`), so every client keeps its own connection.
public final class ControlServer {
    /// One client. `reply` answers and closes; `onClose` runs (main queue) when the client leaves
    /// before it was answered.
    public final class Connection {
        fileprivate let fd: Int32
        fileprivate var source: DispatchSourceRead?
        fileprivate var buffer = Data()
        fileprivate var requested = false
        fileprivate var finished = false
        fileprivate let queue: DispatchQueue
        public var onClose: (() -> Void)?

        fileprivate init(fd: Int32, queue: DispatchQueue) {
            self.fd = fd
            self.queue = queue
        }

        public func reply(_ object: [String: Any]) {
            queue.async { [self] in
                guard !finished else { return }
                if var data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]) {
                    data.append(0x0A)
                    // Blocking (bounded by SO_SNDTIMEO): an answer can be larger than the socket buffer.
                    _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) & ~O_NONBLOCK)
                    UnixSocket.write(data, to: fd)
                }
                finish(closed: false)
            }
        }

        /// One more line for a client that keeps listening (`corral events`). A client that stopped
        /// reading is dropped (its `onClose` runs).
        public func push(_ object: [String: Any]) {
            queue.async { [self] in
                guard !finished, var data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]) else { return }
                data.append(0x0A)
                _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) & ~O_NONBLOCK)
                let sent = UnixSocket.write(data, to: fd)
                _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)
                if !sent { finish(closed: true) }
            }
        }

        /// On `queue`. The source's cancel handler closes the fd and lets go of the connection.
        fileprivate func finish(closed: Bool) {
            guard !finished else { return }
            finished = true
            source?.cancel()
            source = nil
            guard closed else { return }
            DispatchQueue.main.async { [self] in
                onClose?()
                onClose = nil
            }
        }
    }

    public static let maxRequest = 1 << 20
    static let requestDeadline: TimeInterval = 10

    public let path: String
    private var fd: Int32 = -1
    private var source: DispatchSourceRead?
    private let queue = DispatchQueue(label: "corral.control")
    private let handler: ([String: Any], Connection) -> Void

    /// `handler` runs on the main queue and must end in `reply` (now or later).
    public init(path: String = CorralPaths.control.path, handler: @escaping ([String: Any], Connection) -> Void) {
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
        guard var addr = UnixSocket.address(path) else {
            close(fd); fd = -1
            throw POSIXError(.ENAMETOOLONG)
        }
        let rc = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        guard rc == 0, chmod(path, 0o600) == 0, listen(fd, 64) == 0 else {
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
        if let source { source.cancel() } else if fd >= 0 { close(fd) }
        source = nil
        fd = -1
        unlink(path)
    }

    private func acceptPending() {
        while true {
            let client = accept(fd, nil, nil)
            if client < 0 { return }
            // Only this user's processes (the socket is 0600 as well).
            var uid: uid_t = 0, gid: gid_t = 0
            guard getpeereid(client, &uid, &gid) == 0, uid == getuid() else { close(client); continue }
            var one: Int32 = 1
            setsockopt(client, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
            var tv = timeval(tv_sec: 2, tv_usec: 0)
            setsockopt(client, SOL_SOCKET, SO_SNDTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
            _ = fcntl(client, F_SETFL, fcntl(client, F_GETFL) | O_NONBLOCK)
            serve(Connection(fd: client, queue: queue))
        }
    }

    private func serve(_ c: Connection) {
        let src = DispatchSource.makeReadSource(fileDescriptor: c.fd, queue: queue)
        let fd = c.fd
        // The handler keeps the connection alive until it is cancelled.
        src.setEventHandler { [handler] in
            var buf = [UInt8](repeating: 0, count: 16 * 1024)
            let n = read(fd, &buf, buf.count)
            if n < 0, errno == EAGAIN || errno == EINTR { return }
            // End of file: the client is gone (Ctrl-C on `corral wait`, a timeout on its side).
            guard n > 0 else { c.finish(closed: c.requested); return }
            guard !c.requested else { return }
            c.buffer.append(buf, count: n)
            guard let end = c.buffer.firstIndex(of: 0x0A) else {
                if c.buffer.count > Self.maxRequest { c.finish(closed: false) }
                return
            }
            let line = c.buffer[c.buffer.startIndex..<end]
            c.buffer = Data()
            c.requested = true
            guard let request = try? JSONSerialization.jsonObject(with: line) as? [String: Any] else {
                c.finish(closed: false)
                return
            }
            DispatchQueue.main.async { handler(request, c) }
        }
        src.setCancelHandler { close(fd) }
        c.source = src
        src.resume()
        // A client that connects and never asks doesn't keep its connection.
        queue.asyncAfter(deadline: .now() + Self.requestDeadline) { if !c.requested { c.finish(closed: false) } }
    }
}

enum UnixSocket {
    static func address(_ path: String) -> sockaddr_un? {
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8)
        guard bytes.count < MemoryLayout.size(ofValue: addr.sun_path) else { return nil }
        withUnsafeMutableBytes(of: &addr.sun_path) { buf in
            buf.copyBytes(from: bytes)
            buf[bytes.count] = 0
        }
        return addr
    }

    /// All of `data`, false when the other side stops taking it.
    @discardableResult
    static func write(_ data: Data, to fd: Int32) -> Bool {
        data.withUnsafeBytes { raw in
            var off = 0
            while off < raw.count {
                let n = Darwin.write(fd, raw.baseAddress! + off, raw.count - off)
                if n <= 0 { return false }
                off += n
            }
            return true
        }
    }
}

/// The `corral` command's side: sends one request and waits for the answer.
public enum ControlClient {
    public enum Failure: Error, Equatable { case notRunning, noAnswer }

    /// `timeout` nil waits for as long as the app takes (`corral wait`).
    public static func request(_ object: [String: Any], path: String = CorralPaths.control.path,
                               timeout: TimeInterval? = 10) -> Result<[String: Any], Failure> {
        var answer: [String: Any]?
        if let failure = stream(object, path: path, timeout: timeout, each: { answer = $0; return false }) { return .failure(failure) }
        return answer.map { .success($0) } ?? .failure(.noAnswer)
    }

    /// Sends the request and hands every line that comes back to `each` until it returns false or the
    /// app closes the connection (`corral events`). Nil when it ended in order.
    public static func stream(_ object: [String: Any], path: String = CorralPaths.control.path, timeout: TimeInterval? = nil,
                              each: ([String: Any]) -> Bool) -> Failure? {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return .notRunning }
        defer { close(fd) }
        var one: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
        guard var addr = UnixSocket.address(path) else { return .notRunning }
        let rc = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        guard rc == 0 else { return .notRunning }
        guard var data = try? JSONSerialization.data(withJSONObject: object) else { return .noAnswer }
        data.append(0x0A)
        guard UnixSocket.write(data, to: fd) else { return .noAnswer }
        if let timeout {
            var tv = timeval(tv_sec: Int(timeout), tv_usec: 0)
            setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        }
        var pending = Data()
        var buf = [UInt8](repeating: 0, count: 16 * 1024)
        var lines = 0
        while true {
            while let end = pending.firstIndex(of: 0x0A) {
                let line = pending[pending.startIndex..<end]
                pending = Data(pending[pending.index(after: end)...])
                guard let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any] else { return .noAnswer }
                lines += 1
                if !each(object) { return nil }
            }
            let n = read(fd, &buf, buf.count)
            if n < 0, errno == EINTR { continue }
            if n <= 0 { return lines == 0 ? .noAnswer : nil }
            pending.append(buf, count: n)
        }
    }
}
