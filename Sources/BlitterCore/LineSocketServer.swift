import Foundation

/// A local server on a Unix domain socket that answers one line with one line (#58): the
/// automation socket. Only processes of the same user may connect (checked for every client,
/// besides the socket's 0600 mode in a 0700 folder). Each client gets a thread of its own; its
/// lines are answered in order. Nothing here knows what the lines mean.
public final class LineSocketServer: @unchecked Sendable {
    /// Answers one request line, or nil for no answer (a JSON-RPC notification); `client` is
    /// the connecting process, for a confirmation to name.
    public typealias Handler = @Sendable (_ line: String, _ client: Client) async -> String?

    /// Who is connected: its process id and name, as far as the system tells.
    public struct Client: Equatable, Sendable {
        public let pid: pid_t
        public let name: String
    }

    public enum Failure: Error, Equatable {
        /// Another process (a second Blitter) is serving on the socket already.
        case inUse
        /// Something that is not a socket is in the way; it is left alone.
        case notASocket
        /// The folder is not a private folder of this user (another owner, or a link).
        case unsafeFolder
        /// A system call failed with this errno.
        case system(String, Int32)
    }

    public let path: String
    private let handler: Handler
    /// Whether the socket is published and served; its descriptor belongs to the accept thread,
    /// which alone closes it (#79).
    private var listener: Int32 = -1
    /// The write end of the pipe that wakes the accept thread: `stop()` closes it.
    private var wake: Int32 = -1
    /// The lock file held while serving: whoever holds it owns the socket (#58 review).
    private var lockFile: Int32 = -1
    private let lock = NSLock()
    private var clients: Set<Int32> = []
    /// Connections whose thread still runs: `stop()` only shuts them down, their threads close
    /// them. Tests wait for 0 before they start another server in the same process (#66).
    private var serving = 0

    var openConnections: Int {
        lock.withLock { serving }
    }

    private var stopped = false

    /// Tests stop the server here, between binding and publishing the socket.
    var beforePublishing: (() -> Void)?
    /// The longest line a client may send, in bytes; a longer one ends the connection.
    let maximumLine: Int

    public init(path: String, maximumLine: Int = 1 << 20, handler: @escaping Handler) {
        self.path = path
        self.maximumLine = maximumLine
        self.handler = handler
    }

    /// Makes sure the folder is this user's and private (0700), takes the lock file next to the
    /// socket (a second Blitter, even one starting at the same moment, gets `Failure.inUse`),
    /// replaces a socket file left by one that is gone (nothing else: `Failure.notASocket`), and
    /// starts accepting on a new socket (0600). Touches the disk: call it off the main thread.
    /// A `stop()` that comes first, or while it starts, wins: nothing is left serving or held.
    public func start() throws {
        let folder = (path as NSString).deletingLastPathComponent
        try Self.securePrivateFolder(folder)
        let lockFile = open(path + ".lock", O_RDWR | O_CREAT | O_CLOEXEC | O_NOFOLLOW, 0o600)
        guard lockFile >= 0 else {
            throw Failure.system("open lock", errno)
        }
        guard flock(lockFile, LOCK_EX | LOCK_NB) == 0 else {
            close(lockFile)
            throw Failure.inUse
        }
        do {
            let socket = try bindSocket()
            var pipe: [Int32] = [-1, -1]
            // Close-on-exec: a launched tool holding the write end would keep `stop()` from
            // waking the accept thread.
            guard Darwin.pipe(&pipe) == 0, pipe.allSatisfy({ fcntl($0, F_SETFD, FD_CLOEXEC) == 0 }) else {
                let code = errno
                pipe.filter { $0 >= 0 }.forEach { close($0) }
                close(socket)
                unlink(path)
                throw Failure.system("pipe", code)
            }
            beforePublishing?()
            let published = lock.withLock { () -> Bool in
                guard !stopped else {
                    return false // stopped meanwhile (#58 review)
                }
                listener = socket
                wake = pipe[1]
                self.lockFile = lockFile
                return true
            }
            guard published else {
                close(socket)
                pipe.forEach { close($0) }
                unlink(path) // ours: the lock is still held
                close(lockFile)
                return
            }
            Thread.detachNewThread { [self] in acceptLoop(socket, wake: pipe[0]) }
        } catch {
            close(lockFile)
            throw error
        }
    }

    /// With the lock held nobody else serves: a socket file still there is a leftover.
    private func bindSocket() throws -> Int32 {
        // First: a path too long throws before there is a socket to close (#80).
        var address = try Self.address(path)
        var info = stat()
        if lstat(path, &info) == 0 {
            guard info.st_mode & S_IFMT == S_IFSOCK else {
                throw Failure.notASocket
            }
            unlink(path)
        }
        let socket = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard socket >= 0 else {
            throw Failure.system("socket", errno)
        }
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(socket, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        // Non-blocking: a connection that is gone before `accept` takes it must not leave the
        // accept thread waiting where `stop()` cannot wake it.
        guard bound == 0, chmod(path, 0o600) == 0, listen(socket, 8) == 0,
              fcntl(socket, F_SETFL, fcntl(socket, F_GETFL) | O_NONBLOCK) == 0
        else {
            let code = errno
            close(socket)
            throw Failure.system("bind", code)
        }
        return socket
    }

    /// Stops accepting, ends every connection and removes the socket file.
    ///
    /// No descriptor is closed here (#79): the accept thread and each client's thread close their
    /// own. A descriptor closed under a thread still using it gets reused by the next socket the
    /// process opens, and that thread would then accept or end a stranger's connections.
    public func stop() {
        let held = lock.withLock { () -> (wake: Int32, lockFile: Int32) in
            stopped = true
            // Under the lock: a client's thread takes its descriptor out of `clients` before it
            // closes it, so every one here is still open and still that client's.
            for client in clients {
                shutdown(client, SHUT_RDWR) // ends read()
            }
            defer {
                listener = -1
                wake = -1
                lockFile = -1
                clients = []
            }
            return (wake, lockFile) // a wake pipe only while published
        }
        if held.wake >= 0 {
            unlink(path) // still ours: the lock is held until here
            close(held.wake) // the accept thread wakes, closes the socket and goes
        }
        if held.lockFile >= 0 {
            close(held.lockFile) // the next Blitter may take the socket
        }
    }

    /// Accepts until `stop()` closes the pipe's write end; then closes the socket and the pipe.
    private func acceptLoop(_ socket: Int32, wake: Int32) {
        defer {
            close(socket)
            close(wake)
        }
        var fds = [pollfd(fd: socket, events: Int16(POLLIN), revents: 0),
                   pollfd(fd: wake, events: Int16(POLLIN), revents: 0)]
        while true {
            fds[0].revents = 0
            fds[1].revents = 0
            guard poll(&fds, 2, -1) >= 0 else {
                if errno == EINTR {
                    continue
                }
                return
            }
            if fds[1].revents != 0 {
                return // stop()
            }
            let client = accept(socket, nil, nil)
            guard client >= 0 else {
                if [EINTR, EAGAIN, ECONNABORTED].contains(errno) {
                    continue // nothing to take after all
                }
                return
            }
            // The listener is non-blocking; its connections must not be (they inherit it).
            _ = fcntl(client, F_SETFL, fcntl(client, F_GETFL) & ~O_NONBLOCK)
            guard let peer = Self.peer(client), lock.withLock({
                guard !stopped, clients.insert(client).inserted else {
                    return false
                }
                serving += 1
                return true
            }) else {
                close(client) // another user's process, or stopping
                continue
            }
            var enabled: Int32 = 1
            setsockopt(client, SOL_SOCKET, SO_NOSIGPIPE, &enabled, socklen_t(MemoryLayout<Int32>.size))
            Thread.detachNewThread { [self] in serve(client, peer) }
        }
    }

    /// Reads lines and answers each before reading the next; ends when the client goes.
    private func serve(_ client: Int32, _ peer: Client) {
        defer {
            lock.withLock { _ = clients.remove(client) }
            close(client)
            lock.withLock { serving -= 1 }
        }
        var pending = Data()
        var buffer = [UInt8](repeating: 0, count: 64 * 1024)
        while true {
            let count = buffer.withUnsafeMutableBytes { read(client, $0.baseAddress, $0.count) }
            guard count > 0 else {
                return
            }
            pending.append(contentsOf: buffer[0 ..< count])
            while let newline = pending.firstIndex(of: 0x0A) {
                guard newline - pending.startIndex <= maximumLine else {
                    return // too long, even complete
                }
                // swiftlint:disable:next optional_data_string_conversion
                let line = String(decoding: pending[pending.startIndex ..< newline], as: UTF8.self) // lossy is fine
                pending.removeSubrange(pending.startIndex ... newline)
                guard !line.trimmingCharacters(in: .whitespaces).isEmpty else {
                    continue
                }
                switch answer(line, peer, on: client) {
                case let .reply(reply):
                    guard Self.write(reply + "\n", to: client) else {
                        return
                    }
                case .none: // a notification: nothing to send
                    continue
                case .gone: // the client went away, or the server stops
                    return
                }
            }
            guard pending.count <= maximumLine else {
                return
            }
        }
    }

    /// How one request ended.
    private enum Outcome {
        case reply(String)
        case none
        case gone
    }

    /// Runs the async handler and waits for it on this client's thread. A client that goes away
    /// meanwhile (or stopping the server) cancels the handler's task: a confirmation it waits
    /// for then closes.
    private func answer(_ line: String, _ peer: Client, on client: Int32) -> Outcome {
        let done = DispatchSemaphore(value: 0)
        let result = ReplyBox()
        let handler = handler
        let task = Task {
            result.value = await handler(line, peer)
            done.signal()
        }
        while done.wait(timeout: .now() + 0.2) == .timedOut {
            if lock.withLock({ stopped }) || Self.hasHungUp(client) {
                task.cancel()
                done.wait() // the handler ends soon once cancelled; nobody reads its reply
                return .gone
            }
        }
        return result.value.map(Outcome.reply) ?? .none
    }
}

// MARK: Helpers

extension LineSocketServer {
    /// Whether the client is gone: its socket can no longer be written to. A client that only
    /// closed its sending half (`printf … | nc -U`, a script done sending) still waits for the
    /// answer: reading tells the two apart from nothing, kqueue's write filter does.
    private static func hasHungUp(_ client: Int32) -> Bool {
        let queue = kqueue()
        guard queue >= 0 else {
            return false
        }
        defer { close(queue) }
        var change = kevent(ident: UInt(client), filter: Int16(EVFILT_WRITE), flags: UInt16(EV_ADD | EV_ONESHOT),
                            fflags: 0, data: 0, udata: nil)
        var event = kevent()
        var timeout = timespec(tv_sec: 0, tv_nsec: 0)
        return kevent(queue, &change, 1, &event, 1, &timeout) == 1 && event.flags & UInt16(EV_EOF) != 0
    }

    private static func write(_ text: String, to client: Int32) -> Bool {
        var bytes = Array(text.utf8)[...]
        while !bytes.isEmpty {
            let written = bytes.withUnsafeBytes { Darwin.write(client, $0.baseAddress, $0.count) }
            guard written > 0 else {
                return false
            }
            bytes = bytes.dropFirst(written)
        }
        return true
    }

    static func address(_ path: String) throws -> sockaddr_un {
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8)
        guard bytes.count < MemoryLayout.size(ofValue: address.sun_path) else {
            throw Failure.system("path too long", ENAMETOOLONG)
        }
        withUnsafeMutableBytes(of: &address.sun_path) { raw in
            raw.copyBytes(from: bytes)
            raw[bytes.count] = 0
        }
        return address
    }

    /// The connected process, if it runs as the same user as this one.
    private static func peer(_ client: Int32) -> Client? {
        var uid: uid_t = 0
        var gid: gid_t = 0
        guard getpeereid(client, &uid, &gid) == 0, uid == getuid() else {
            return nil
        }
        var pid: pid_t = 0
        var length = socklen_t(MemoryLayout<pid_t>.size)
        getsockopt(client, SOL_LOCAL, LOCAL_PEERPID, &pid, &length)
        var name = [CChar](repeating: 0, count: Int(MAXPATHLEN))
        let path = proc_pidpath(pid, &name, UInt32(name.count)) > 0
            ? (String(cString: name) as NSString).lastPathComponent : "unknown"
        return Client(pid: pid, name: path)
    }
}

extension LineSocketServer {
    /// Creates the folder (0700) or checks the one there: a folder, not a link, this user's; any
    /// access for others is taken away, so nobody else can replace the socket in it.
    static func securePrivateFolder(_ folder: String) throws {
        if mkdir(folder, 0o700) != 0, errno != EEXIST {
            try FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true,
                                                    attributes: [.posixPermissions: 0o700])
        }
        var info = stat()
        guard lstat(folder, &info) == 0, info.st_mode & S_IFMT == S_IFDIR, info.st_uid == getuid() else {
            throw Failure.unsafeFolder
        }
        if info.st_mode & 0o077 != 0, chmod(folder, 0o700) != 0 {
            throw Failure.system("chmod", errno)
        }
    }
}

/// Carries a reply from the handler's task to the waiting client thread.
private final class ReplyBox: @unchecked Sendable {
    var value: String?
}
