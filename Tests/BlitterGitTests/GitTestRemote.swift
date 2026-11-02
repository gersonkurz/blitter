@testable import BlitterCore
import Foundation
import Testing

/// A bare "remote" and clones "a" and "b" of it in a temporary folder, both on main with its
/// upstream, for tests against a real git (#43, #44).
final class GitTestRemote {
    let root: String
    let git: String

    init() throws {
        let folder = NSTemporaryDirectory() + "BlitterGitTests-" + UUID().uuidString
        try FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: false)
        root = FolderWatcher.realPath(folder)
        git = try #require(Git.executable, "no git on this Mac")
        try run(["init", "-q", "--bare", "-b", "main", root + "/remote.git"], in: root)
        try run(["clone", "-q", root + "/remote.git", root + "/a"], in: root)
        try configure("a")
        try commit("README.md", "hello", in: "a")
        try run(["push", "-q", "-u", "origin", "main"], in: root + "/a")
        try run(["clone", "-q", root + "/remote.git", root + "/b"], in: root)
        try configure("b")
    }

    /// Commits made by the code under test (a plain `git commit`) need no global git settings,
    /// and are never signed or run through the user's hooks.
    private func configure(_ clone: String) throws {
        for (key, value) in [("user.name", "T"), ("user.email", "t@example.invalid"), ("commit.gpgsign", "false"),
                             ("core.hooksPath", root + "/hooks-" + clone)]
        {
            try run(["config", key, value], in: path(clone))
        }
    }

    deinit {
        try? FileManager.default.removeItem(atPath: root)
    }

    func path(_ clone: String) -> String {
        root + "/" + clone
    }

    func commit(_ file: String, _ text: String, in clone: String) throws {
        try text.write(toFile: path(clone) + "/" + file, atomically: true, encoding: .utf8)
        try run(["add", file], in: path(clone))
        try run(["-c", "user.name=T", "-c", "user.email=t@example.invalid", "commit", "-q", "-m", file],
                in: path(clone))
    }

    /// What git prints, trimmed.
    func output(_ arguments: [String], in folder: String) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: git)
        process.arguments = ["-C", folder] + arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (String(bytes: data, encoding: .utf8) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func run(_ arguments: [String], in folder: String) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: git)
        process.arguments = ["-C", folder] + arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        #expect(process.terminationStatus == 0, "git \(arguments.joined(separator: " "))")
    }

    /// A file's text, or nil.
    func text(_ file: String, in clone: String) -> String? {
        try? String(contentsOfFile: path(clone) + "/" + file, encoding: .utf8)
    }
}
