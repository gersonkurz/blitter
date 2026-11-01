@testable import BlitterCore
import Foundation
import Testing

/// Reading git working copies (#22), with the real git on temporary repositories.
@Suite(.serialized)
struct GitStatusTests {
    @Test func porcelainIsParsed() {
        let records = [
            "# branch.oid 1234", "# branch.head main", "# branch.upstream origin/main", "# branch.ab +2 -1",
            "1 .M N... 100644 100644 100644 aaa bbb src/with space.swift",
            "2 R. N... 100644 100644 100644 aaa bbb R100 docs/new.md", "docs/old.md",
            "u UU N... 100644 100644 100644 100644 aaa bbb ccc conflict.txt",
            "? notes/", "? top.txt", "! ignored.log",
        ]
        let data = Data(records.joined(separator: "\0").utf8 + [0])
        let status = Git.parse(data)
        #expect(status.ahead == 2 && status.behind == 1)
        #expect(status.changed == ["src/with space.swift", "docs/new.md", "docs/old.md", "conflict.txt"])
        #expect(status.untracked == ["notes/", "top.txt"])
        #expect(status.ignored == ["ignored.log"])
    }

    /// #35 review: a submodule whose only change is untracked files is no tracked change; one with
    /// a modified file or a new commit is.
    @Test func aSubmoduleWithOnlyUntrackedFilesIsNoChange() {
        let records = [
            "1 .M S..U 160000 160000 160000 aaa aaa lib/untrackedonly",
            "1 .M S.M. 160000 160000 160000 aaa aaa lib/modified",
            "1 .M SC.. 160000 160000 160000 aaa bbb lib/newcommit",
        ]
        let status = Git.parse(Data(records.joined(separator: "\0").utf8 + [0]))
        #expect(status.changed == ["lib/modified", "lib/newcommit"])
    }

    @Test func trackedFoldersComeFromTheIndex() {
        let index = ["100644 aaa 0\tsrc/app/main.swift", "100644 aaa 0\tREADME.md", "160000 bbb 0\tlib/sub"]
        let folders = Git.trackedFolders(fromIndex: Data(index.joined(separator: "\0").utf8 + [0]))
        #expect(folders == ["", "src", "src/app", "lib", "lib/sub"])
    }

    @Test func aRealWorkingCopy() throws {
        let git = try #require(Git.executable, "no git on this Mac")
        let folder = try TemporaryFolder()
        let root = FolderWatcher.realPath(folder.path)
        try run(git, ["init", "-q", "-b", "main"], in: root)
        try "a".write(toFile: root + "/a.txt", atomically: true, encoding: .utf8)
        try FileManager.default.createDirectory(atPath: root + "/sub/deeper", withIntermediateDirectories: true)
        try "b".write(toFile: root + "/sub/deeper/b.txt", atomically: true, encoding: .utf8)
        try run(git, ["add", "."], in: root)
        try run(git, ["-c", "user.name=Test", "-c", "user.email=test@example.invalid", "commit", "-q", "-m", "first"],
                in: root)

        #expect(Git.isRepositoryRoot(root) && !Git.isRepositoryRoot(root + "/sub"))
        #expect(Git.repositoryRoot(containing: root + "/sub/deeper") == root)
        #expect(Git.isLocal(root))
        let clean = try #require(Git.status(of: root))
        #expect(clean.changed.isEmpty && clean.untracked.isEmpty && clean.ignored.isEmpty)
        #expect(clean.ahead == 0 && clean.behind == 0 && clean.trackedFolders == ["", "sub", "sub/deeper"])

        try "changed".write(toFile: root + "/sub/deeper/b.txt", atomically: true, encoding: .utf8)
        // Tracked changes, untracked and ignored items come apart; a folder with nothing tracked
        // in it is one "dir/" entry (#35).
        try FileManager.default.createDirectory(atPath: root + "/new/deeper", withIntermediateDirectories: true)
        try "n".write(toFile: root + "/new/deeper/n.txt", atomically: true, encoding: .utf8)
        try FileManager.default.createDirectory(atPath: root + "/new/empty", withIntermediateDirectories: false)
        try FileManager.default.createDirectory(atPath: root + "/build", withIntermediateDirectories: false)
        try "x".write(toFile: root + "/build/out.o", atomically: true, encoding: .utf8)
        try "build/\n".write(toFile: root + "/.git/info/exclude", atomically: true, encoding: .utf8)
        let status = try #require(Git.status(of: root))
        #expect(status.changed == ["sub/deeper/b.txt"])
        #expect(status.untracked == ["new/"])
        #expect(status.ignored == ["build/"])
        #expect(status.trackedFolders == ["", "sub", "sub/deeper"])
        #expect(!FileManager.default.fileExists(atPath: root + "/.git/index.lock"))
    }

    /// #35 review, with the real git: a folder holding only an ignored file and an empty folder
    /// are not tracked; a submodule with only untracked files in it changes nothing, one with a
    /// modified file does.
    @Test func ignoredOnlyEmptyAndSubmodules() throws {
        let git = try #require(Git.executable, "no git on this Mac")
        let folder = try TemporaryFolder()
        let base = FolderWatcher.realPath(folder.path)
        let library = base + "/library"
        let root = base + "/root"
        for repo in [library, root] {
            try FileManager.default.createDirectory(atPath: repo, withIntermediateDirectories: false)
            try run(git, ["init", "-q", "-b", "main"], in: repo)
            try "x".write(toFile: repo + "/file.txt", atomically: true, encoding: .utf8)
            try run(git, ["add", "."], in: repo)
            try commit(git, in: repo)
        }
        try run(git, ["-c", "protocol.file.allow=always", "submodule", "add", "-q", library, "sub"], in: root)
        try commit(git, in: root)
        try FileManager.default.createDirectory(atPath: root + "/conf", withIntermediateDirectories: false)
        try "secret".write(toFile: root + "/conf/local.json", atomically: true, encoding: .utf8)
        try "conf/local.json\n".write(toFile: root + "/.git/info/exclude", atomically: true, encoding: .utf8)
        try FileManager.default.createDirectory(atPath: root + "/empty", withIntermediateDirectories: false)
        try "u".write(toFile: root + "/sub/untracked.txt", atomically: true, encoding: .utf8)

        var status = try #require(Git.status(of: root))
        #expect(status.changed.isEmpty) // only untracked content in the submodule
        #expect(status.ignored == ["conf/local.json"]) // the file, not the folder
        #expect(status.trackedFolders.contains("sub") && !status.trackedFolders.contains("conf"))
        #expect(!status.trackedFolders.contains("empty"))

        try "changed".write(toFile: root + "/sub/file.txt", atomically: true, encoding: .utf8)
        status = try #require(Git.status(of: root))
        #expect(status.changed == ["sub"])
    }

    private func commit(_ git: String, in folder: String) throws {
        try run(git, ["-c", "user.name=Test", "-c", "user.email=test@example.invalid", "commit", "-q", "-m", "c"],
                in: folder)
    }

    @Test func noWorkingCopyNoStatus() throws {
        let folder = try TemporaryFolder()
        #expect(Git.repositoryRoot(containing: folder.path) == nil)
        #expect(Git.status(of: folder.path) == nil) // git fails outside a working copy
        #expect(Git.status(of: folder.path, git: nil) == nil)
    }

    @Test func aGitThatHangsIsGivenUpOn() throws {
        let folder = try TemporaryFolder()
        let script = folder.path + "/slow-git"
        try "#!/bin/sh\nsleep 30\n".write(toFile: script, atomically: true, encoding: .utf8)
        chmod(script, 0o755)
        let start = Date()
        #expect(Git.status(of: folder.path, git: script, timeout: 0.3) == nil)
        #expect(Date().timeIntervalSince(start) < 3)
    }

    @Test func aCancelledReadStopsGit() throws {
        let folder = try TemporaryFolder()
        let script = folder.path + "/slow-git"
        try "#!/bin/sh\nsleep 30\n".write(toFile: script, atomically: true, encoding: .utf8)
        chmod(script, 0o755)
        let cancelled = CancellationFlag()
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.2) { cancelled.set() }
        let start = Date()
        #expect(Git.status(of: folder.path, git: script, timeout: 30, cancelled: cancelled) == nil)
        #expect(Date().timeIntervalSince(start) < 3)
    }

    private func run(_ git: String, _ arguments: [String], in folder: String) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: git)
        process.arguments = ["-C", folder] + arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        #expect(process.terminationStatus == 0, "git \(arguments.joined(separator: " "))")
    }
}
