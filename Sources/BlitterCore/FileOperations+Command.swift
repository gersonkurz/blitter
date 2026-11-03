import Foundation

/// Running a tool's command line as a job (#30): never through a shell, cancellable, and a
/// failure reported with what the command wrote to stderr.
extension FileOperations {
    /// Where a command name without a slash is looked for. An app started from the Dock gets only
    /// `/usr/bin:/bin:/usr/sbin:/sbin`; Homebrew's folders and the user's own come first.
    static func searchPath(home: String = NSHomeDirectory()) -> [String] {
        ["/opt/homebrew/bin", "/usr/local/bin", home + "/.local/bin", "/usr/bin", "/bin", "/usr/sbin", "/sbin"]
    }

    /// A name with "/" is a path: absolute, or relative to `folder` (where the command runs).
    /// Anything else is looked for on `folders`.
    static func executable(_ name: String, in folder: String = "/", searching folders: [String] = searchPath())
        -> String?
    {
        if name.contains("/") {
            let path = name.hasPrefix("/") ? name
                : ((folder as NSString).appendingPathComponent(name) as NSString).standardizingPath
            return FileManager.default.isExecutableFile(atPath: path) ? path : nil
        }
        return folders.lazy.map { $0 + "/" + name }.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    /// How much of stderr is kept: the end, where the reason for a failure usually is.
    static let errorTailLimit = 4096

    /// The kept end of stderr as text. Cutting it may have split a UTF-8 character at its start:
    /// those leftover bytes are dropped. Anything else that is not UTF-8 shows as "�" — never
    /// the whole message lost.
    static func text(of tail: Data) -> String {
        let start = tail.firstIndex { $0 & 0xC0 != 0x80 } ?? tail.endIndex
        let whole = tail[start...]
        // swiftlint:disable:next optional_data_string_conversion
        return String(bytes: whole, encoding: .utf8) ?? String(decoding: whole, as: UTF8.self)
    }

    /// Runs `arguments` (the program, then its arguments) in `folder`. Returns nil when it exits
    /// with 0 or is cancelled, else what went wrong.
    ///
    /// The program gets a process group of its own, so Cancel reaches whatever it started: TERM
    /// to the group, and after 2 s (or at once if the program is gone) KILL to the group. stderr
    /// is read as it comes, keeping only its end; once the program exits, the job is done, even
    /// if something it left running still holds stderr open.
    static func runCommand(_ arguments: [String], in folder: String, cancelled: CancellationFlag,
                           output: @escaping (Data) -> Void = { _ in }) -> String?
    {
        guard let name = arguments.first else {
            return "The command is empty."
        }
        let path = searchPath()
        guard let program = executable(name, in: folder, searching: path) else {
            return "“\(name)” was not found (" + (name.contains("/") ? "in \(folder))."
                : "looked in \(path.joined(separator: ", ")).")
        }
        var environment = ProcessInfo.processInfo.environment
        environment["PATH"] = path.joined(separator: ":")
        // No terminal to ask in: git fails at once instead of waiting for a password (#43).
        environment["GIT_TERMINAL_PROMPT"] = "0"
        // A script run as a tool reaches this Blitter (#28), whatever its own environment says.
        environment["BLITTER_SOCKET"] = UserPaths.automationSocket
        let child: SpawnedProcess
        do {
            child = try SpawnedProcess(program, arguments: [name] + arguments.dropFirst(), folder: folder,
                                       environment: environment)
        } catch {
            return "“\(name)” could not be started: \(error.localizedDescription)"
        }
        child.onOutput = output
        guard let status = child.wait(cancelled: cancelled) else {
            return nil // cancelled: the job says so itself
        }
        if status.exitCode == 0 {
            return nil
        }
        let text = Self.text(of: child.errorTail).trimmingCharacters(in: .whitespacesAndNewlines)
        let tail = text.count > 300 ? "…" + text.suffix(300) : text
        let how = status.exitCode.map { "ended with exit code \($0)" } ?? "was stopped by signal \(status.signal)"
        return "“\(name)” \(how)" + (tail.isEmpty ? "." : ": " + tail)
    }
}

/// Starting a program that goes on by itself, such as a diff tool's window (#40): not a job,
/// nothing waits for it. A thread of its own collects its exit, so it leaves no zombie, without
/// using any CPU meanwhile. Its exit code means nothing here: diff tools report differences
/// with it.
public enum Launcher {
    public enum Failure: Error, LocalizedError, Equatable {
        case empty
        case notFound(String)

        public var errorDescription: String? {
            switch self {
            case .empty: "the command is empty"
            case let .notFound(name): "“\(name)” was not found"
            }
        }
    }

    /// `arguments`: the program, then its arguments; never through a shell. `environment` is
    /// added to Blitter's own (with the search path as PATH).
    public static func launch(_ arguments: [String], environment extra: [String: String] = [:]) throws {
        guard let name = arguments.first else {
            throw Failure.empty
        }
        let path = FileOperations.searchPath()
        guard let program = FileOperations.executable(name, in: "/", searching: path) else {
            throw Failure.notFound(name)
        }
        var environment = ProcessInfo.processInfo.environment
        environment["PATH"] = path.joined(separator: ":")
        environment.merge(extra) { $1 }
        let child = try SpawnedProcess(program, arguments: [name] + arguments.dropFirst(), folder: "/",
                                       environment: environment, keepErrors: false)
        Thread.detachNewThread { child.reap() }
    }
}

/// A process started with `posix_spawn` in a group of its own, stdin on /dev/null, stdout and
/// stderr together on a pipe (or both on /dev/null), every other descriptor closed. Used by one
/// thread at a time.
private final class SpawnedProcess: @unchecked Sendable {
    struct Status {
        /// Nil if it was ended by a signal.
        let exitCode: Int32?
        let signal: Int32
    }

    private let pid: pid_t
    private let errorsRead: Int32
    private(set) var errorTail = Data()
    /// Each piece of output as it is read (stdout and stderr together, #43).
    var onOutput: ((Data) -> Void)?

    init(_ program: String, arguments: [String], folder: String, environment: [String: String],
         keepErrors: Bool = true) throws
    {
        var fds: [Int32] = [-1, -1]
        guard pipe(&fds) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        defer { close(fds[1]) } // the child has its own copy
        _ = fcntl(fds[0], F_SETFL, fcntl(fds[0], F_GETFL) | O_NONBLOCK)
        // Neither end may leak into another process Blitter starts meanwhile; the child gets
        // its stderr from the dup2 below, which clears the flag on descriptor 2.
        _ = fcntl(fds[0], F_SETFD, FD_CLOEXEC)
        _ = fcntl(fds[1], F_SETFD, FD_CLOEXEC)

        var actions: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&actions)
        defer { posix_spawn_file_actions_destroy(&actions) }
        posix_spawn_file_actions_addopen(&actions, 0, "/dev/null", O_RDONLY, 0)
        if keepErrors {
            posix_spawn_file_actions_adddup2(&actions, fds[1], 1)
            posix_spawn_file_actions_adddup2(&actions, fds[1], 2)
        } else {
            posix_spawn_file_actions_addopen(&actions, 1, "/dev/null", O_WRONLY, 0)
            posix_spawn_file_actions_addopen(&actions, 2, "/dev/null", O_WRONLY, 0)
        }
        if #available(macOS 26, *) {
            posix_spawn_file_actions_addchdir(&actions, folder)
        } else {
            posix_spawn_file_actions_addchdir_np(&actions, folder)
        }
        var attributes: posix_spawnattr_t?
        posix_spawnattr_init(&attributes)
        defer { posix_spawnattr_destroy(&attributes) }
        // Default signal handling and no blocked signals, whatever Blitter inherited: an ignored
        // or blocked TERM would otherwise be passed on, and Cancel would always wait out the grace.
        posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_SETPGROUP | POSIX_SPAWN_CLOEXEC_DEFAULT
                | POSIX_SPAWN_SETSIGDEF | POSIX_SPAWN_SETSIGMASK))
        posix_spawnattr_setpgroup(&attributes, 0)
        var allSignals = sigset_t()
        sigfillset(&allSignals)
        posix_spawnattr_setsigdefault(&attributes, &allSignals)
        var noSignals = sigset_t()
        sigemptyset(&noSignals)
        posix_spawnattr_setsigmask(&attributes, &noSignals)

        let argv = arguments.map { strdup($0) } + [nil]
        let envp = environment.map { strdup("\($0.key)=\($0.value)") } + [nil]
        defer {
            argv.forEach { free($0) }
            envp.forEach { free($0) }
        }
        var pid: pid_t = 0
        let result = posix_spawn(&pid, program, &actions, &attributes, argv, envp)
        guard result == 0 else {
            close(fds[0])
            throw POSIXError(POSIXErrorCode(rawValue: result) ?? .EIO)
        }
        self.pid = pid
        errorsRead = fds[0]
    }

    deinit {
        close(errorsRead)
    }

    /// Blocks until the program exits and collects it (a launched program, stderr discarded).
    func reap() {
        var status: Int32 = 0
        while waitpid(pid, &status, 0) == -1, errno == EINTR {}
    }

    /// Waits for the program, reading stderr as it comes. Nil if it was cancelled.
    func wait(cancelled: CancellationFlag) -> Status? {
        var status: Int32 = 0
        while true {
            drainErrors()
            let result = waitpid(pid, &status, WNOHANG)
            if result == pid || (result == -1 && errno != EINTR) {
                break
            }
            if cancelled.isSet {
                stopGroup()
                return nil
            }
            usleep(50000)
        }
        drainErrors() // what it wrote last; whatever it left running may keep stderr open
        let signal = status & 0x7F
        return Status(exitCode: signal == 0 ? (status >> 8) & 0xFF : nil, signal: signal)
    }

    /// TERM to the whole group; KILL to the whole group after 2 s, or once the program is gone
    /// (something it started may ignore TERM).
    private func stopGroup() {
        kill(-pid, SIGTERM)
        var status: Int32 = 0
        for _ in 0 ..< 40 where waitpid(pid, &status, WNOHANG) == 0 {
            usleep(50000)
        }
        kill(-pid, SIGKILL)
        _ = waitpid(pid, &status, 0) // reaped (an error if it already was)
    }

    private func drainErrors() {
        var buffer = [UInt8](repeating: 0, count: 4096)
        while true {
            let count = read(errorsRead, &buffer, buffer.count)
            guard count > 0 else {
                return
            }
            errorTail.append(contentsOf: buffer[0 ..< count])
            onOutput?(Data(buffer[0 ..< count]))
            if errorTail.count > FileOperations.errorTailLimit {
                errorTail = errorTail.suffix(FileOperations.errorTailLimit)
            }
        }
    }
}
