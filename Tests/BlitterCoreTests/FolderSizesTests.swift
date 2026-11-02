@testable import BlitterCore
import Foundation
import Testing

/// Measuring a folder (#52) on a real tree.
struct FolderSizesTests {
    private let root = NSTemporaryDirectory() + "BlitterFolderSizes-" + UUID().uuidString

    private func file(_ path: String, bytes: Int) {
        FileManager.default.createFile(atPath: root + "/" + path, contents: Data(count: bytes))
    }

    @Test func everythingBelowIsAddedUpLinksAndUnreadableFoldersAside() throws {
        let manager = FileManager.default
        for folder in ["sub/deeper", "Tool.app/Contents", "locked"] {
            try manager.createDirectory(atPath: root + "/" + folder, withIntermediateDirectories: true)
        }
        defer {
            try? manager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: root + "/locked")
            try? manager.removeItem(atPath: root)
        }
        file("a.txt", bytes: 100)
        file(".hidden", bytes: 10) // hidden items count
        file("sub/deeper/b.bin", bytes: 1000)
        file("Tool.app/Contents/c", bytes: 5) // so do packages' contents
        file("locked/secret", bytes: 7)
        try manager.setAttributes([.posixPermissions: 0], ofItemAtPath: root + "/locked")
        // Links count their own size (the length of the path they hold), never what they point to.
        try manager.createSymbolicLink(atPath: root + "/link", withDestinationPath: "sub/deeper/b.bin")
        try manager.createSymbolicLink(atPath: root + "/folderlink", withDestinationPath: "sub")

        let links: Int = "sub/deeper/b.bin".utf8.count + "sub".utf8.count
        let expected = Int64(100 + 10 + 1000 + 5 + links)
        #expect(FolderSizes.measure(root, cancelled: CancellationFlag()) == expected)
        #expect(FolderSizes.measure(root + "/sub", cancelled: CancellationFlag()) == 1000)
        // A link the user opened is measured where it leads.
        #expect(FolderSizes.measure(root + "/folderlink", cancelled: CancellationFlag()) == 1000)
        #expect(FolderSizes.measure(root + "/missing", cancelled: CancellationFlag()) == 0)

        let cancelled = CancellationFlag()
        cancelled.set()
        #expect(FolderSizes.measure(root, cancelled: cancelled) == nil)
    }

    /// Stop between the entries of one folder: not one more entry is looked at (#52 review).
    @Test func stopEndsTheWalkBetweenEntries() throws {
        let manager = FileManager.default
        for index in 0 ..< 20 {
            try manager.createDirectory(atPath: root + "/folder\(index)", withIntermediateDirectories: true)
            file("file\(index)", bytes: 1)
        }
        defer { try? manager.removeItem(atPath: root) }
        let cancelled = CancellationFlag()
        var visits = 0
        let result = FolderSizes.measure(root, cancelled: cancelled) {
            visits += 1
            cancelled.set()
        }
        #expect(result == nil && visits == 1)
    }
}
