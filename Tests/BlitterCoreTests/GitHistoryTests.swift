@testable import BlitterCore
import Foundation
import Testing

/// A working copy's history (#42), from a real git in a temporary working copy.
struct GitHistoryTests {
    /// `date`: the commit's time (seconds since 1970), so the order never depends on how fast
    /// the commits were made.
    private func git(_ arguments: [String], in folder: String, date: Int? = nil) throws {
        let git = try #require(Git.executable, "no git on this Mac")
        let process = Process()
        if let date {
            var environment = ProcessInfo.processInfo.environment
            environment["GIT_AUTHOR_DATE"] = "@\(date) +0000"
            environment["GIT_COMMITTER_DATE"] = "@\(date) +0000"
            process.environment = environment
        }
        process.executableURL = URL(fileURLWithPath: git)
        process.arguments = ["-C", folder, "-c", "user.name=Ada Tester", "-c", "user.email=t@example.invalid"]
            + arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        #expect(process.terminationStatus == 0, "git \(arguments.joined(separator: " "))")
    }

    private func write(_ text: String, _ path: String) throws {
        try text.write(toFile: path, atomically: true, encoding: .utf8)
    }

    /// first one (a, b) → rename a and edit b → side work (s, on a branch) → main work (d) →
    /// merge → delete b.
    private func history() throws -> (TemporaryFolder, String) {
        let folder = try TemporaryFolder()
        let root = FolderWatcher.realPath(folder.path)
        try git(["init", "-q", "-b", "main"], in: root)
        try write("a", root + "/a.txt")
        try write("b", root + "/b.txt")
        try git(["add", "."], in: root)
        try git(["commit", "-q", "-m", "first one"], in: root, date: 1_700_000_000)
        try git(["mv", "a.txt", "renamed.txt"], in: root)
        try write("b2", root + "/b.txt")
        try git(["commit", "-q", "-am", "second: rename & edit — ünïcode"], in: root, date: 1_700_000_100)
        try git(["checkout", "-q", "-b", "side"], in: root)
        try write("s", root + "/s.txt")
        try git(["add", "s.txt"], in: root)
        try git(["commit", "-q", "-m", "side work"], in: root, date: 1_700_000_200)
        try git(["checkout", "-q", "main"], in: root)
        try write("d", root + "/d.txt")
        try git(["add", "d.txt"], in: root)
        try git(["commit", "-q", "-m", "main work"], in: root, date: 1_700_000_300)
        try git(["merge", "-q", "--no-edit", "side"], in: root, date: 1_700_000_400)
        try git(["rm", "-q", "b.txt"], in: root)
        try git(["commit", "-q", "-m", "delete b"], in: root, date: 1_700_000_500)
        return (folder, root)
    }

    @Test func theLogListsEveryCommitNewestFirstWithItsFirstParent() throws {
        let (folder, root) = try history()
        _ = folder
        let commits = try #require(Git.log(of: root))
        #expect(commits.map(\.subject) == ["delete b", "Merge branch 'side'", "main work", "side work",
                                           "second: rename & edit — ünïcode", "first one"])
        #expect(commits.allSatisfy { $0.author == "Ada Tester" && $0.hash.count == 40 })
        #expect(commits.last?.parent == nil) // the first commit
        #expect(commits[1].parent == commits[2].hash) // the merge: its first parent, main's
        #expect(commits[0].date == Date(timeIntervalSince1970: 1_700_000_500))
        // Of one path; and a limit.
        #expect(try #require(Git.log(of: root, path: "renamed.txt"))
            .map(\.subject) == ["second: rename & edit — ünïcode"])
        #expect(try #require(Git.log(of: root, limit: 2)).count == 2)
        // Not a working copy: nil.
        let other = try TemporaryFolder()
        #expect(Git.log(of: other.path) == nil)
    }

    @Test func eachCommitsChangesAgainstItsFirstParent() throws {
        let (folder, root) = try history()
        _ = folder
        let commits = try #require(Git.log(of: root))
        let changes = { (index: Int) in Git.changes(in: root, commit: commits[index]) }
        #expect(changes(5) == [GitChange(status: "A", path: "a.txt"), GitChange(status: "A", path: "b.txt")])
        #expect(changes(4) == [GitChange(status: "M", path: "b.txt"),
                               GitChange(status: "R", path: "renamed.txt", oldPath: "a.txt")])
        #expect(changes(1) == [GitChange(status: "A", path: "s.txt")]) // the merge brought in s
        #expect(changes(0) == [GitChange(status: "D", path: "b.txt")])
    }

    @Test func aFilesContentsAtARevision() throws {
        let (folder, root) = try history()
        _ = folder
        let commits = try #require(Git.log(of: root))
        #expect(Git.contents(of: "b.txt", at: commits[4].hash, in: root) == Data("b2".utf8))
        #expect(Git.contents(of: "b.txt", at: commits[5].hash, in: root) == Data("b".utf8))
        #expect(Git.contents(of: "b.txt", at: commits[0].hash, in: root) == nil) // deleted there
        #expect(Git.contents(of: "renamed.txt", at: commits[5].hash, in: root) == nil) // not yet
    }

    /// #42 review: a name is taken literally, never as a pattern.
    @Test func aNameWithPatternCharactersIsTakenLiterally() throws {
        let folder = try TemporaryFolder()
        let root = FolderWatcher.realPath(folder.path)
        try git(["init", "-q", "-b", "main"], in: root)
        try write("x", root + "/abc.txt")
        try git(["add", "abc.txt"], in: root)
        try git(["commit", "-q", "-m", "abc"], in: root, date: 1_700_000_000)
        try write("y", root + "/a*.txt")
        try git(["add", "--", "a*.txt"], in: root)
        try git(["commit", "-q", "-m", "star"], in: root, date: 1_700_000_100)
        #expect(try #require(Git.log(of: root, path: "a*.txt")).map(\.subject) == ["star"]) // not "abc" too
        #expect(try #require(Git.log(of: root, path: "a?c.txt")).isEmpty)
    }

    /// #43 review: finding the last fetch can be cancelled; git is stopped, or not started.
    @Test func findingTheLastFetchCanBeCancelled() throws {
        let folder = try TemporaryFolder()
        let script = folder.path + "/slow-git"
        try "#!/bin/sh\nsleep 30\n".write(toFile: script, atomically: true, encoding: .utf8)
        chmod(script, 0o755)
        let cancelled = CancellationFlag()
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.2) { cancelled.set() }
        let start = Date()
        #expect(Git.lastFetch(of: folder.path, git: script, cancelled: cancelled) == nil)
        #expect(Date().timeIntervalSince(start) < 3)
        let already = CancellationFlag()
        already.set()
        let again = Date()
        #expect(Git.lastFetch(of: folder.path, git: script, cancelled: already) == nil)
        #expect(Date().timeIntervalSince(again) < 0.5) // not started at all
    }

    /// #42 review: reading a version can be cancelled; git is stopped.
    @Test func readingAVersionCanBeCancelled() throws {
        let folder = try TemporaryFolder()
        let script = folder.path + "/slow-git"
        try "#!/bin/sh\nsleep 30\n".write(toFile: script, atomically: true, encoding: .utf8)
        chmod(script, 0o755)
        let cancelled = CancellationFlag()
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.2) { cancelled.set() }
        let start = Date()
        #expect(Git.contents(of: "x", at: "HEAD", in: folder.path, git: script, cancelled: cancelled) == nil)
        #expect(Date().timeIntervalSince(start) < 3)
    }

    @Test func theOutputIsParsedEvenWhenOdd() {
        let first = "h1\u{1F}p1 p2\u{1F}A B\u{1F}100\u{1F}subject: with | bars\u{0}"
        let log = Data((first + "h2\u{1F}\u{1F}C\u{1F}x\u{1F}bad\u{0}").utf8)
        let commits = Git.parseLog(log)
        #expect(commits == [GitCommit(hash: "h1", parent: "p1", author: "A B", date: Date(timeIntervalSince1970: 100),
                                      subject: "subject: with | bars")]) // the second has no number
        let changes = Git.parseChanges(Data("C075\u{0}x\u{0}y\u{0}M\u{0}z\u{0}R100\u{0}cut".utf8))
        #expect(changes == [GitChange(status: "C", path: "y", oldPath: "x"), GitChange(status: "M", path: "z")])
    }
}
