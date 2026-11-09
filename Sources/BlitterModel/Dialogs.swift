/// A dialog or window the app is asked to show for a path (#42). The kinds are the Model's; the
/// app registers a window for each one it has, so a later module adds kinds without the Model
/// knowing its windows.
public struct DialogRequest: Equatable, Sendable {
    public let kind: String
    public let path: String

    public init(kind: String, path: String) {
        self.kind = kind
        self.path = path
    }

    /// The Git Log for a working copy, file or folder (#42).
    public static let gitLog = "git-log"
    /// Fetch, pull and push for the working copy a path is in (#43).
    public static let gitSync = "git-sync"
    /// Commit (and push) the changes of the working copy a path is in (#44).
    public static let gitCommit = "git-commit"
    /// Clone a repository into a folder (#70).
    public static let gitClone = "git-clone"
}

extension Workspace {
    func present(_ request: DialogRequest) -> Bool {
        system.present(request)
        return false
    }
}
