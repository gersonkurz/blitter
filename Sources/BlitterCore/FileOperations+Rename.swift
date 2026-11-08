import Foundation

/// Rename one item, or several (batch rename). For several, every item first gets a temporary name, then its new one,
/// so names can be
/// swapped or passed along within the batch. Nothing is renamed unless every new name is valid,
/// unique in its folder and free there, or taken by an item of the batch itself.
extension FileOperations {
    mutating func rename(_ path: String, to name: String) {
        guard !isCancelled else {
            return
        }
        guard Self.isValidName(name) else {
            fail(path, "“\(name)” is not a valid name.")
            return
        }
        let target = ((path as NSString).deletingLastPathComponent as NSString).appendingPathComponent(name)
        // On a case-insensitive volume a change of case only names the same item: that is the one
        // case where the new name may already "exist". Anything else must not be overwritten.
        let isSameItem = Self.identity(target) != nil && Self.identity(target) == Self.identity(path)
        let flags = isSameItem ? 0 : UInt32(RENAME_EXCL)
        if renamex_np(path, target, flags) != 0 {
            fail(path, errno == EEXIST ? "An item named “\(name)” already exists." : Self.message(errno))
        } else {
            recordRenames([Rename(path: target, newName: (path as NSString).lastPathComponent)])
        }
    }

    mutating func renameAll(_ renames: [Rename]) {
        guard Self.canRenameAll(renames, cancelled: context.cancellation, fail: { fail($0, $1) }),
              context.commit() // from here it runs to the end: half a batch would leave temporary names
        else {
            return
        }
        context.update { $0.totalItems = renames.count }
        var staged: [Staged] = []
        for rename in renames {
            let item = Staged(rename: rename)
            let code = renameItem(rename.path, item.temporary)
            guard code == 0 else {
                fail(rename.path, Self.message(code))
                undo(staged, renamed: [])
                return
            }
            staged.append(item)
        }
        var renamed: [Staged] = []
        for item in staged {
            context.update { $0.currentItem = item.rename.newName }
            let code = renameItem(item.temporary, item.target)
            guard code == 0 else {
                fail(item.rename.path, code == EEXIST ? "An item named “\(item.rename.newName)” already exists."
                    : Self.message(code))
                undo(staged, renamed: renamed)
                return
            }
            renamed.append(item)
            context.update { $0.doneItems += 1 }
        }
        recordRenames(renamed.map {
            Rename(path: $0.target, newName: ($0.rename.path as NSString).lastPathComponent)
        })
    }

    /// An item of a batch on its way: its temporary name and its final path.
    private struct Staged {
        let rename: Rename
        let temporary: String
        let target: String

        var oldName: String {
            (rename.path as NSString).lastPathComponent
        }

        init(rename: Rename) {
            self.rename = rename
            let folder = (rename.path as NSString).deletingLastPathComponent
            temporary = folder + "/.blitter-rename-" + UUID().uuidString
            target = folder + "/" + rename.newName
        }
    }

    /// Puts the whole batch back: the items already renamed to their temporary names first (their
    /// old names may be other items' new ones), then every staged item to its old name. An item
    /// that cannot get its old name back is reported with the name it has now, and recorded for
    /// Undo (#61) to try again.
    private mutating func undo(_ staged: [Staged], renamed: [Staged]) {
        var stuck: Set<String> = [] // still at its new name
        var left: [Rename] = [] // where each item that did not get back is, and its old name
        for item in renamed.reversed() where renameItem(item.target, item.temporary) != 0 {
            stuck.insert(item.temporary)
            fail(item.rename.path, "It could not get its old name back and is now named “\(item.rename.newName)”.")
            left.append(Rename(path: item.target, newName: item.oldName))
        }
        for item in staged.reversed() where !stuck.contains(item.temporary) {
            if renameItem(item.temporary, item.rename.path) != 0 {
                let name = (item.temporary as NSString).lastPathComponent
                fail(item.rename.path, "It could not get its old name back and is now named “\(name)”.")
                left.append(Rename(path: item.temporary, newName: item.oldName))
            }
        }
        recordRenames(left)
    }

    /// Every new name valid and unique in its folder, and not taken there by an item outside the
    /// batch; both ignoring case (the rule the preview shows), whether or not the volume does.
    /// Each folder is listed once; a folder that cannot be listed refuses the batch, as what is in
    /// it is not known (#54 review). Otherwise each problem is reported.
    private static func canRenameAll(_ renames: [Rename], cancelled: CancellationFlag,
                                     fail: (String, String) -> Void) -> Bool
    {
        let sources = Set(renames.compactMap { identity($0.path) })
        var listings: [String: Result<[String: [String]], Error>] = [:] // folder → folded name → names
        var seen: Set<String> = []
        var fine = true
        for rename in renames {
            let folder = (rename.path as NSString).deletingLastPathComponent
            let folded = rename.newName.lowercased()
            if listings[folder] == nil {
                listings[folder] = Result {
                    try Dictionary(grouping: listDirectory(folder, cancelled: cancelled).map(\.name)) { $0.lowercased()
                    }
                }
            }
            let listing: [String: [String]]
            switch listings[folder] {
            case let .success(names)?:
                listing = names
            case let .failure(error)?:
                let reason = (error as? POSIXError).map { message($0.code.rawValue) } ?? "it was stopped"
                fail(rename.path, "Its folder could not be read (\(reason)), so its names cannot be checked.")
                fine = false
                continue
            case nil:
                continue // listed just above
            }
            let clashes = (listing[folded] ?? []).filter { name in
                identity(folder + "/" + name).map { !sources.contains($0) } ?? false
            }
            if !isValidName(rename.newName) || rename.newName.utf8.count > Int(NAME_MAX) {
                fail(rename.path, "“\(rename.newName)” is not a valid name.")
            } else if !seen.insert(folder + "/" + folded).inserted {
                fail(rename.path, "Another item would also be named “\(rename.newName)”.")
            } else if let clash = clashes.first {
                fail(rename.path, "An item named “\(clash)” is already there.")
            } else {
                continue
            }
            fine = false
        }
        return fine
    }
}
