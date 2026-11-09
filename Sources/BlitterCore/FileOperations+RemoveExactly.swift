import Foundation

/// What Git Clean removes (#71), read together with its preview: the folder cleaned, each file
/// and folder below it by its path relative to that folder, and the identity of each of them and
/// of every folder on the way. Removing goes only through folders that are still those very
/// folders, and only removes items that are still those very items.
public struct RemovalPlan: Equatable, Sendable {
    public struct Item: Equatable, Sendable {
        public let relative: String
        public let identity: ItemIdentity
    }

    public let root: String
    let rootIdentity: ItemIdentity
    public let files: [Item]
    /// Removed once empty, deepest first.
    public let folders: [Item]
    /// Every folder on the way to an item, by its relative path.
    let way: [String: ItemIdentity]

    public var isEmpty: Bool {
        files.isEmpty && folders.isEmpty
    }

    /// Reads the identities now (off the main thread): items no longer there are left out. Nil if
    /// the folder itself cannot be read.
    public static func read(root: String, files: [String], folders: [String]) -> RemovalPlan? {
        guard let rootIdentity = FileOperations.identity(root) else {
            return nil
        }
        func items(_ paths: [String]) -> [Item] {
            paths.compactMap { relative in
                FileOperations.identity(root + "/" + relative).map { Item(relative: relative, identity: $0) }
            }
        }
        let (fileItems, folderItems) = (items(files), items(folders))
        var way: [String: ItemIdentity] = [:]
        for item in fileItems + folderItems {
            var prefix = ""
            for component in item.relative.split(separator: "/").dropLast() {
                prefix += (prefix.isEmpty ? "" : "/") + component
                if way[prefix] == nil {
                    way[prefix] = FileOperations.identity(root + "/" + prefix)
                }
            }
        }
        return RemovalPlan(root: root, rootIdentity: rootIdentity, files: fileItems, folders: folderItems, way: way)
    }
}

/// Removing a plan: each item through open folder handles (`openat` with `O_NOFOLLOW`, each
/// folder's identity checked), never by a path a link swapped in since could redirect.
/// - For good: files with `unlinkat`, then folders with `rmdir`, deepest first.
/// - To the Trash: files with `renameat` into one staging folder (keeping their paths), the
///   folders' details (permissions, flags, extended attributes, ACL) copied onto their
///   counterparts there, the staging folder to the Trash, then the folders with `rmdir`. Undo
///   puts each file back, and makes each folder again with its details. If the Trash refuses,
///   the files go back at once and no folder is removed.
/// `rmdir` refuses a folder that is not empty: whatever turned up in one keeps it.
extension FileOperations {
    mutating func removeExactly(_ plan: RemovalPlan, forGood: Bool) {
        context.update { $0.totalItems = plan.files.count + plan.folders.count }
        guard let root = Self.openFolder(plan.root, at: AT_FDCWD, identity: plan.rootIdentity) else {
            fail(plan.root, "The folder changed since the list was made; nothing was removed.")
            return
        }
        defer { close(root) }
        if forGood {
            deleteFiles(plan, from: root)
            _ = removeEmptyFolders(plan, from: root) { _ in true }
            return
        }
        guard var staging = Staging(in: root, at: plan.root) else {
            fail(plan.root, "No folder for the Trash could be made here; nothing was removed.")
            return
        }
        gatherFiles(plan, from: root, into: &staging)
        let detailsKept = keepDetails(of: plan, from: root, in: &staging)
        let trashed: String?
        do {
            trashed = try trashItem(staging.path)
        } catch {
            putBack(staging, plan: plan, root: root)
            fail(plan.root, "The Trash refused (\(error.localizedDescription)); everything was put back.")
            return
        }
        close(staging.handle)
        guard let trashed else {
            return // in the Trash, but where is not known: nothing to undo, so the folders stay
        }
        for item in staging.taken {
            undoSteps.append(.move(trashed + "/" + item.relative, toPath: plan.root + "/" + item.relative,
                                   item.identity))
        }
        for relative in removeEmptyFolders(plan, from: root, if: detailsKept.contains) {
            undoSteps.append(.makeFolder(plan.root + "/" + relative, details: trashed + "/" + relative))
        }
    }

    private mutating func deleteFiles(_ plan: RemovalPlan, from root: Int32) {
        for item in plan.files where !isCancelled {
            context.update { $0.currentItem = (item.relative as NSString).lastPathComponent }
            defer { context.update { $0.doneItems += 1 } }
            guard let (parent, name) = open(item, of: plan, from: root) else {
                continue
            }
            if unlinkat(parent, name, 0) != 0 {
                fail(plan.root + "/" + item.relative, Self.message(errno))
            }
            close(parent)
        }
    }

    private mutating func gatherFiles(_ plan: RemovalPlan, from root: Int32, into staging: inout Staging) {
        for item in plan.files where !isCancelled {
            context.update { $0.currentItem = (item.relative as NSString).lastPathComponent }
            defer { context.update { $0.doneItems += 1 } }
            guard let (parent, name) = open(item, of: plan, from: root) else {
                continue
            }
            if !staging.take(item, from: parent, name: name) {
                fail(plan.root + "/" + item.relative, Self.message(errno))
            }
            close(parent)
        }
    }

    /// Copies each folder's details onto its counterpart in the staging folder; the folders
    /// whose details are kept (only those are removed later).
    private mutating func keepDetails(of plan: RemovalPlan, from root: Int32,
                                      in staging: inout Staging) -> Set<String>
    {
        var kept: Set<String> = []
        for item in plan.folders where !isCancelled {
            guard let (parent, name) = open(item, of: plan, from: root) else {
                continue
            }
            defer { close(parent) }
            guard let folder = Self.openFolder(name, at: parent, identity: item.identity) else {
                fail(plan.root + "/" + item.relative, "It changed since the list was made; it was left as it is.")
                continue
            }
            defer { close(folder) }
            if staging.copyDetails(of: folder, to: item.relative, with: copyDetails) {
                kept.insert(item.relative)
            } else {
                fail(plan.root + "/" + item.relative, "It was kept: its details could not be kept for Undo.")
            }
        }
        return kept
    }

    /// The plan's folders that `remove` allows, deepest first, each only if empty; returns those
    /// removed (relative).
    private mutating func removeEmptyFolders(_ plan: RemovalPlan, from root: Int32,
                                             if remove: (String) -> Bool) -> [String]
    {
        let deepestFirst = plan.folders.filter { remove($0.relative) }.sorted {
            $0.relative.split(separator: "/").count > $1.relative.split(separator: "/").count
        }
        var removed: [String] = []
        for item in deepestFirst where !isCancelled {
            defer { context.update { $0.doneItems += 1 } }
            guard let (parent, name) = open(item, of: plan, from: root) else {
                continue
            }
            defer { close(parent) }
            let path = plan.root + "/" + item.relative
            if unlinkat(parent, name, AT_REMOVEDIR) == 0 {
                removed.append(item.relative)
            } else if errno == ENOTEMPTY || errno == EEXIST {
                fail(path, "“\(name)” was kept: something was added to it after the list was made.")
            } else {
                fail(path, Self.message(errno))
            }
        }
        return removed
    }

    /// The folder holding the item, opened through the plan's folders; nil (reported) if one of
    /// them changed.
    mutating func openWay(to relative: String, of plan: RemovalPlan, from root: Int32) -> Int32? {
        var folder = dup(root)
        var prefix = ""
        for component in relative.split(separator: "/").dropLast().map(String.init) {
            prefix += (prefix.isEmpty ? "" : "/") + component
            guard let identity = plan.way[prefix],
                  let next = Self.openFolder(component, at: folder, identity: identity)
            else {
                close(folder)
                fail(
                    plan.root + "/" + relative,
                    "A folder on its way changed since the list was made; it was left as it is."
                )
                return nil
            }
            close(folder)
            folder = next
        }
        return folder
    }

    /// The item's folder and its name, if it is still the item of the plan; otherwise that is
    /// reported (unless it is simply gone) and nil returned.
    private mutating func open(_ item: RemovalPlan.Item, of plan: RemovalPlan, from root: Int32) -> (Int32, String)? {
        guard let folder = openWay(to: item.relative, of: plan, from: root) else {
            return nil
        }
        let name = (item.relative as NSString).lastPathComponent
        var info = stat()
        let found = fstatat(folder, name, &info, AT_SYMLINK_NOFOLLOW) == 0
        let gone = !found && errno == ENOENT
        guard found, ItemIdentity(device: info.st_dev, inode: info.st_ino) == item.identity else {
            close(folder)
            if !gone {
                fail(plan.root + "/" + item.relative, "It changed since the list was made; it was left as it is.")
            }
            return nil
        }
        return (folder, name)
    }

    /// A folder opened without following a link, if it is the folder with that identity.
    static func openFolder(_ name: String, at folder: Int32, identity: ItemIdentity) -> Int32? {
        let handle = openat(folder, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard handle >= 0 else {
            return nil
        }
        var info = stat()
        guard fstat(handle, &info) == 0, ItemIdentity(device: info.st_dev, inode: info.st_ino) == identity else {
            close(handle)
            return nil
        }
        return handle
    }
}
