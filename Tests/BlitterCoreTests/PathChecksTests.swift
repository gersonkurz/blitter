import BlitterCore
import Foundation
import Testing

struct PathChecksTests {
    @Test func isDirectoryFollowsSymlinks() async throws {
        let folder = try TemporaryFolder()
        folder.createFile("file")
        try FileManager.default.createDirectory(atPath: folder.path + "/dir", withIntermediateDirectories: false)
        try FileManager.default.createSymbolicLink(atPath: folder.path + "/to-dir", withDestinationPath: "dir")
        try FileManager.default.createSymbolicLink(atPath: folder.path + "/to-file", withDestinationPath: "file")
        try FileManager.default.createSymbolicLink(atPath: folder.path + "/dangling", withDestinationPath: "nowhere")

        #expect(await isDirectory(folder.path + "/dir"))
        #expect(await isDirectory(folder.path + "/to-dir"))
        #expect(await !isDirectory(folder.path + "/file"))
        #expect(await !isDirectory(folder.path + "/to-file"))
        #expect(await !isDirectory(folder.path + "/dangling"))
        #expect(await !isDirectory(folder.path + "/missing"))
    }
}
