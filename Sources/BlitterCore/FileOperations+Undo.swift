import Foundation

/// One step of undoing a job (#61). A job records them as it does what they undo, so they name
/// what really happened: where a copy went ("report 2.txt" after Keep Both), where the Trash put
/// an item. Each names the item it acts on by its identity too: Undo acts only on that very item,
/// never on another one that took its path since. They run in the order given (the job's own
/// steps reversed).
public enum UndoStep: Equatable, Sendable {
    /// An item the job made (a copy, a new folder) goes to the Trash: never deleted for good.
    case trash(String, ItemIdentity)
    /// An item goes back where it was: a moved one, or one the job put in the Trash.
    case move(String, toPath: String, ItemIdentity)
    /// Renamed items get their old names back (a rename, or a batch rename as a whole); each
    /// rename's item by its identity, in the same order.
    case rename([Rename], [ItemIdentity])
    /// An empty folder that was removed is made again (Git Clean, #71), with the details
    /// (permissions, flags, extended attributes, ACL) kept on the folder at `details`.
    case makeFolder(String, details: String)

    /// The same step for items that are other items now (moved to another volume, #61 review):
    /// what it names by an old identity, it names by the new one.
    public func replacing(_ changes: [ItemIdentity: ItemIdentity]) -> UndoStep {
        switch self {
        case let .trash(path, identity): .trash(path, changes[identity] ?? identity)
        case let .move(path, target, identity): .move(path, toPath: target, changes[identity] ?? identity)
        case let .rename(renames, identities): .rename(renames, identities.map { changes[$0] ?? $0 })
        case .makeFolder: self
        }
    }

    /// The paths the step acts on now.
    public var paths: [String] {
        switch self {
        case let .trash(path, _): [path]
        case let .move(source, _, _): [source]
        case let .rename(renames, _): renames.map(\.path)
        case let .makeFolder(path, _): [path]
        }
    }
}

extension FileOperations {
    /// Records the step for the item now at `path` (its identity read now); nothing if there is
    /// no item there.
    mutating func recordTrash(_ path: String) {
        if let identity = Self.identity(path) {
            undoSteps.append(.trash(path, identity))
        }
    }

    mutating func recordMove(_ path: String, back original: String) {
        if let identity = Self.identity(path) {
            undoSteps.append(.move(path, toPath: original, identity))
        }
    }

    /// `renames`: each item's current path and the name it is to get back.
    mutating func recordRenames(_ renames: [Rename]) {
        let known = renames.compactMap { rename in Self.identity(rename.path).map { (rename, $0) } }
        if !known.isEmpty {
            undoSteps.append(.rename(known.map(\.0), known.map(\.1)))
        }
    }

    /// Every item at and below `path` by its path below it ("" for `path` itself). Only real
    /// folders are entered: a symbolic link, also `path` itself, counts as itself. A folder that
    /// cannot be read contributes only itself. Nil once the job is cancelled: it stops then.
    /// Tests watch each folder it reads through `sizingProbe`.
    func identities(below path: String) -> [String: ItemIdentity]? {
        var found: [String: ItemIdentity] = [:]
        var folders = [""]
        while let relative = folders.popLast() {
            guard !isCancelled else {
                return nil
            }
            let full = relative.isEmpty ? path : path + "/" + relative
            guard let identity = Self.identity(full) else {
                continue
            }
            found[relative] = identity
            guard FileOperation.isRealFolder(full) else {
                continue // a file, or a link to anything
            }
            sizingProbe?(context.cancellation)
            for entry in (try? listDirectory(full, cancelled: context.cancellation)) ?? [] {
                let child = relative.isEmpty ? entry.name : relative + "/" + entry.name
                if entry.kind == .directory {
                    folders.append(child)
                } else if let identity = Self.identity(path + "/" + child) {
                    found[child] = identity
                }
            }
        }
        return isCancelled ? nil : found
    }

    /// The items that were `before` (the original) are `after` (the copy) now, matched by path.
    mutating func recordReplaced(_ before: [String: ItemIdentity], by after: [String: ItemIdentity]) {
        for (relative, old) in before {
            if let new = after[relative], new != old {
                identityChanges[old] = new
            }
        }
    }

    /// Carries out undo steps. A step whose item is gone or is another item now, or whose old
    /// place is taken, is reported and left; nothing is ever overwritten, and the other steps
    /// still run.
    mutating func runUndo(_ steps: [UndoStep]) {
        context.update { $0.totalItems = steps.count }
        for step in steps {
            guard !isCancelled else {
                return
            }
            switch step {
            case let .trash(path, identity):
                context.update { $0.currentItem = (path as NSString).lastPathComponent }
                guard isStill(path, identity) else {
                    break
                }
                do {
                    _ = try trashItem(path)
                } catch {
                    fail(path, error.localizedDescription)
                }
            case let .move(source, target, identity):
                let name = (target as NSString).lastPathComponent
                context.update { $0.currentItem = name }
                guard isStill(source, identity) else {
                    break
                }
                if Self.exists(target) {
                    fail(target, "An item named “\(name)” is there again; it was left as it is.")
                } else {
                    moveItem(source, to: target)
                }
            case let .makeFolder(path, details):
                if mkdir(path, 0o700) != 0 { // private until its own details are on it
                    if !FileOperation.isRealFolder(path) {
                        fail(path, "The folder could not be made again: \(Self.message(errno))")
                    }
                } else if copyfile(details, path, nil, Staging.details) != 0 {
                    fail(path, "The folder was made again, but without its permissions and attributes.")
                }
            case let .rename(renames, identities):
                let still = zip(renames, identities).filter { isStill($0.0.path, $0.1) }.map(\.0)
                if !still.isEmpty {
                    renameAll(still)
                }
            }
            context.update { $0.doneItems += 1 }
        }
    }

    /// Whether the item Undo is to act on is still at `path`; if not, that is reported.
    private mutating func isStill(_ path: String, _ identity: ItemIdentity) -> Bool {
        guard let current = Self.identity(path) else {
            fail(path, "It is no longer there; Undo left it.")
            return false
        }
        guard current == identity else {
            fail(path, "Another item is there now; Undo left it as it is.")
            return false
        }
        return true
    }
}
