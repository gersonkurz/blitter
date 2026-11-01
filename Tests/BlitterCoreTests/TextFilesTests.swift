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
}
