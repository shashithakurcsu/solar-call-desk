import Darwin
import Dispatch
import Foundation

/// Mutable transport state and each connection are confined to queue. The sole actor
/// crossing carries owned Data; no socket reads/writes or readiness waits run on MainActor.
public final class LocalCommandServer: @unchecked Sendable {
    public static var defaultPath: String { "/tmp/solar-call-desk-\(getuid())/control.sock" }
    private let path: String
    private let queue = DispatchQueue(label: "SolarCallDesk.SambhaSocket")
    private let handler: @MainActor @Sendable (Data) -> Data
    private var listener: DispatchSourceRead?
    private var clients: [UUID: Client] = [:]
    private var socketInode: ino_t?
    private final class Client: @unchecked Sendable {
        let id = UUID(), fd: Int32
        var input = Data(), output = Data(), sent = 0
        var read: DispatchSourceRead?, write: DispatchSourceWrite?
        var closed = false, processing = false, sources = 1
        init(_ fd: Int32) { self.fd = fd }
        func sourceEnded() { sources -= 1; if sources == 0 { Darwin.close(fd) } }
    }
    public init(path: String = LocalCommandServer.defaultPath, handler: @escaping @MainActor @Sendable (Data) -> Data) {
        self.path = path; self.handler = handler
    }
    public func start() async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            queue.async { [self] in
                do { try listen(); continuation.resume() } catch { continuation.resume(throwing: error) }
            }
        }
    }
    public func stop() { queue.async { [self] in closeTransport() } }
    /// Only bounded nonblocking transport operations run here; no actor callback is awaited.
    public func stopAndWait() { queue.sync { closeTransport() } }
    private func closeTransport() {
        for client in Array(clients.values) { close(client) }
        let source = listener; listener = nil; source?.cancel()
        unlinkOwnedSocket()
    }
    private func problem(_ message: String) -> NSError { NSError(domain: "SolarCallDesk.LocalIPC", code: 1, userInfo: [NSLocalizedDescriptionKey: message]) }
    private func listen() throws {
        guard listener == nil else { throw problem("Sambha listener already exists.") }
        let directory = (path as NSString).deletingLastPathComponent
        guard path.utf8.count < 104 else { throw problem("Local socket path is too long.") }
        var info = stat()
        if lstat(directory, &info) != 0 {
            guard errno == ENOENT, mkdir(directory, 0o700) == 0, lstat(directory, &info) == 0 else { throw problem("Cannot create the private local-control directory.") }
        }
        guard info.st_mode & S_IFMT == S_IFDIR, info.st_uid == getuid(), info.st_mode & 0o777 == 0o700 else {
            throw problem("Local-control directory must be a real, same-user directory with mode0700.")
        }
        if lstat(path, &info) == 0 {
            // Never remove arbitrary/symlink paths or another owner's endpoint.
            guard info.st_mode & S_IFMT == S_IFSOCK, info.st_uid == getuid(), info.st_mode & 0o777 == 0o600 else { throw problem("Unsafe existing local-control socket.") }
            throw problem("A control socket already exists. Close the other Solar instance; an abandoned socket requires explicit cleanup.")
        }
        guard errno == ENOENT else { throw problem("Cannot inspect the local-control socket.") }
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw problem("Cannot create the local socket.") }
        var keep = false
        defer { if !keep { Darwin.close(fd); unlinkOwnedSocket() } }
        var address = sockaddr_un(); address.sun_family = sa_family_t(AF_UNIX)
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        withUnsafeMutableBytes(of: &address.sun_path) { bytes in
            bytes.initializeMemory(as: UInt8.self, repeating: 0)
            bytes.copyBytes(from: Array(path.utf8) + [0])
        }
        let bound = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        guard bound == 0 else { throw problem("Cannot bind the local socket.") }
        guard lstat(path, &info) == 0 else { throw problem("Cannot inspect the new socket.") }
        socketInode = info.st_ino
        guard chmod(path, 0o600) == 0, fcntl(fd, F_SETFL, O_NONBLOCK) == 0, Darwin.listen(fd, 4) == 0 else { throw problem("Cannot secure or listen on the local socket.") }
        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        source.setEventHandler { [weak self] in self?.acceptClients(fd) }
        source.setCancelHandler { Darwin.close(fd) }
        listener = source; keep = true; source.resume()
    }
    private func acceptClients(_ fd: Int32) {
        for _ in 0..<8 {
            let peer = accept(fd, nil, nil)
            guard peer >= 0 else { return }
            var uid: uid_t = 0, gid: gid_t = 0
            guard clients.count < 4, getpeereid(peer, &uid, &gid) == 0, uid == getuid(), fcntl(peer, F_SETFL, O_NONBLOCK) == 0 else { Darwin.close(peer); continue }
            var noSignal: Int32 = 1
            _ = setsockopt(peer, SOL_SOCKET, SO_NOSIGPIPE, &noSignal, socklen_t(MemoryLayout<Int32>.size))
            let client = Client(peer), source = DispatchSource.makeReadSource(fileDescriptor: peer, queue: queue)
            client.read = source; clients[client.id] = client
            source.setEventHandler { [weak self, weak client] in if let client { self?.read(client) } }
            source.setCancelHandler { [weak self, client] in
                client.sourceEnded(); if client.sources == 0 { self?.clients.removeValue(forKey: client.id) }
            }
            source.resume()
            queue.asyncAfter(deadline: .now() + .seconds(10)) { [weak self, weak client] in if let client { self?.close(client) } }
        }
    }
    private func read(_ client: Client) {
        guard !client.closed, !client.processing else { return }
        var buffer = [UInt8](repeating: 0, count: 4_096)
        for _ in 0..<17 {
            let count = Darwin.read(client.fd, &buffer, buffer.count)
            if count < 0 { if errno != EAGAIN && errno != EWOULDBLOCK { close(client) }; return }
            if count == 0 { close(client); return }
            client.input.append(contentsOf: buffer.prefix(count))
            guard client.input.count <= 65_537 else { close(client); return }
            if let newline = client.input.firstIndex(of: 10) {
                guard newline == client.input.count - 1 else { close(client); return }
                let command = Data(client.input.prefix(upTo: newline)); client.input = Data(); client.processing = true
                let handler = handler
                Task { @MainActor [weak self, client] in
                    let response = handler(command)
                    self?.queue.async { [weak self, client] in self?.reply(response, to: client) }
                }
                return
            }
        }
    }
    private func reply(_ response: Data, to client: Client) {
        guard !client.closed else { return }
        guard response.count <= 2_097_152 else { close(client); return }
        client.output = response; client.output.append(10)
        let source = DispatchSource.makeWriteSource(fileDescriptor: client.fd, queue: queue)
        client.write = source; client.sources += 1
        source.setEventHandler { [weak self, weak client] in if let client { self?.write(client) } }
        source.setCancelHandler { [weak self, client] in
            client.sourceEnded(); if client.sources == 0 { self?.clients.removeValue(forKey: client.id) }
        }
        source.resume()
    }
    private func write(_ client: Client) {
        guard !client.closed else { return }
        let sent = client.output.withUnsafeBytes { raw in Darwin.write(client.fd, raw.baseAddress!.advanced(by: client.sent), raw.count - client.sent) }
        if sent < 0 { if errno != EAGAIN && errno != EWOULDBLOCK { close(client) }; return }
        client.sent += sent
        if client.sent == client.output.count { close(client) }
    }
    private func close(_ client: Client) {
        guard !client.closed else { return }
        client.closed = true
        let read = client.read, write = client.write; client.read = nil; client.write = nil
        read?.cancel(); write?.cancel()
    }
    private func unlinkOwnedSocket() {
        guard let inode = socketInode else { return }
        var info = stat()
        if lstat(path, &info) == 0, info.st_ino == inode, info.st_uid == getuid(), info.st_mode & S_IFMT == S_IFSOCK { unlink(path) }
        socketInode = nil
    }
}
