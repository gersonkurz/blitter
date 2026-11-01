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
    /// Give an item a new name in the same folder.
    case rename(String, newName: String)
    /// Create a folder.
    case newFolder(parent: String, name: String)
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
}
