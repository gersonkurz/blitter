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
        #expect(status.changed == ["src/with space.swift", "docs/new.md", "docs/old.md", "conflict.txt", "notes/",
                                   "top.txt"])
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
        #expect(Git.status(of: root) == GitRepoStatus())

        try "changed".write(toFile: root + "/sub/deeper/b.txt", atomically: true, encoding: .utf8)
        // Untracked content in nested folders is listed file by file, so every folder holding
        // some is known; empty and ignored folders are not listed at all.
        try FileManager.default.createDirectory(atPath: root + "/new/deeper", withIntermediateDirectories: true)
        try "n".write(toFile: root + "/new/deeper/n.txt", atomically: true, encoding: .utf8)
        try FileManager.default.createDirectory(atPath: root + "/new/empty", withIntermediateDirectories: false)
        try FileManager.default.createDirectory(atPath: root + "/build", withIntermediateDirectories: false)
        try "x".write(toFile: root + "/build/out.o", atomically: true, encoding: .utf8)
        try "build/\n".write(toFile: root + "/.git/info/exclude", atomically: true, encoding: .utf8)
        let status = try #require(Git.status(of: root))
        #expect(Set(status.changed) == ["sub/deeper/b.txt", "new/deeper/n.txt"])
        #expect(!FileManager.default.fileExists(atPath: root + "/.git/index.lock"))
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
