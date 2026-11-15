@testable import BlitterCore
@testable import BlitterGit
@testable import BlitterModel
import Foundation
import Synchronization
import Testing

private final class IdleWatcher: FolderWatching {
    func watch(_: Set<String>) {}
}

/// #89: the selected commit's message, and a whole commit in the diff tool.
@MainActor
@Suite(.serialized)
struct GitLogCommitTests {
    private final class Recorder: Sendable {
        let launches = Mutex<[[String]]>([])
        let reads = Mutex<[String]>([])
        let messageRequests = Mutex<[String]>([])
        /// How many reads of a commit's files fail before they work.
        let changesFailures = Mutex(0)
        /// While set, reading a file waits (until cancelled, or 3 s).
        let holdReads = Mutex(false)
        /// The changes of every commit but c1, instead of the usual ones.
        let changes = Mutex<[GitChange]?>(nil)
    }

    private let commits = [
        GitCommit(hash: "c3cccccccccccc", parent: "c2bbbbbbbbbbbb", author: "Grace Hopper", date: .distantPast,
                  subject: "Rework the copper"),
        GitCommit(hash: "c2bbbbbbbbbbbb", parent: "c1", author: "Jay Miner", date: .distantPast, subject: "Agnus"),
        GitCommit(hash: "c1", parent: nil, author: "Jay Miner", date: .distantPast, subject: "first"),
    ]

    private func access(_ recorder: Recorder, unreadable: String? = nil) -> GitHistoryAccess {
        GitHistoryAccess(log: { [commits] _, _, _ in commits }, changes: { _, commit, _ in
            let fails = recorder.changesFailures.withLock { count in
                defer { count = max(count - 1, 0) }
                return count > 0
            }
            if fails {
                return nil
            }
            if commit.hash != "c1", let changes = recorder.changes.withLock({ $0 }) {
                return changes
            }
            return switch commit.hash {
            case "c1": [GitChange(status: "A", path: "README.md")]
            default: [
                    GitChange(status: "M", path: "src/copper/list.s"),
                    GitChange(status: "R", path: "docs/new.md", oldPath: "old.md"),
                    GitChange(status: "A", path: "added.txt"),
                    GitChange(status: "D", path: "gone/deleted.txt"),
                ]
            }
        }, contents: { _, path, revision, cancelled in
            for _ in 0 ..< 300 where recorder.holdReads.withLock({ $0 }) && !cancelled.isSet {
                Thread.sleep(forTimeInterval: 0.01)
            }
            if cancelled.isSet {
                return nil
            }
            recorder.reads.withLock { $0.append("\(path)@\(revision)") }
            return path == unreadable ? nil : Data("\(path)@\(revision)".utf8)
        }, message: { _, hash, _ in
            recorder.messageRequests.withLock { $0.append(hash) }
            return hash == "c1" ? "first" : "Rework the copper\n\nThe list is built once per frame."
        })
    }

    private func workspace(_ recorder: Recorder) -> Workspace {
        let workspace = Workspace(initialLocation: "/", home: "/", lister: { _ in [] }, directoryCheck: { _ in false },
                                  volumes: { [] }, watcher: { _ in IdleWatcher() })
        workspace.gitRepositories["/repo"] = KnownRepository(GitRepoStatus(), checked: Date())
        workspace.findDiffTool = { DiffTool(["tool", "{left}", "{right}"]) }
        workspace.launchTool = { arguments, _ in recorder.launches.withLock { $0.append(arguments) } }
        return workspace
    }

    private func settle(_ log: GitLog) async {
        for _ in 0 ..< 400 where log.isBusy {
            try? await Task.sleep(for: .milliseconds(5))
        }
    }

    private func launched(_ workspace: Workspace, _ recorder: Recorder) async throws -> [String] {
        for _ in 0 ..< 400 where workspace.compareWork != nil || recorder.launches.withLock({ $0 }).isEmpty {
            try await Task.sleep(for: .milliseconds(5))
        }
        return try #require(recorder.launches.withLock { $0 }.first)
    }

    /// Every file below `folder`, by its path there, with its contents.
    private func files(_ folder: String) throws -> [String: String] {
        let paths = FileManager.default.enumerator(atPath: folder)?.allObjects as? [String] ?? []
        var result: [String: String] = [:]
        for path in paths {
            var isFolder: ObjCBool = false
            if FileManager.default.fileExists(atPath: folder + "/" + path, isDirectory: &isFolder),
               !isFolder.boolValue
            {
                result[path] = try String(contentsOfFile: folder + "/" + path, encoding: .utf8)
            }
        }
        return result
    }

    @Test func theSelectedCommitsMessageIsReadWithItsFiles() async {
        let recorder = Recorder()
        let log = GitLog(workspace: workspace(recorder), path: "/repo", access: access(recorder))
        await settle(log)
        #expect(recorder.messageRequests.withLock { $0 }.isEmpty) // not for the whole history
        log.perform(.select("c3cccccccccccc"))
        #expect(log.message == nil) // being read
        await settle(log)
        #expect(log.message == "Rework the copper\n\nThe list is built once per frame.")
        log.perform(.select("c1"))
        #expect(log.message == nil) // never the previous commit's
        await settle(log)
        #expect(log.message == "first")
        log.perform(.select(nil))
        #expect(log.message == nil)
        #expect(recorder.messageRequests.withLock { $0 } == ["c3cccccccccccc", "c1"])
    }

    /// Before and after as two folders: each changed file at its path, a renamed one under its
    /// old name before, an added one only after, a deleted one only before.
    @Test func aWholeCommitIsTwoFoldersInTheDiffTool() async throws {
        let recorder = Recorder()
        let workspace = workspace(recorder)
        let log = GitLog(workspace: workspace, path: "/repo", access: access(recorder))
        await settle(log)
        log.perform(.select("c3cccccccccccc"))
        await settle(log)
        log.perform(.compareCommit)
        #expect(log.isPreparingComparison)
        await settle(log)
        #expect(!log.isPreparingComparison && log.problem == nil)
        let call = try await launched(workspace, recorder)
        #expect(call.count == 3 && call[0] == "tool")
        #expect(call[1].contains("/Blitter-Git/") && call[1].hasSuffix("/c2bbbbbbbb"))
        #expect(call[2].hasSuffix("/c3cccccccc"))
        #expect(try files(call[1]) == [
            "src/copper/list.s": "src/copper/list.s@c2bbbbbbbbbbbb",
            "old.md": "old.md@c2bbbbbbbbbbbb",
            "gone/deleted.txt": "gone/deleted.txt@c2bbbbbbbbbbbb",
        ])
        #expect(try files(call[2]) == [
            "src/copper/list.s": "src/copper/list.s@c3cccccccccccc",
            "docs/new.md": "docs/new.md@c3cccccccccccc",
            "added.txt": "added.txt@c3cccccccccccc",
        ])
    }

    /// A first commit has nothing before it: an empty folder, so the diff tool shows every file
    /// as new. Its files may not have been read yet: the comparison reads them itself.
    @Test func aFirstCommitIsComparedWithAnEmptyFolder() async throws {
        let recorder = Recorder()
        let workspace = workspace(recorder)
        let log = GitLog(workspace: workspace, path: "/repo", access: access(recorder))
        await settle(log)
        log.perform(.select("c1"))
        log.perform(.compareCommit) // at once, while its files are still being read
        await settle(log)
        let call = try await launched(workspace, recorder)
        #expect(call[1].hasSuffix("/none") && call[2].hasSuffix("/c1"))
        #expect(try files(call[1]).isEmpty)
        #expect(FileManager.default.fileExists(atPath: call[1]))
        #expect(try files(call[2]) == ["README.md": "README.md@c1"])
    }

    /// A side that should be there but cannot be read is a problem; nothing is shown.
    @Test func anUnreadableFileIsAProblem() async throws {
        let recorder = Recorder()
        let workspace = workspace(recorder)
        let log = GitLog(workspace: workspace, path: "/repo", access: access(recorder, unreadable: "old.md"))
        await settle(log)
        log.perform(.select("c3cccccccccccc"))
        await settle(log)
        log.perform(.compareCommit)
        await settle(log)
        #expect(log.problem == "“old.md” could not be read at c2bbbbbbbb.")
        #expect(!log.isPreparingComparison)
        try await Task.sleep(for: .milliseconds(50))
        #expect(recorder.launches.withLock { $0 }.isEmpty)
    }

    /// #89 review: files that could not be read are no empty commit. The comparison reads them
    /// again; if that fails too, it is a problem and nothing is shown.
    @Test func filesThatCouldNotBeReadAreReadAgainNeverShownAsNone() async throws {
        let recorder = Recorder()
        let workspace = workspace(recorder)
        let log = GitLog(workspace: workspace, path: "/repo", access: access(recorder))
        await settle(log)
        recorder.changesFailures.withLock { $0 = 2 } // the selection's read, and the comparison's
        log.perform(.select("c3cccccccccccc"))
        await settle(log)
        #expect(log.changes == [])
        log.perform(.compareCommit)
        await settle(log)
        #expect(log.problem == "The commit's files could not be read.")
        try await Task.sleep(for: .milliseconds(50))
        #expect(recorder.launches.withLock { $0 }.isEmpty)

        log.perform(.select("c1"))
        await settle(log)
        recorder.changesFailures.withLock { $0 = 1 } // only the selection's read fails
        log.perform(.select("c3cccccccccccc"))
        await settle(log)
        #expect(log.changes == [])
        log.perform(.compareCommit)
        await settle(log)
        let call = try await launched(workspace, recorder)
        #expect(try files(call[2]).count == 3) // read again: the commit's files, not none
    }

    /// #89 review: while the commit is prepared, asking again starts nothing; selecting another
    /// commit ends it, and nothing is shown for it.
    @Test func preparingShowsAtOnceAndAnotherSelectionEndsIt() async throws {
        let recorder = Recorder()
        let workspace = workspace(recorder)
        let log = GitLog(workspace: workspace, path: "/repo", access: access(recorder))
        await settle(log)
        log.perform(.select("c3cccccccccccc"))
        await settle(log)
        var changes = 0
        log.onChange = { changes += 1 }
        recorder.holdReads.withLock { $0 = true }
        log.perform(.compareCommit)
        #expect(log.isPreparingComparison && changes == 1) // told at once, not when done
        log.perform(.compareCommit)
        #expect(changes == 1) // nothing started again
        log.perform(.select("c1"))
        #expect(!log.isPreparingComparison)
        recorder.holdReads.withLock { $0 = false }
        await settle(log)
        try await Task.sleep(for: .milliseconds(100))
        #expect(recorder.launches.withLock { $0 }.isEmpty)
        #expect(log.problem == nil)
    }

    /// On the volume the copies go to, Foo.txt and foo.txt in one commit: a problem, no launch.
    /// And a copy is never written over another (on a case-insensitive volume, the second fails).
    @Test func aCaseClashIsAProblemOnTheRealVolume() async throws {
        let recorder = Recorder()
        recorder.changes.withLock {
            $0 = [GitChange(status: "M", path: "Foo.txt"), GitChange(status: "M", path: "foo.txt")]
        }
        let workspace = workspace(recorder)
        let log = GitLog(workspace: workspace, path: "/repo", access: access(recorder))
        await settle(log)
        log.perform(.select("c3cccccccccccc"))
        await settle(log)
        log.perform(.compareCommit)
        await settle(log)
        #expect(log.problem?.contains("would be the same file") == true)
        try await Task.sleep(for: .milliseconds(50))
        #expect(recorder.launches.withLock { $0 }.isEmpty)

        let folder = CompareCopies.newFolder()
        defer { try? FileManager.default.removeItem(atPath: folder) }
        guard case .success = CompareCopies.write(Data("1".utf8), at: "Foo.txt", in: folder) else {
            Issue.record("the first copy was not written")
            return
        }
        let caseSensitive = try URL(fileURLWithPath: folder)
            .resourceValues(forKeys: [.volumeSupportsCaseSensitiveNamesKey])
            .volumeSupportsCaseSensitiveNames == true
        let second = CompareCopies.write(Data("2".utf8), at: "foo.txt", in: folder)
        if case .success = second {
            #expect(caseSensitive)
        } else {
            #expect(!caseSensitive)
            #expect(try String(contentsOfFile: folder + "/Foo.txt", encoding: .utf8) == "1") // not overwritten
        }
        guard case .failure = CompareCopies.write(Data("3".utf8), at: "Foo.txt", in: folder) else {
            Issue.record("a copy was written over another")
            return
        }
    }
}
