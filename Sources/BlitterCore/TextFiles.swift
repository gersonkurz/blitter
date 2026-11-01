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
}
