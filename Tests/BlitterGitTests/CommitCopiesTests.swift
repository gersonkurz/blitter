@testable import BlitterCore
@testable import BlitterGit
import Foundation
import Testing

/// #89: where a whole commit's copies go, and what is never written.
struct CommitCopiesTests {
    /// #89 review: names that are one file on the Mac's volumes are refused before anything is
    /// written: case, Unicode form, a file in the way of a folder. Different sides do not clash.
    @Test func namesThatAreOneFileOnDiskAreRefused() {
        #expect(CommitCopies.clash(in: ["Foo.txt", "foo.txt"]) ?? ("", "") == ("Foo.txt", "foo.txt"))
        #expect(CommitCopies.clash(in: ["caf\u{E9}.txt", "cafe\u{301}.txt"]) != nil)
        #expect(CommitCopies.clash(in: ["Doc", "doc/a.txt"]) != nil)
        #expect(CommitCopies.clash(in: ["doc/a.txt", "DOC"]) != nil)
        #expect(CommitCopies.clash(in: ["src/a.txt", "src/b.txt", "Src2/a.txt", "a.txt"]) == nil)
        let commit = GitCommit(hash: "h", parent: "p", author: "", date: .distantPast, subject: "")
        let renamed = [GitChange(status: "R", path: "readme.md", oldPath: "README.md")] // one per side
        #expect((try? CommitCopies.plan(renamed, of: commit, in: "/x").get()) != nil)
        let both = [GitChange(status: "M", path: "Foo.txt"), GitChange(status: "M", path: "foo.txt")]
        guard case let .failure(failure) = CommitCopies.plan(both, of: commit, in: "/x") else {
            Issue.record("a clash was planned")
            return
        }
        #expect(failure.message.hasPrefix("“Foo.txt” and “foo.txt” would be the same file"))
    }

    /// Paths come from git, but a copy is never written outside its folder.
    @Test func aCopyStaysInItsFolder() {
        let folder = NSTemporaryDirectory() + "BlitterCopies-" + UUID().uuidString
        defer { try? FileManager.default.removeItem(atPath: folder) }
        for bad in ["../escape.txt", "/etc/x", "a/../../b", "a//b", "./a", ""] {
            guard case .failure = CompareCopies.write(Data(), at: bad, in: folder) else {
                Issue.record("“\(bad)” was written")
                continue
            }
        }
        #expect(!FileManager.default.fileExists(atPath: NSTemporaryDirectory() + "escape.txt"))
        guard case let .success(path) = CompareCopies.write(Data("x".utf8), at: "deep/er/file.txt", in: folder) else {
            Issue.record("a nested path was not written")
            return
        }
        #expect(path == folder + "/deep/er/file.txt")
    }
}
