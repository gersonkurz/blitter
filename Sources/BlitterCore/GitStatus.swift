import Foundation

/// The state of a git working copy (#22), from `git status --porcelain=v2 --branch`.
public struct GitRepoStatus: Equatable, Sendable {
    /// Commits the branch is ahead of and behind its upstream (0 without one).
    public var ahead = 0
    public var behind = 0
    /// Tracked files that changed: modified, staged, renamed (both names), unmerged. Relative
    /// to the repository root.
    public var changed: [String] = []
    /// Untracked items; a folder with nothing tracked in it is one entry ending in "/".
    public var untracked: [String] = []
    /// Ignored items, the same way.
    public var ignored: [String] = []
    /// Every folder (relative, "" for the root) with something tracked in it, submodules
    /// included: from the index, since a folder holding only ignored or no files at all is
    /// listed neither as untracked nor as ignored (#35).
    public var trackedFolders: Set<String> = []

    public init(ahead: Int = 0, behind: Int = 0, changed: [String] = [], untracked: [String] = [],
                ignored: [String] = [], trackedFolders: Set<String> = [])
    {
        self.ahead = ahead
        self.behind = behind
        self.changed = changed
        self.untracked = untracked
        self.ignored = ignored
        self.trackedFolders = trackedFolders
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

    /// Runs `git status` and `git ls-files` in the working copy; nil if git is missing, fails,
    /// takes longer than `timeout` in all or is cancelled (git is stopped then). Takes no locks
    /// (`GIT_OPTIONAL_LOCKS=0`), so it never gets in the way of git commands the user runs.
    public static func status(of root: String, git: String? = executable, timeout: TimeInterval = 10,
                              cancelled: CancellationFlag = CancellationFlag()) -> GitRepoStatus?
    {
        guard let git else {
            return nil
        }
        let deadline = Date().addingTimeInterval(timeout)
        let statusArguments = ["status", "--porcelain=v2", "--branch", "-z", "--untracked-files=normal",
                               "--ignored=matching"]
        guard let statusOutput = run(git, statusArguments, in: root, until: deadline, cancelled: cancelled),
              let index = run(git, ["ls-files", "-z", "--stage"], in: root, until: deadline, cancelled: cancelled)
        else {
            return nil
        }
        var status = parse(statusOutput)
        status.trackedFolders = trackedFolders(fromIndex: index)
        return status
    }

    /// Runs git and returns its output; nil if it fails, passes `deadline` or is cancelled.
    private static func run(_ git: String, _ arguments: [String], in root: String, until deadline: Date,
                            cancelled: CancellationFlag) -> Data?
    {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: git, isDirectory: false)
        process.arguments = ["-C", root] + arguments
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
        // Read on another thread while it runs: a large output would otherwise fill the pipe and
        // block git, and a git that hangs must not block this thread past the deadline.
        let reader = OutputReader()
        let read = DispatchSemaphore(value: 0)
        let handle = output.fileHandleForReading
        DispatchQueue.global(qos: .utility).async {
            reader.data = handle.readDataToEndOfFile()
            read.signal()
        }
        while finished.wait(timeout: .now() + 0.05) == .timedOut {
            guard !cancelled.isSet, Date() < deadline else {
                process.terminate() // closes its end of the pipe, so the reader finishes too
                return nil
            }
        }
        // Something git started may still hold the pipe: never wait past the deadline for it.
        guard read.wait(timeout: .now() + max(0, deadline.timeIntervalSinceNow)) == .success,
              process.terminationStatus == 0
        else {
            return nil
        }
        return reader.data
    }

    /// The folders with something tracked in them, from `git ls-files -z --stage` ("mode hash
    /// stage<TAB>path"): every file's folders, and a submodule (mode 160000) itself.
    static func trackedFolders(fromIndex data: Data) -> Set<String> {
        var folders: Set = [""]
        for record in data.split(separator: 0, omittingEmptySubsequences: true) {
            guard let line = String(bytes: record, encoding: .utf8), let tab = line.firstIndex(of: "\t") else {
                continue
            }
            var folder = String(line[line.index(after: tab)...])
            if line.hasPrefix("160000 ") {
                folders.insert(folder) // a submodule: tracked, and a folder
            }
            while let slash = folder.lastIndex(of: "/") {
                folder = String(folder[..<slash])
                guard folders.insert(folder).inserted else {
                    break // its ancestors are in already
                }
            }
        }
        return folders
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
            // Ordinary (1), renamed or copied (2), unmerged (u), untracked (?), ignored (!); the
            // path is the last field. A rename is followed by a record with the original path.
            let fieldsBeforePath = switch record.first {
            case "1": 8
            case "2": 9
            case "u": 10
            case "?", "!": 1
            default: -1
            }
            guard fieldsBeforePath >= 0 else {
                continue
            }
            let fields = record.split(separator: " ", maxSplits: fieldsBeforePath, omittingEmptySubsequences: false)
            // A submodule whose only change is untracked files in it (".M" with "S..U": no new
            // commit, no tracked modification) is not a tracked change.
            if record.first == "1", fields.count > 2, fields[1] == ".M", fields[2].hasPrefix("S"),
               fields[2].dropFirst().prefix(2) == ".."
            {
                continue
            }
            if fields.count == fieldsBeforePath + 1 {
                let path = String(fields[fieldsBeforePath])
                switch record.first {
                case "?": status.untracked.append(path)
                case "!": status.ignored.append(path)
                default: status.changed.append(path)
                }
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
