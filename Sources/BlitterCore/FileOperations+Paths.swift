import Foundation

/// Path and identity helpers for file operations. Identity (device and inode) rather than path
/// strings decides whether two paths are the same item, so aliases and case differences count.
extension FileOperations {
    static func message(_ code: Int32) -> String {
        String(cString: strerror(code))
    }

    static func exists(_ path: String) -> Bool {
        var info = stat()
        return lstat(path, &info) == 0
    }

    struct Identity: Equatable {
        let device: dev_t
        let inode: ino_t
    }

    /// The item at `path` itself (a symbolic link, not what it points to), or nil if there is none.
    static func identity(_ path: String) -> Identity? {
        var info = stat()
        return lstat(path, &info) == 0 ? Identity(device: info.st_dev, inode: info.st_ino) : nil
    }

    static func realPath(_ path: String) -> String {
        guard let resolved = realpath(path, nil) else {
            return path
        }
        defer { free(resolved) }
        return String(cString: resolved)
    }

    /// Whether the two paths name the same folder, through aliases and differences in case.
    static func isSameFolder(_ first: String, _ second: String) -> Bool {
        guard let identity = identity(realPath(first)) else {
            return false
        }
        return identity == Self.identity(realPath(second))
    }

    /// Whether `item` is `path` itself or one of the folders above it, by file identity. The
    /// folders above `path` are resolved. Its last component is resolved too with `resolvingLast`
    /// (a destination folder reached through an alias is that folder); without it a symbolic link
    /// stays itself (a source item that is a link is the link, not what it points to).
    static func isSameOrAncestor(_ item: String, of path: String, resolvingLast: Bool) -> Bool {
        guard let identity = identity(item) else {
            return false
        }
        let name = (path as NSString).lastPathComponent
        var current = resolvingLast ? realPath(path)
            : (realPath((path as NSString).deletingLastPathComponent) as NSString).appendingPathComponent(name)
        while true {
            if Self.identity(current) == identity {
                return true
            }
            guard current != "/", !current.isEmpty else {
                return false
            }
            current = (current as NSString).deletingLastPathComponent
        }
    }

    static func isValidName(_ name: String) -> Bool {
        !name.isEmpty && name != "." && name != ".." && !name.contains("/") && !name.contains("\0")
    }

    /// "report 2.txt", "report 3.txt", ... for "report.txt"; "Folder 2" for "Folder".
    static func freeName(for name: String, in folder: String) -> String {
        let base = (name as NSString).deletingPathExtension
        let pathExtension = (name as NSString).pathExtension
        for number in 2... {
            let candidate = pathExtension.isEmpty ? "\(base) \(number)" : "\(base) \(number).\(pathExtension)"
            let path = (folder as NSString).appendingPathComponent(candidate)
            if !exists(path) {
                return path
            }
        }
        fatalError("unreachable")
    }

    /// Bytes of a file, or of everything in a folder; symbolic links are not followed. Stops early
    /// (with a partial sum) once `cancelled` is set. `visit` is called before each folder is read;
    /// tests use it to cancel in the middle of a scan.
    static func size(of path: String, cancelled: CancellationFlag,
                     visit: (@Sendable (CancellationFlag) -> Void)? = nil) -> Int64
    {
        var info = stat()
        guard lstat(path, &info) == 0 else {
            return 0
        }
        guard info.st_mode & S_IFMT == S_IFDIR else {
            return info.st_mode & S_IFMT == S_IFREG ? Int64(info.st_size) : 0
        }
        visit?(cancelled)
        guard !cancelled.isSet else {
            return 0
        }
        let entries = (try? BulkLister.list(path, cancelled: cancelled)) ?? []
        return entries.reduce(Int64(0)) { total, entry in
            let child = (path as NSString).appendingPathComponent(entry.name)
            let size = entry.kind == .directory ? size(of: child, cancelled: cancelled, visit: visit)
                : entry.kind == .file ? entry.size : 0
            return total + size
        }
    }
}
