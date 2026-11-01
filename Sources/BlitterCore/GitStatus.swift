import Foundation

/// The state of a git working copy (#22), from `git status --porcelain=v2 --branch`.
public struct GitRepoStatus: Equatable, Sendable {
    /// Commits the branch is ahead of and behind its upstream (0 without one).
    public var ahead = 0
    public var behind = 0
    /// Changed, staged, unmerged and untracked files, relative to the repository root. Untracked
    /// files are listed one by one, also inside untracked folders, so every folder that contains
    /// changes is known; empty and ignored folders are not listed.
    public var changed: [String] = []

    public init(ahead: Int = 0, behind: Int = 0, changed: [String] = []) {
        self.ahead = ahead
        self.behind = behind
        self.changed = changed
    }
}

/// Reading git working copies. Everything here touches the disk or runs git: call it off the
/// main thread.
public enum Git {
    /// A real git, never `/usr/bin/git`: without the developer tools that one only asks the user
    /// to install them. Nil if there is none — then folders simply get no git colors.
    public static let executable: String? = [
        "/opt/homebrew/bin/git",
        "/usr/local/bin/git",
        "/Library/Developer/CommandLineTools/usr/bin/git",
        "/Applications/Xcode.app/Contents/Developer/usr/bin/git",
    ].first { FileManager.default.isExecutableFile(atPath: $0) }

    /// A working copy's top folder has `.git` (a folder, or a file for worktrees and submodules).
    public static func isRepositoryRoot(_ path: String) -> Bool {
        var info = stat()
        return lstat(path + "/.git", &info) == 0
    }

    /// The working copy `path` is in, if any: the nearest folder at or above it with `.git`.
    /// Only on local volumes; a network volume is never searched or read.
    public static func repositoryRoot(containing path: String) -> String? {
        guard isLocal(path) else {
            return nil
        }
        var current = path
        while true {
            if isRepositoryRoot(current) {
                return current
            }
            guard current != "/", let parent = parent(of: current) else {
                return nil
            }
            current = parent
        }
    }

    public static func isLocal(_ path: String) -> Bool {
        var info = statfs()
        return statfs(path, &info) == 0 && info.f_flags & UInt32(MNT_LOCAL) != 0
    }

    /// Runs `git status` in the working copy; nil if git is missing, fails, takes longer than
    /// `timeout` or is cancelled (git is stopped then). Takes no locks (`GIT_OPTIONAL_LOCKS=0`), so
    /// it never gets in the way of git commands the user runs at the same time.
    public static func status(of root: String, git: String? = executable, timeout: TimeInterval = 10,
                              cancelled: CancellationFlag = CancellationFlag()) -> GitRepoStatus?
    {
        guard let git else {
            return nil
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: git, isDirectory: false)
        process.arguments = ["-C", root, "status", "--porcelain=v2", "--branch", "-z", "--untracked-files=all"]
        var environment = ProcessInfo.processInfo.environment
        environment["GIT_OPTIONAL_LOCKS"] = "0"
        process.environment = environment
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice
        let finished = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in finished.signal() }
        do {
            try process.run()
        } catch {
            return nil
        }
        // Read on another thread while it runs: a large status would otherwise fill the pipe and
        // block git, and a git that hangs must not block this thread past the timeout.
        let reader = OutputReader()
        let read = DispatchSemaphore(value: 0)
        let handle = output.fileHandleForReading
        DispatchQueue.global(qos: .utility).async {
            reader.data = handle.readDataToEndOfFile()
            read.signal()
        }
        let deadline = Date().addingTimeInterval(timeout)
        while finished.wait(timeout: .now() + 0.05) == .timedOut {
            guard !cancelled.isSet, Date() < deadline else {
                process.terminate() // closes its end of the pipe, so the reader finishes too
                return nil
            }
        }
        read.wait()
        guard process.terminationStatus == 0 else {
            return nil
        }
        return parse(reader.data)
    }

    /// Hands git's output from the reading thread over; the semaphore orders the access.
    private final class OutputReader: @unchecked Sendable {
        var data = Data()
    }

    /// Parses `git status --porcelain=v2 --branch -z`.
    static func parse(_ data: Data) -> GitRepoStatus {
        var status = GitRepoStatus()
        let records = data.split(separator: 0, omittingEmptySubsequences: true)
            .map { String(bytes: $0, encoding: .utf8) ?? "" } // not UTF-8: skipped, the pairing kept
        var index = 0
        while index < records.count {
            let record = records[index]
            index += 1
            if record.hasPrefix("# branch.ab ") {
                let parts = record.split(separator: " ")
                if parts.count == 4 {
                    status.ahead = Int(parts[2].dropFirst()) ?? 0
                    status.behind = Int(parts[3].dropFirst()) ?? 0
                }
                continue
            }
            // Ordinary (1), renamed or copied (2), unmerged (u), untracked (?); the path is the
            // last field. A rename is followed by a record with the original path.
            let fieldsBeforePath = switch record.first {
            case "1": 8
            case "2": 9
            case "u": 10
            case "?": 1
            default: -1
            }
            guard fieldsBeforePath >= 0 else {
                continue
            }
            let fields = record.split(separator: " ", maxSplits: fieldsBeforePath, omittingEmptySubsequences: false)
            if fields.count == fieldsBeforePath + 1 {
                status.changed.append(String(fields[fieldsBeforePath]))
            }
            if record.first == "2", index < records.count {
                status.changed.append(records[index]) // the original path: it changed too
                index += 1
            }
        }
        return status
    }

    private static func parent(of path: String) -> String? {
        guard let slash = path.lastIndex(of: "/") else {
            return nil
        }
        return slash == path.startIndex ? "/" : String(path[..<slash])
    }
}
