import Foundation

/// Whether `path` is a folder, following symbolic links. Like `listDirectory`, the `stat` runs on a
/// GCD queue, because it can block on a slow network or cloud volume.
public func isDirectory(_ path: String) async -> Bool {
    await withCheckedContinuation { continuation in
        DispatchQueue.global(qos: .userInitiated).async {
            var info = stat()
            continuation.resume(returning: stat(path, &info) == 0 && info.st_mode & S_IFMT == S_IFDIR)
        }
    }
}
