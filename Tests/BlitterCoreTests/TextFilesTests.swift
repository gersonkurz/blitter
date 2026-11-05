import BlitterCore
import Foundation
import Testing

struct TextFilesTests {
    @Test func readingAMissingFileGivesNil() async throws {
        let folder = try TemporaryFolder()
        #expect(try await TextFiles.read(folder.path + "/none.toml") == nil)
    }

    @Test func createIfMissingMakesFoldersAndNeverOverwrites() async throws {
        let folder = try TemporaryFolder()
        let path = folder.path + "/a/b/settings.toml"
        try await TextFiles.createIfMissing(path, contents: "first")
        #expect(try await TextFiles.read(path) == "first")
        try await TextFiles.createIfMissing(path, contents: "second")
        #expect(try await TextFiles.read(path) == "first")
    }

    /// #63: the zoomed font size is saved this way; a linked settings file stays a link, and
    /// the file keeps its permissions. The expected text replaced: nothing is left beside it.
    @Test func swapWritesThroughASymbolicLink() async throws {
        let folder = try TemporaryFolder()
        let real = folder.path + "/real.toml"
        let link = folder.path + "/settings.toml"
        try "old".write(toFile: real, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: real)
        try FileManager.default.createSymbolicLink(atPath: link, withDestinationPath: real)
        #expect(try await TextFiles.swap(link, contents: "new", expecting: "old") == .replacedExpected)
        #expect(try FileManager.default.destinationOfSymbolicLink(atPath: link) == real)
        #expect(try await TextFiles.read(real) == "new")
        let mode = try FileManager.default.attributesOfItem(atPath: real)[.posixPermissions] as? NSNumber
        #expect(mode?.intValue == 0o600)
        #expect(try FileManager.default.contentsOfDirectory(atPath: folder.path).sorted()
            == ["real.toml", "settings.toml"])
    }

    /// Something else in the file's place stays byte for byte beside it, even bytes that are not
    /// text; an earlier kept version is never overwritten.
    @Test func whatElseWasThereIsKeptInANewFile() async throws {
        let folder = try TemporaryFolder()
        let path = folder.path + "/settings.toml"
        let earlier = path + ".conflict-1"
        try "earlier".write(toFile: earlier, atomically: true, encoding: .utf8)
        let notText = Data([0x5B, 0xFF, 0xFE, 0x5D])
        try notText.write(to: URL(fileURLWithPath: path))
        let outcome = try await TextFiles.swap(path, contents: "new", expecting: "what was read")
        #expect(outcome == .replacedOther(text: nil, keptAt: path + ".conflict-2"))
        #expect(FileManager.default.contents(atPath: path + ".conflict-2") == notText)
        #expect(try String(contentsOfFile: earlier, encoding: .utf8) == "earlier")
        #expect(try await TextFiles.read(path) == "new")

        try "an editor's".write(toFile: path, atomically: true, encoding: .utf8)
        #expect(try await TextFiles.swap(path, contents: "newer", expecting: "new")
            == .replacedOther(text: "an editor's", keptAt: path + ".conflict-3"))
    }

    @Test func swappingAMissingFileThrowsAndLeavesNothing() async throws {
        let folder = try TemporaryFolder()
        await #expect(throws: (any Error).self) {
            try await TextFiles.swap(folder.path + "/none", contents: "x", expecting: "")
        }
        #expect(try FileManager.default.contentsOfDirectory(atPath: folder.path).isEmpty)
    }
}
