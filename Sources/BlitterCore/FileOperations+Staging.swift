import Foundation

/// One folder in the cleaned folder that Git Clean's trashed files gather in, keeping their
/// paths, with the removed folders' details on their counterparts (#71). It goes to the Trash as
/// a whole; if the Trash refuses, `putBack` returns everything.
struct Staging {
    let handle: Int32
    let path: String
    let name: String
    private(set) var taken: [RemovalPlan.Item] = []
    /// Folders made in it, by relative path.
    private(set) var made: [String] = []
    /// What details are copied: permissions, owner, flags, times, extended attributes, ACL.
    static let details = copyfile_flags_t(COPYFILE_SECURITY | COPYFILE_XATTR | COPYFILE_STAT)

    init?(in root: Int32, at rootPath: String) {
        let stamp = Int(Date().timeIntervalSince1970)
        for number in 1 ... 100 {
            let name = "Git Clean \(stamp)" + (number > 1 ? " \(number)" : "")
            guard mkdirat(root, name, 0o700) == 0 else {
                if errno == EEXIST {
                    continue
                }
                return nil
            }
            let handle = openat(root, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            guard handle >= 0 else {
                return nil
            }
            self.handle = handle
            self.name = name
            path = rootPath + "/" + name
            return
        }
        return nil
    }

    /// The counterpart of `relative` (a folder) in here, made if needed; an open handle.
    mutating func folder(_ relative: String) -> Int32? {
        var folder = dup(handle)
        var prefix = ""
        for component in relative.split(separator: "/").map(String.init) {
            prefix += (prefix.isEmpty ? "" : "/") + component
            if mkdirat(folder, component, 0o700) == 0 {
                made.append(prefix)
            }
            let next = openat(folder, component, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            close(folder)
            guard next >= 0 else {
                return nil
            }
            folder = next
        }
        return folder
    }

    /// Moves the item from its folder into here, at its relative path.
    mutating func take(_ item: RemovalPlan.Item, from parent: Int32, name: String) -> Bool {
        guard let folder = folder((item.relative as NSString).deletingLastPathComponent) else {
            return false
        }
        defer { close(folder) }
        guard renameatx_np(parent, name, folder, name, UInt32(RENAME_EXCL)) == 0 else {
            return false
        }
        taken.append(item)
        return true
    }

    /// Copies an open folder's details onto its counterpart in here (`copy`: `fcopyfile`).
    mutating func copyDetails(of source: Int32, to relative: String,
                              with copy: FileOperations.DetailsCopier) -> Bool
    {
        guard let folder = folder(relative) else {
            return false
        }
        defer { close(folder) }
        return copy(source, folder) == 0
    }
}

extension FileOperations {
    /// The Trash refused the staging folder: each file goes back to its folder (through the
    /// plan's folders), then the staging folder is removed if that left it empty.
    mutating func putBack(_ staging: Staging, plan: RemovalPlan, root: Int32) {
        for item in staging.taken.reversed() {
            let path = plan.root + "/" + item.relative
            let name = (item.relative as NSString).lastPathComponent
            let inside = (item.relative as NSString).deletingLastPathComponent
            let from = inside.isEmpty ? dup(staging.handle)
                : openat(staging.handle, inside, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            guard from >= 0 else {
                fail(path, "It could not be put back; it is in “\(staging.path)”.")
                continue
            }
            defer { close(from) }
            guard let parent = openWay(to: item.relative, of: plan, from: root) else {
                fail(path, "It could not be put back; it is in “\(staging.path)”.")
                continue
            }
            defer { close(parent) }
            if renameatx_np(from, name, parent, name, UInt32(RENAME_EXCL)) != 0 {
                fail(path, "It could not be put back; it is in “\(staging.path)”.")
            }
        }
        // Only the folders made in it are left once all went back: deepest first, each if empty.
        for relative in staging.made.sorted(by: { $0.split(separator: "/").count > $1.split(separator: "/").count }) {
            unlinkat(staging.handle, relative, AT_REMOVEDIR)
        }
        close(staging.handle)
        unlinkat(root, staging.name, AT_REMOVEDIR) // only if empty
    }
}
