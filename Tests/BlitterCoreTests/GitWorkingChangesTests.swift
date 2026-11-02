@testable import BlitterCore
import Foundation
import Testing

/// What Git Commit (#44) reads: the changes that can be committed, and earlier messages.
struct GitWorkingChangesTests {
    private func porcelain(_ records: [String]) -> Data {
        Data(records.joined(separator: "\0").utf8 + [0])
    }

    @Test func changesAreParsedWithTheirIndexAndWorkingTreeLetters() {
        let changes = Git.parseWorkingChanges(porcelain([
            "# branch.oid 1234", "# branch.head main", "# branch.upstream origin/main", "# branch.ab +0 -0",
            "1 M. N... 100644 100644 100644 aaa bbb staged.txt",
            "1 .M N... 100644 100644 100644 aaa bbb src/with space.swift",
            "1 MM N... 100644 100644 100644 aaa bbb both.txt",
            "1 .D N... 100644 100644 000000 aaa aaa gone.txt",
            "2 R. N... 100644 100644 100644 aaa aaa R100 docs/new.md", "docs/old.md",
            "u UU N... 100644 100644 100644 100644 aaa bbb ccc conflict.txt",
            "1 .M S..U 160000 160000 160000 aaa aaa lib/untrackedonly",
            "? new/deep/file.txt", "! ignored.log",
        ]))
        #expect(changes.branch == "main" && changes.upstream == "origin/main" && changes.hasCommits)
        #expect(changes.files == [
            GitFileChange(path: "staged.txt", staged: "M"),
            GitFileChange(path: "src/with space.swift", unstaged: "M"),
            GitFileChange(path: "both.txt", staged: "M", unstaged: "M"),
            GitFileChange(path: "gone.txt", unstaged: "D"),
            GitFileChange(path: "docs/new.md", oldPath: "docs/old.md", staged: "R"),
            GitFileChange(path: "conflict.txt", staged: "U", unstaged: "U"),
            GitFileChange(path: "new/deep/file.txt", unstaged: "?"),
        ])
        #expect(changes.files[5].isUnmerged && changes.files[6].isUntracked)
    }

    /// #44 review: `git rm --cached` gives a staged deletion and an untracked record for one
    /// path; they are one entry.
    @Test func twoRecordsForOnePathAreOneEntry() {
        let changes = Git.parseWorkingChanges(porcelain([
            "1 D. N... 100644 000000 000000 aaa 000 f.txt",
            "2 R. N... 100644 100644 100644 aaa aaa R100 b.txt", "a.txt",
            "? a.txt", "? f.txt",
        ]))
        #expect(changes.files == [
            GitFileChange(path: "f.txt", staged: "D", unstaged: "?"),
            GitFileChange(path: "b.txt", oldPath: "a.txt", staged: "R"),
            GitFileChange(path: "a.txt", unstaged: "?"), // the old name, in use again
        ])
    }

    @Test func beforeTheFirstCommitAndOnADetachedHead() {
        let initial = Git.parseWorkingChanges(porcelain(["# branch.oid (initial)", "# branch.head main"]))
        #expect(!initial.hasCommits && initial.files.isEmpty && initial.upstream == nil)
        let detached = Git.parseWorkingChanges(porcelain(["# branch.oid 1234", "# branch.head (detached)"]))
        #expect(detached.hasCommits && detached.branch == nil)
    }

    @Test func messagesAreTrimmedAndEachListedOnce() {
        let data = Data("Fix it\n\nMore words.\n\0Second\n\0Fix it\n\nMore words.\n\0\n\0".utf8)
        #expect(Git.parseMessages(data) == ["Fix it\n\nMore words.", "Second"])
    }

    @Test func aRealWorkingCopyBeforeAndAfterItsFirstCommit() throws {
        let git = try #require(Git.executable)
        let root = FolderWatcher.realPath(NSTemporaryDirectory()) + "/BlitterChanges-" + UUID().uuidString
        try FileManager.default.createDirectory(atPath: root + "/new/deep", withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: root) }
        func run(_ arguments: [String]) throws {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: git)
            process.arguments = ["-C", root, "-c", "user.name=T", "-c", "user.email=t@example.invalid",
                                 "-c", "commit.gpgsign=false"] + arguments
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            try process.run()
            process.waitUntilExit()
            #expect(process.terminationStatus == 0)
        }
        try run(["init", "-q", "-b", "main"])
        try "x".write(toFile: root + "/new/deep/file.txt", atomically: true, encoding: .utf8)
        try "*.log\n".write(toFile: root + "/.gitignore", atomically: true, encoding: .utf8)
        try "x".write(toFile: root + "/ignored.log", atomically: true, encoding: .utf8)
        let before = try #require(Git.workingChanges(of: root))
        #expect(!before.hasCommits && before.branch == "main")
        // Each untracked file on its own, the ignored one left out.
        #expect(before.files.map(\.path).sorted() == [".gitignore", "new/deep/file.txt"])
        #expect(Git.recentMessages(of: root) == [])

        try run(["add", "-A"])
        try run(["commit", "-q", "-m", "First\n\nwith a body"])
        let after = try #require(Git.workingChanges(of: root))
        #expect(after.hasCommits && after.files.isEmpty)
        #expect(Git.recentMessages(of: root) == ["First\n\nwith a body"])
    }
}
