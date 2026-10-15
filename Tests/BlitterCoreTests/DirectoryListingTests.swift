@testable import BlitterCore
import Foundation
import Testing

/// A temporary folder that is deleted when the test finishes.
final class TemporaryFolder {
    let path: String

    init() throws {
        path = NSTemporaryDirectory() + "BlitterTests-" + UUID().uuidString
        try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: false)
    }

    deinit {
        chmod(path, 0o755)
        try? FileManager.default.removeItem(atPath: path)
    }

    @discardableResult
    func createFile(_ name: String, bytes: Int = 0) -> String {
        let filePath = path + "/" + name
        FileManager.default.createFile(atPath: filePath, contents: Data(count: bytes))
        return filePath
    }
}

struct DirectoryListingTests {
    @Test func listsFilesFoldersAndSymlinksWithAttributes() async throws {
        let folder = try TemporaryFolder()
        let filePath = folder.createFile("data.bin", bytes: 1234)
        try FileManager.default.createDirectory(atPath: folder.path + "/Sub", withIntermediateDirectories: false)
        try FileManager.default.createSymbolicLink(atPath: folder.path + "/link", withDestinationPath: "data.bin")
        let modified = Date(timeIntervalSince1970: 1_700_000_000.5)
        try FileManager.default.setAttributes([.modificationDate: modified], ofItemAtPath: filePath)

        let entries = try await listDirectory(folder.path)
        let byName = Dictionary(uniqueKeysWithValues: entries.map { ($0.name, $0) })

        #expect(Set(byName.keys) == ["data.bin", "Sub", "link"])
        let file = try #require(byName["data.bin"])
        #expect(file.kind == .file)
        #expect(file.size == 1234)
        #expect(abs(file.modificationDate.timeIntervalSince(modified)) < 0.001)
        #expect(!file.isHidden && !file.isDataless && file.error == 0)

        let sub = try #require(byName["Sub"])
        #expect(sub.kind == .directory)
        #expect(sub.size == 0)

        let link = try #require(byName["link"])
        #expect(link.kind == .symlink)
        #expect(link.size == Int64("data.bin".utf8.count))
    }

    @Test func detectsHiddenItemsByDotAndByFlag() async throws {
        let folder = try TemporaryFolder()
        folder.createFile(".dotfile")
        let flagged = folder.createFile("flagged")
        #expect(chflags(flagged, UInt32(UF_HIDDEN)) == 0)
        folder.createFile("visible")

        let hidden = try await listDirectory(folder.path).filter(\.isHidden).map(\.name)
        #expect(Set(hidden) == [".dotfile", "flagged"])
    }

    @Test func decodesNonASCIINames() async throws {
        let folder = try TemporaryFolder()
        let names: Set = ["Größe.txt", "日本語", "emoji 🚀"]
        for name in names {
            folder.createFile(name)
        }
        let listed = try await Set(listDirectory(folder.path).map(\.name))
        // APFS keeps names as written; compare in canonical form to be independent of normalization.
        #expect(Set(listed.map(\.precomposedStringWithCanonicalMapping))
            == Set(names.map(\.precomposedStringWithCanonicalMapping)))
    }

    @Test func emptyFolderGivesNoEntries() async throws {
        let folder = try TemporaryFolder()
        #expect(try await listDirectory(folder.path).isEmpty)
    }

    /// A 1 KiB buffer holds only a handful of entries, so the listing needs many system calls.
    @Test func listsFoldersAcrossManyBatches() throws {
        let folder = try TemporaryFolder()
        let count = 500
        for index in 0 ..< count {
            folder.createFile(String(format: "file-with-a-reasonably-long-name-%05d.txt", index))
        }
        var batches = 0
        let entries = try BulkLister.list(folder.path, cancelled: CancellationFlag(), bufferSize: 1024) {
            batches += 1
        }
        #expect(entries.count == count)
        #expect(Set(entries.map(\.name)).count == count)
        #expect(batches > 10)
    }

    @Test func missingFolderThrowsENOENT() async throws {
        let folder = try TemporaryFolder()
        await #expect(throws: POSIXError(.ENOENT)) {
            try await listDirectory(folder.path + "/does-not-exist")
        }
    }

    @Test func fileInsteadOfFolderThrowsENOTDIR() async throws {
        let folder = try TemporaryFolder()
        let file = folder.createFile("plain")
        await #expect(throws: POSIXError(.ENOTDIR)) {
            try await listDirectory(file)
        }
    }

    @Test func unreadableFolderThrowsEACCES() async throws {
        let folder = try TemporaryFolder()
        folder.createFile("secret")
        #expect(chmod(folder.path, 0o000) == 0)
        await #expect(throws: POSIXError(.EACCES)) {
            try await listDirectory(folder.path)
        }
    }

    @Test func cancelledTaskThrowsCancellationError() async throws {
        let folder = try TemporaryFolder()
        folder.createFile("a")
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await listDirectory(folder.path)
        }
        await #expect(throws: CancellationError.self) {
            try await task.value
        }
    }

    @Test func cancellationDuringListingStopsAtTheNextBatch() throws {
        let folder = try TemporaryFolder()
        for index in 0 ..< 200 {
            folder.createFile("file-\(index)")
        }
        let flag = CancellationFlag()
        var batches = 0
        #expect(throws: CancellationError.self) {
            try BulkLister.list(folder.path, cancelled: flag, bufferSize: 1024) {
                batches += 1
                flag.set()
            }
        }
        #expect(batches == 1)
    }

    @Test func setCancellationFlagStopsBeforeTheFirstSystemCall() throws {
        let folder = try TemporaryFolder()
        folder.createFile("a")
        let flag = CancellationFlag()
        flag.set()
        #expect(throws: CancellationError.self) {
            try BulkLister.list(folder.path, cancelled: flag)
        }
    }
}

/// `parseEntry` against hand-built buffers, for cases a real file system rarely produces.
/// Layout per getattrlistbulk(2): length, returned set, then the returned attributes in order,
/// with the name bytes in the variable-length area after all fixed-size attributes.
struct ParseEntryTests {
    private struct EntryBuilder {
        var common: attrgroup_t = .init(ATTR_CMN_RETURNED_ATTRS) | attrgroup_t(ATTR_CMN_NAME)
        var file: attrgroup_t = 0
        /// Fixed-size attributes in buffer order. The name bytes are added by `build(name:)`.
        var fixed: [UInt8] = []
        var nameReferenceOffset = 0

        mutating func append(_ value: some Any) {
            withUnsafeBytes(of: value) { fixed.append(contentsOf: $0) }
        }

        /// Reserves the name's attrreference_t at the current position; `build(name:)` fills it in.
        mutating func appendNameReference() {
            nameReferenceOffset = fixed.count
            append(attrreference_t())
        }

        func build(name: [UInt8]) -> [UInt8] {
            var returned = attribute_set_t()
            returned.commonattr = common
            returned.fileattr = file
            let header = MemoryLayout<UInt32>.size + MemoryLayout<attribute_set_t>.size
            var body = fixed
            var reference = attrreference_t()
            // The data offset is relative to the attrreference_t itself; the length includes the NUL.
            reference.attr_dataoffset = Int32(body.count - nameReferenceOffset)
            reference.attr_length = UInt32(name.count + 1)
            withUnsafeBytes(of: reference) {
                body.replaceSubrange(nameReferenceOffset ..< nameReferenceOffset + $0.count, with: $0)
            }
            body += name + [0]
            var bytes: [UInt8] = []
            withUnsafeBytes(of: UInt32(header + body.count)) { bytes.append(contentsOf: $0) }
            withUnsafeBytes(of: returned) { bytes.append(contentsOf: $0) }
            return bytes + body
        }
    }

    private func parse(_ bytes: [UInt8]) -> DirectoryEntry {
        bytes.withUnsafeBytes { BulkLister.parseEntry($0) }
    }

    @Test func entryWithErrorAndOnlyANameKeepsDefaults() {
        var builder = EntryBuilder()
        builder.common |= attrgroup_t(ATTR_CMN_ERROR)
        builder.append(UInt32(EIO))
        builder.appendNameReference()

        let entry = parse(builder.build(name: Array("broken".utf8)))
        #expect(entry.error == EIO)
        #expect(entry.name == "broken")
        #expect(entry.kind == .other)
        #expect(entry.size == 0)
        #expect(entry.modificationDate == Date(timeIntervalSince1970: 0))
        #expect(!entry.isHidden && !entry.isDataless)
    }

    @Test func allAttributesWithAnInvalidUTF8Name() {
        var builder = EntryBuilder()
        builder.common |= attrgroup_t(ATTR_CMN_OBJTYPE) | attrgroup_t(ATTR_CMN_MODTIME) | attrgroup_t(ATTR_CMN_FLAGS)
        builder.file = attrgroup_t(ATTR_FILE_DATALENGTH)
        builder.appendNameReference()
        builder.append(fsobj_type_t(VREG.rawValue))
        builder.append(timespec(tv_sec: 1_700_000_000, tv_nsec: 250_000_000))
        builder.append(UInt32(UF_HIDDEN) | UInt32(SF_DATALESS))
        builder.append(off_t(42))

        let entry = parse(builder.build(name: [0x66, 0xFF, 0x6F]))
        #expect(entry.name == "f\u{FFFD}o")
        #expect(entry.kind == .file)
        #expect(entry.size == 42)
        #expect(entry.modificationDate == Date(timeIntervalSince1970: 1_700_000_000.25))
        #expect(entry.isHidden && entry.isDataless)
        #expect(entry.error == 0)
    }
}

/// Timing probe on a large folder, compared with FileManager. Skipped in normal runs; `just bench` runs it.
struct DirectoryListingBenchmark {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["BLITTER_BENCHMARK"] != nil))
    func listOneHundredThousandEntries() async throws {
        let folder = try TemporaryFolder()
        let count = 100_000
        for index in 0 ..< count {
            close(open(folder.path + "/file-\(index).txt", O_CREAT | O_WRONLY, 0o644))
        }

        let clock = ContinuousClock()
        var entries: [DirectoryEntry] = []
        let bulk = try await clock.measure { entries = try await listDirectory(folder.path) }
        #expect(entries.count == count)

        let keys: [URLResourceKey] = [.isDirectoryKey, .isSymbolicLinkKey, .fileSizeKey,
                                      .contentModificationDateKey, .isHiddenKey]
        var urls: [URL] = []
        let fileManager = try clock.measure {
            urls = try FileManager.default.contentsOfDirectory(at: URL(fileURLWithPath: folder.path),
                                                               includingPropertiesForKeys: keys)
            for url in urls {
                _ = try url.resourceValues(forKeys: Set(keys))
            }
        }
        #expect(urls.count == count)
        print("BENCHMARK \(count) entries: getattrlistbulk \(bulk), FileManager with resource values \(fileManager)")
    }
}
