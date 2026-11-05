import Foundation

/// Reading and writing small text files (such as the settings file) off the main thread, like
/// every other file system access.
public enum TextFiles {
    /// The file's contents, or nil if there is no file. Other failures throw, including contents
    /// that are not UTF-8 (they must be reported, not read as an empty file).
    public static func read(_ path: String) async throws -> String? {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                continuation.resume(with: Result {
                    guard let data = FileManager.default.contents(atPath: path) else {
                        if !FileManager.default.fileExists(atPath: path) {
                            return nil
                        }
                        throw POSIXError(.EACCES)
                    }
                    guard let text = String(bytes: data, encoding: .utf8) else {
                        throw CocoaError(.fileReadInapplicableStringEncoding)
                    }
                    return text
                })
            }
        }
    }

    /// Creates the file with `contents` (and its folders) unless it exists. Never overwrites.
    public static func createIfMissing(_ path: String, contents: String) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            DispatchQueue.global(qos: .userInitiated).async {
                continuation.resume(with: Result {
                    let folder = (path as NSString).deletingLastPathComponent
                    try FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
                    guard !FileManager.default.fileExists(atPath: path) else {
                        return
                    }
                    // O_EXCL: if another writer got there first, its file stays.
                    let descriptor = open(path, O_WRONLY | O_CREAT | O_EXCL, 0o644)
                    guard descriptor >= 0 else {
                        if errno == EEXIST {
                            return
                        }
                        throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
                    }
                    defer { close(descriptor) }
                    let bytes = Array(contents.utf8)
                    guard write(descriptor, bytes, bytes.count) == bytes.count else {
                        throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
                    }
                })
            }
        }
    }

    /// What `swap` found in the file's place.
    public enum SwapOutcome: Equatable, Sendable {
        /// The expected text: nothing else was lost, nothing was kept.
        case replacedExpected
        /// Something else (another program saved meanwhile). It stays, byte for byte, in the
        /// file `keptAt` beside the original; `text` is it as UTF-8, nil if it is not.
        case replacedOther(text: String?, keptAt: String)
    }

    /// Puts `contents` in the file's place in one step: the new text is written to a new file
    /// beside it (`<name>.conflict-N`, never an existing one), and the two are exchanged with
    /// `renamex_np(RENAME_SWAP)`. That file then holds what was in the file's place at that
    /// instant: if it is `expected`, it is deleted; otherwise it simply stays — whatever another
    /// program saved is never deleted, and no step after the swap can lose it. A reader sees the
    /// old or the new text, never a part. The file must exist; it keeps its permissions. A
    /// symbolic link stays a link: the file it points to is replaced. A volume that cannot
    /// swap (some network shares) throws, and nothing is changed.
    public static func swap(_ path: String, contents: String, expecting expected: String) async throws
        -> SwapOutcome
    {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                continuation.resume(with: Result { try swapNow(path, contents: contents, expecting: expected) })
            }
        }
    }

    private static func swapNow(_ path: String, contents: String, expecting expected: String) throws
        -> SwapOutcome
    {
        let target = URL(fileURLWithPath: path).resolvingSymlinksInPath().path
        let mode = try (FileManager.default.attributesOfItem(atPath: target)[.posixPermissions] as? NSNumber)?
            .uint16Value ?? 0o644
        let side = try createBeside(target, contents: Data(contents.utf8), mode: mode_t(mode))
        guard renamex_np(side, target, UInt32(RENAME_SWAP)) == 0 else {
            let error = POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            unlink(side) // it holds only the new text
            throw error
        }
        let replaced = FileManager.default.contents(atPath: side)
        if replaced == Data(expected.utf8) {
            unlink(side)
            return .replacedExpected
        }
        return .replacedOther(text: replaced.flatMap { String(bytes: $0, encoding: .utf8) }, keptAt: side)
    }

    /// A new file `<target>.conflict-N` with the contents; an existing one is never touched.
    private static func createBeside(_ target: String, contents: Data, mode: mode_t) throws -> String {
        for number in 1 ... 1000 {
            let candidate = "\(target).conflict-\(number)"
            let descriptor = open(candidate, O_WRONLY | O_CREAT | O_EXCL, mode)
            guard descriptor >= 0 else {
                if errno == EEXIST {
                    continue
                }
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
            defer { close(descriptor) }
            let written = contents.withUnsafeBytes { write(descriptor, $0.baseAddress, $0.count) }
            guard written == contents.count, fchmod(descriptor, mode) == 0 else {
                let error = POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
                unlink(candidate)
                throw error
            }
            return candidate
        }
        throw POSIXError(.EEXIST)
    }
}
