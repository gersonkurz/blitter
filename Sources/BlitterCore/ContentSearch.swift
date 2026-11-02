import Foundation

/// Whether files contain a text (#49), for Find. Reads the disk: call it off the main thread.
public enum ContentSearch {
    /// How much is read at a time.
    public static let chunkSize = 256 * 1024

    /// Whether the file at `path` contains `text`, ignoring case and diacritics. It is read in
    /// chunks, and reading stops at the first match. A file with a NUL byte in its first chunk
    /// counts as binary and contains nothing; so does a file that cannot be opened (a link is
    /// not followed). Text is read as UTF-8; bytes that are not (or a file that ends in the
    /// middle of a character) read as U+FFFD. Stops, answering false, once `cancelled` is set,
    /// and does not even open the file then.
    public static func file(_ path: String, contains text: String, cancelled: CancellationFlag,
                            chunkSize: Int = chunkSize) -> Bool
    {
        guard !text.isEmpty else {
            return true
        }
        guard !cancelled.isSet else {
            return false
        }
        let descriptor = open(path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else {
            return false
        }
        defer { close(descriptor) }
        var search = Search(text)
        var buffer = [UInt8](repeating: 0, count: chunkSize)
        var first = true
        while !cancelled.isSet {
            let count = buffer.withUnsafeMutableBytes { read(descriptor, $0.baseAddress, chunkSize) }
            guard count > 0 else {
                return count == 0 && search.finish() // the end; a read error is no match
            }
            let chunk = buffer[0 ..< count]
            if first, chunk.contains(0) {
                return false // binary
            }
            first = false
            if search.add(chunk) {
                return true
            }
        }
        return false
    }

    /// Matching across chunks. Bytes are decoded exactly: a character whose bytes are split
    /// between two chunks waits for the rest, so no chunk boundary makes up a character. What
    /// is carried over from the text read so far is a number of characters (grapheme clusters),
    /// not bytes: a letter with any number of combining marks is one, and ignoring diacritics
    /// ignores the marks. A match covers at most three characters per character of the text
    /// (case folding turns "ﬃ" into "ffi"); a few more are kept to be sure.
    struct Search {
        let text: String
        let keep: Int
        /// The end of the last chunk: a character still incomplete.
        private var pending: [UInt8] = []
        private var tail = ""

        init(_ text: String) {
            self.text = text
            keep = text.count * 3 + 8
        }

        /// Whether the text is found once these bytes are added.
        mutating func add(_ bytes: ArraySlice<UInt8>) -> Bool {
            let all = pending + bytes
            let complete = Self.completeLength(all)
            pending = Array(all[complete...])
            // swiftlint:disable:next optional_data_string_conversion
            let window = tail + String(decoding: all[..<complete], as: UTF8.self) // complete: nothing is lost
            if Self.matches(window, text) {
                return true
            }
            tail = String(window.suffix(keep))
            return false
        }

        /// At the end of the file: an incomplete last character reads as U+FFFD.
        mutating func finish() -> Bool {
            guard !pending.isEmpty else {
                return false
            }
            // swiftlint:disable:next optional_data_string_conversion
            let window = tail + String(decoding: pending, as: UTF8.self) // lossy on purpose: see above
            pending = []
            return Self.matches(window, text)
        }

        private static func matches(_ window: String, _ text: String) -> Bool {
            window.range(of: text, options: [.caseInsensitive, .diacriticInsensitive]) != nil
        }

        /// How many bytes form complete UTF-8 sequences: an unfinished last one is left out. A
        /// byte that cannot start a sequence counts as complete (it decodes as U+FFFD).
        static func completeLength(_ bytes: [UInt8]) -> Int {
            // The last lead byte is at most three bytes from the end.
            for back in stride(from: 1, through: min(4, bytes.count), by: 1) {
                let byte = bytes[bytes.count - back]
                if byte & 0xC0 != 0x80 { // not a continuation byte
                    let needed = byte >= 0xF0 ? 4 : byte >= 0xE0 ? 3 : byte >= 0xC0 ? 2 : 1
                    return back < needed ? bytes.count - back : bytes.count
                }
            }
            return bytes.count // none, or only continuation bytes: invalid either way
        }
    }
}
