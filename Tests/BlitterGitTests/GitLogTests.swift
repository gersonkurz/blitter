@testable import BlitterCore
@testable import BlitterGit
@testable import BlitterModel
import Foundation
import Synchronization
import Testing

private final class NoWatcher: FolderWatching {
    func watch(_: Set<String>) {}
}

/// A pretend git: a fixed history, the changes per commit, file contents per revision.
private final class FakeHistory: Sendable {
    let commits: [GitCommit]
    let logRequests = Mutex<[String?]>([])
    let failLog: Bool
    /// The first read of this path waits until it is cancelled (or 3 s); `sawCancel` tells.
    let slowPath = Mutex<String?>(nil)
    let sawCancel = Mutex(false)

    init(_ commits: [GitCommit], failLog: Bool = false) {
        self.commits = commits
        self.failLog = failLog
    }

    var access: GitHistoryAccess {
        GitHistoryAccess(log: { [self] _, path, _ in
            logRequests.withLock { $0.append(path) }
            return failLog ? nil : commits
        }, changes: { _, commit, _ in
            switch commit.hash {
            case "c2": [GitChange(status: "M", path: "src/main.swift"),
                        GitChange(status: "R", path: "new.txt", oldPath: "old.txt")]
            case "c3aaaa": [
                    GitChange(status: "M", path: "src/config.json"),
                    GitChange(status: "M", path: "tests/config.json"),
                    GitChange(status: "M", path: "broken.txt"),
                    GitChange(status: "A", path: "added.txt"),
                    GitChange(status: "D", path: "gone.txt"),
                ]
            default: [GitChange(status: "A", path: "README.md")]
            }
        }, contents: { [self] _, path, revision, cancelled in
            let isSlow = slowPath.withLock { slow in
                guard slow == path else {
                    return false
                }
                slow = nil // only the first read
                return true
            }
            if isSlow {
                for _ in 0 ..< 300 where !cancelled.isSet {
                    Thread.sleep(forTimeInterval: 0.01)
                }
                sawCancel.withLock { $0 = cancelled.isSet }
                return nil
            }
            return path == "broken.txt" ? nil : Data("\(path)@\(revision)".utf8)
        })
    }
}

private final class Launches: Sendable {
    let calls = Mutex<[[String]]>([])
}

/// The Git Log's model (#42).
@MainActor
@Suite(.serialized)
struct GitLogTests {
    private let history = FakeHistory([
        GitCommit(hash: "c3aaaa", parent: "c2", author: "Grace Hopper", date: Date(timeIntervalSince1970: 300),
                  subject: "Fix the Blitter timing"),
        GitCommit(hash: "c2", parent: "c1", author: "Jay Miner", date: Date(timeIntervalSince1970: 200),
                  subject: "Add Agnus"),
        GitCommit(hash: "c1", parent: nil, author: "Rene Deßaux", date: Date(timeIntervalSince1970: 100),
                  subject: "first one"),
    ])

    private func workspace(launches: Launches? = nil) -> Workspace {
        let workspace = Workspace(initialLocation: "/", home: "/", lister: { _ in [] }, directoryCheck: { _ in false },
                                  volumes: { [] }, watcher: { _ in NoWatcher() })
        workspace.gitRepositories["/repo"] = KnownRepository(GitRepoStatus(), checked: Date())
        workspace.findDiffTool = { DiffTool(["tool", "{left}", "{right}"]) }
        workspace.launchTool = { arguments, _ in launches?.calls.withLock { $0.append(arguments) } }
        return workspace
    }

    private func settle(_ log: GitLog) async {
        for _ in 0 ..< 200 where log.isBusy {
            try? await Task.sleep(for: .milliseconds(5))
        }
    }

    @Test func theHistoryOfTheWorkingCopyOrOfAPathInIt() async {
        let log = GitLog(workspace: workspace(), path: "/repo", access: history.access)
        #expect(log.status == .loading)
        await settle(log)
        #expect(log.status == .loaded(truncated: false))
        #expect(log.shown.map(\.hash) == ["c3aaaa", "c2", "c1"])
        #expect(log.relativePath == nil)

        let ofFile = GitLog(workspace: workspace(), path: "/repo/src/main.swift", access: history.access)
        await settle(ofFile)
        #expect(ofFile.relativePath == "src/main.swift")
        #expect(history.logRequests.withLock { $0 } == [nil, "src/main.swift"])
    }

    @Test func theFilterMatchesMessageAuthorOrHash() async {
        let log = GitLog(workspace: workspace(), path: "/repo", access: history.access)
        await settle(log)
        let cases: [(String, [String])] = [
            ("blitter", ["c3aaaa"]), ("jay", ["c2"]), ("DESSAUX", ["c1"]), ("deßaux", ["c1"]),
            ("dessaux", ["c1"]), // ß is ss, case-insensitively
            ("rene", ["c1"]), ("c3a", ["c3aaaa"]), ("C2", ["c2"]), ("  ", ["c3aaaa", "c2", "c1"]), ("zzz", []),
        ]
        for (text, expected) in cases {
            log.perform(.filter(text))
            await settle(log)
            #expect(log.shown.map(\.hash) == expected, "\(text)")
        }
        #expect(log.commits.count == 3) // the filter never drops what was read
    }

    @Test func aSelectedCommitShowsItsChangesAndOneOpensInTheDiffTool() async throws {
        let launches = Launches()
        let workspace = workspace(launches: launches)
        let log = GitLog(workspace: workspace, path: "/repo", access: history.access)
        await settle(log)
        log.perform(.select("c2"))
        #expect(log.changes == nil) // being read
        await settle(log)
        #expect(log.selected?.hash == "c2")
        let changes = try #require(log.changes)
        #expect(changes.map(\.path) == ["src/main.swift", "new.txt"])

        log.perform(.compare(changes[1])) // a rename: before under its old name
        await settle(log)
        for _ in 0 ..< 200 where workspace.compareWork != nil || launches.calls.withLock({ $0 }).isEmpty {
            try await Task.sleep(for: .milliseconds(5))
        }
        let launched = try #require(launches.calls.withLock { $0 }.first)
        #expect(launched.count == 3 && launched[0] == "tool")
        #expect(launched[1].contains("/Blitter-Git/") && launched[1].hasSuffix("/c1/new.txt"))
        #expect(launched[2].hasSuffix("/c2/new.txt"))
        #expect(try String(contentsOfFile: launched[1], encoding: .utf8) == "old.txt@c1")
        #expect(try String(contentsOfFile: launched[2], encoding: .utf8) == "new.txt@c2")

        log.perform(.select(nil))
        #expect(log.selected == nil && log.changes == [])
    }

    private func launched(_ workspace: Workspace, _ launches: Launches, count: Int) async throws -> [[String]] {
        for _ in 0 ..< 300 where workspace.compareWork != nil || launches.calls.withLock({ $0 }).count < count {
            try await Task.sleep(for: .milliseconds(5))
        }
        return launches.calls.withLock { $0 }
    }

    /// #42 review: two files of the same name, compared at once, each in a folder of its own.
    @Test func eachComparisonHasFilesOfItsOwn() async throws {
        let launches = Launches()
        let workspace = workspace(launches: launches)
        let log = GitLog(workspace: workspace, path: "/repo", access: history.access)
        await settle(log)
        log.perform(.select("c3aaaa"))
        await settle(log)
        let changes = try #require(log.changes)
        log.perform(.compare(changes[0])) // src/config.json
        log.perform(.compare(changes[1])) // tests/config.json, while the first is still being written
        await settle(log)
        let calls = try await launched(workspace, launches, count: 2)
        #expect(calls.count == 2)
        let files = calls.flatMap { $0.dropFirst() }
        #expect(Set(files).count == 4) // nothing shared
        let contents = try files.map { try String(contentsOfFile: $0, encoding: .utf8) }
        #expect(Set(contents) == ["src/config.json@c2", "src/config.json@c3aaaa", "tests/config.json@c2",
                                  "tests/config.json@c3aaaa"])
    }

    /// #42 review: a side that should be there but cannot be read is a problem, not an empty
    /// file; a side the commit says is absent is empty.
    @Test func aFailedReadIsAProblemNotAnEmptyFile() async throws {
        let launches = Launches()
        let workspace = workspace(launches: launches)
        let log = GitLog(workspace: workspace, path: "/repo", access: history.access)
        await settle(log)
        log.perform(.select("c3aaaa"))
        await settle(log)
        let changes = try #require(log.changes)
        log.perform(.compare(changes[2])) // broken.txt: modified, but unreadable
        await settle(log)
        #expect(log.problem == "“broken.txt” could not be read at c2.")
        #expect(launches.calls.withLock { $0 }.isEmpty)

        log.perform(.compare(changes[3])) // added: nothing before
        await settle(log)
        log.perform(.compare(changes[4])) // deleted: nothing after
        await settle(log)
        let calls = try await launched(workspace, launches, count: 2)
        #expect(log.problem == nil)
        #expect(try String(contentsOfFile: calls[0][1], encoding: .utf8).isEmpty)
        #expect(try String(contentsOfFile: calls[0][2], encoding: .utf8) == "added.txt@c3aaaa")
        #expect(try String(contentsOfFile: calls[1][1], encoding: .utf8) == "gone.txt@c2")
        #expect(try String(contentsOfFile: calls[1][2], encoding: .utf8).isEmpty)
    }

    /// #42 review: a comparison replaced by a newer one is cancelled down to git.
    @Test func aReplacedComparisonIsCancelledDownToGit() async throws {
        let launches = Launches()
        let workspace = workspace(launches: launches)
        let log = GitLog(workspace: workspace, path: "/repo", access: history.access)
        await settle(log)
        log.perform(.select("c3aaaa"))
        await settle(log)
        let changes = try #require(log.changes)
        history.slowPath.withLock { $0 = "src/config.json" }
        let start = Date()
        log.perform(.compare(changes[0])) // waits in the read
        try await Task.sleep(for: .milliseconds(50))
        log.perform(.compare(changes[0])) // again: the first is cancelled
        await settle(log)
        for _ in 0 ..< 100 where !history.sawCancel.withLock({ $0 }) { // the reader wakes up
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(history.sawCancel.withLock { $0 })
        #expect(Date().timeIntervalSince(start) < 2)
        #expect(try await launched(workspace, launches, count: 1).count == 1)
    }

    @Test func failuresSayWhy() async {
        let outside = GitLog(workspace: workspace(), path: "/elsewhere", access: history.access)
        #expect(outside.status == .failed("“/elsewhere” is not in a git working copy."))
        let broken = GitLog(workspace: workspace(), path: "/repo", access: FakeHistory([], failLog: true).access)
        await settle(broken)
        #expect(broken.status == .failed("The history could not be read."))
    }

    @Test func aLongHistoryIsMarkedAsCutShort() async {
        let many = (0 ..< GitLog.limit).map {
            GitCommit(hash: "h\($0)", parent: nil, author: "A", date: Date(), subject: "s\($0)")
        }
        let log = GitLog(workspace: workspace(), path: "/repo", access: FakeHistory(many).access)
        await settle(log)
        #expect(log.status == .loaded(truncated: true))
        log.perform(.filter("s19999"))
        await settle(log)
        #expect(log.shown.map(\.hash) == ["h19999"])
    }
}
