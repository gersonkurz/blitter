import Foundation

/// A change to the file system that runs as a job.
public enum FileOperation: Equatable, Sendable {
    /// Copy items into a folder.
    case copy([String], into: String)
    /// Move items into a folder.
    case move([String], into: String)
    /// Move items to the Trash.
    case trash([String])
    /// Delete items for good, folders with everything in them: the one operation that bypasses
    /// the Trash, run only on the user's explicit request (#17).
    case delete([String])
    /// Run a command line in a folder (a tool, #30): the program first, then its arguments.
    case command([String], folder: String)
    /// Give an item a new name in the same folder.
    case rename(String, newName: String)
    /// Give several items new names, each in its own folder (batch rename): all or none, and
    /// names may be swapped or passed along ("a" → "b", "b" → "c").
    case renameAll([Rename])
    /// Create a folder.
    case newFolder(parent: String, name: String)
    /// Undo an earlier job (#61): its recorded steps, in the order they run.
    case undo([UndoStep])
    /// Remove exactly what a plan names (Git Clean, #71): to the Trash, or (`forGood`) for good.
    case removeExactly(RemovalPlan, forGood: Bool)
}

public extension FileOperation {
    /// The same operation on the outermost of its items: an item given together with a folder it
    /// is in (search results, #48, list both) goes along with that folder, and is not copied,
    /// moved or deleted a second time; an item given twice counts once. The order stays.
    /// "In" means inside on disk: only through real folders, never through a symbolic link
    /// (copying a link does not copy what it leads to), so `isRealFolder` is asked about each
    /// folder in between. It reads the disk by default: call this off the main thread.
    func withoutNestedItems(isRealFolder: (String) -> Bool = Self.isRealFolder) -> FileOperation {
        switch self {
        case let .copy(paths, folder): .copy(Self.outermost(paths, isRealFolder: isRealFolder), into: folder)
        case let .move(paths, folder): .move(Self.outermost(paths, isRealFolder: isRealFolder), into: folder)
        case let .trash(paths): .trash(Self.outermost(paths, isRealFolder: isRealFolder))
        case let .delete(paths): .delete(Self.outermost(paths, isRealFolder: isRealFolder))
        case .command, .rename, .renameAll, .newFolder, .undo, .removeExactly: self
        }
    }

    /// `paths` without repeats, and without those inside another of them through real folders.
    /// Set lookups find the nearest other item above each one; only then is the disk asked, about
    /// the folders between the two.
    static func outermost(_ paths: [String], isRealFolder: (String) -> Bool) -> [String] {
        let all = Set(paths)
        var kept: Set<String> = []
        return paths.filter { path in
            var between: [String] = []
            var folder = path
            while let slash = folder.lastIndex(of: "/"), slash != folder.startIndex {
                folder = String(folder[..<slash])
                between.append(folder)
                if all.contains(folder) {
                    if between.allSatisfy(isRealFolder) {
                        return false // it goes along with `folder`
                    }
                    break // behind a link: given on its own, it stays
                }
            }
            return kept.insert(path).inserted
        }
    }

    /// A folder, not a link to one.
    static func isRealFolder(_ path: String) -> Bool {
        var info = stat()
        return lstat(path, &info) == 0 && info.st_mode & S_IFMT == S_IFDIR
    }
}

/// One item of a batch rename.
public struct Rename: Equatable, Sendable {
    public let path: String
    public let newName: String

    public init(path: String, newName: String) {
        self.path = path
        self.newName = newName
    }
}

/// An item already exists where a copy or move wants to put one.
public struct Conflict: Equatable, Sendable {
    public let source: String
    public let existing: String
}

public enum ConflictDecision: Equatable, Sendable {
    /// The existing item goes to the Trash, then the new one takes its place.
    case replace
    case skip
    /// The new item gets a free name such as "report 2.txt".
    case keepBoth
}

public struct ConflictAnswer: Equatable, Sendable {
    public let decision: ConflictDecision
    /// Use the same decision for the job's remaining conflicts without asking.
    public let applyToAll: Bool

    public init(_ decision: ConflictDecision, applyToAll: Bool = false) {
        self.decision = decision
        self.applyToAll = applyToAll
    }
}

public struct JobError: Equatable, Sendable {
    public let path: String
    public let message: String
}

/// How far a job has come. `totalBytes` is nil while it is not known.
public struct JobProgress: Equatable, Sendable {
    public var totalItems = 0
    public var doneItems = 0
    public var totalBytes: Int64?
    public var doneBytes: Int64 = 0
    public var currentItem: String?
    /// A command job's output, stdout and stderr together as it came (#43): its last 64 KB.
    public var outputBytes = Data()

    /// `outputBytes` as text; a character cut at the start is dropped, anything not UTF-8 shows
    /// as "�".
    public var output: String {
        FileOperations.text(of: outputBytes)
    }

    static let outputLimit = 64 * 1024
}
