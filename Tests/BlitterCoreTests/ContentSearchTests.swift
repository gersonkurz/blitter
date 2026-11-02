@testable import BlitterCore
import Foundation
import Testing

/// Whether a file contains a text (#49).
struct ContentSearchTests {
    private let folder: TemporaryFolder

    init() throws {
        folder = try TemporaryFolder()
    }

    private func file(_ name: String, _ bytes: [UInt8]) -> String {
        let path = folder.path + "/" + name
        FileManager.default.createFile(atPath: path, contents: Data(bytes))
        return path
    }

    private func file(_ name: String, _ text: String) -> String {
        file(name, Array(text.utf8))
    }

    private func contains(_ path: String, _ text: String, chunk: Int = ContentSearch.chunkSize) -> Bool {
        ContentSearch.file(path, contains: text, cancelled: CancellationFlag(), chunkSize: chunk)
    }

    @Test func caseAndDiacriticsDoNotMatter() {
        let path = file("a.txt", "Der Ärger mit dem Café\nzweite Zeile")
        #expect(contains(path, "ärger") && contains(path, "CAFE") && contains(path, "zweite zeile"))
        #expect(!contains(path, "Kaffee"))
        #expect(contains(path, "")) // nothing asked: anything holds it
    }

    /// Small chunks: a match across two of them, and a character cut in two by them, are found.
    @Test func matchesAcrossChunks() {
        let path = file("b.txt", "aaaaaaaNEEDLEbbbbbbbb äöü end")
        for chunk in [1, 3, 8] {
            #expect(contains(path, "needle", chunk: chunk), "chunk \(chunk)")
            #expect(contains(path, "ÄÖÜ END", chunk: chunk), "chunk \(chunk)")
            #expect(!contains(path, "needlex", chunk: chunk), "chunk \(chunk)")
        }
    }

    @Test func binaryFilesLinksAndMissingFilesHoldNothing() throws {
        let binary = file("c.bin", [0x41, 0x42, 0x00, 0x43] + Array("needle".utf8))
        #expect(!contains(binary, "needle"))
        let text = file("d.txt", "needle")
        try FileManager.default.createSymbolicLink(atPath: folder.path + "/link", withDestinationPath: text)
        #expect(!contains(folder.path + "/link", "needle")) // a link is not followed
        #expect(!contains(folder.path + "/missing", "needle"))
        #expect(!contains(folder.path, "needle")) // a folder
    }

    @Test func aCancelledSearchStops() {
        let path = file("e.txt", String(repeating: "x", count: 1000) + "needle")
        let cancelled = CancellationFlag()
        cancelled.set()
        #expect(!ContentSearch.file(path, contains: "needle", cancelled: cancelled, chunkSize: 10))
    }

    /// #49 review: a letter with any number of combining marks is one character; the chunk
    /// boundary after it does not hide a match (the review's case, at the real chunk size).
    @Test func combiningMarksAcrossTheChunkBoundary() {
        let marks = String(repeating: "\u{0301}", count: 5)
        let text = String(repeating: "x", count: ContentSearch.chunkSize - 11) + "a" + marks + "b"
        let path = file("marks.txt", text)
        #expect(contains(path, "ab"))
        for chunk in [1, 2, 7] {
            #expect(contains(file("short.txt", "xa" + marks + "b"), "ab", chunk: chunk), "chunk \(chunk)")
        }
    }

    /// #49 review: a character split by the chunk boundary is not read as U+FFFD.
    @Test func aSplitCharacterMakesNothingUp() {
        let path = file("split.txt", String(repeating: "x", count: ContentSearch.chunkSize - 1) + "é")
        #expect(!contains(path, "\u{FFFD}"))
        #expect(contains(path, "xé") && contains(path, "XE"))
        // A file that really ends in the middle of a character: that one reads as U+FFFD.
        let cut = file("cut.txt", Array("ab".utf8) + [0xC3])
        #expect(contains(cut, "\u{FFFD}") && contains(cut, "ab"))
    }

    @Test func completeUTF8IsTold() {
        #expect(ContentSearch.Search.completeLength([]) == 0)
        #expect(ContentSearch.Search.completeLength([0xC3]) == 0)
        #expect(ContentSearch.Search.completeLength([0x41, 0xE2, 0x82]) == 1)
        #expect(ContentSearch.Search.completeLength([0xE2, 0x82, 0xAC]) == 3)
        #expect(ContentSearch.Search.completeLength([0x41, 0xF0, 0x9F, 0x98]) == 1)
        #expect(ContentSearch.Search.completeLength([0x41, 0x80]) == 2) // a stray continuation byte: as it is
    }
}
