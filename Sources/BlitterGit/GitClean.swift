import BlitterCore
import BlitterModel
import Foundation

/// What Git Clean asks of git and the disk; the real one asks them, tests use their own.
public struct GitCleanAccess: Sendable {
    /// `git clean -n` in a folder with `-d`, `-x` as asked; nil if git fails.
    public var preview: @Sendable (_ folder: String, _ folders: Bool, _ ignored: Bool,
                                   _ cancelled: CancellationFlag) -> GitCleanPreview?
    /// Whether a path is a real folder (not a file, not a link).
    public var isFolder: @Sendable (String) -> Bool

    public static let real = GitCleanAccess(
        preview: { Git.cleanPreview(in: $0, folders: $1, ignored: $2, cancelled: $3) },
        isFolder: isRealFolder
    )

    public init(preview: @escaping @Sendable (String, Bool, Bool, CancellationFlag) -> GitCleanPreview?,
                isFolder: @escaping @Sendable (String) -> Bool)
    {
        self.preview = preview
        self.isFolder = isFolder
    }

    @Sendable static func isRealFolder(_ path: String) -> Bool {
        var info = stat()
        return lstat(path, &info) == 0 && info.st_mode & S_IFMT == S_IFDIR
    }

    /// What a folder holds now, all the way down: its files (and links, not followed) and its
    /// folders, the folder itself included. Nil if one cannot be read: then nothing in it is
    /// offered for removal.
    static func contents(of folder: String, cancelled: CancellationFlag) -> (files: [String], folders: [String])? {
        var files: [String] = []
        var folders: [String] = []
        var pending = [folder]
        while let current = pending.popLast() {
            guard !cancelled.isSet, let entries = try? listDirectory(current, cancelled: cancelled) else {
                return nil
            }
            folders.append(current)
            for entry in entries {
                let path = current + "/" + entry.name
                if entry.kind == .directory {
                    pending.append(path)
                } else {
                    files.append(path)
                }
            }
        }
        return (files, folders)
    }
}

/// Git Clean (#71): what `git clean` would remove in a working copy's folder, always shown first
/// (a dry run), with untracked folders and ignored files as options. Removing goes through
/// Blitter's own jobs and takes exactly the items shown: to the Trash (undoable, #61), or deleted
/// for good once the user has agreed. Never `git clean -f`: files that turn up after the preview
/// are never touched.
@MainActor
public final class GitClean {
    /// The folder cleaned: the selected item if it is a folder, else its folder; nil until known.
    public private(set) var folder: String?
    /// Untracked folders too (`-d`).
    public var includesFolders = true {
        didSet { refresh() }
    }

    /// Ignored files too (`-x`).
    public var includesIgnored = false {
        didSet { refresh() }
    }

    /// What would go, as full paths (as git lists them: a folder as a whole); nil while it is read.
    public private(set) var items: [String]?
    /// What removing takes: the files, and the folders it removes once they are empty, each by
    /// its identity. Read with the preview, so what turns up later, also inside a listed folder,
    /// is never removed.
    private var removal: RemovalPlan?
    /// Nested repositories git leaves alone, as full paths.
    public private(set) var skippedRepositories: [String] = []
    /// Why the preview could not be read.
    public private(set) var problem: String?
    /// The Trash or delete job running.
    public private(set) var runningJob: Int?
    public var onChange: (() -> Void)?

    private let workspace: Workspace
    private let path: String
    private let access: GitCleanAccess
    private let work = BackgroundWork()

    public init(workspace: Workspace, path: String, access: GitCleanAccess = .real) {
        self.workspace = workspace
        self.path = path
        self.access = access
        refresh()
    }

    /// Whether there is something to remove now.
    public var canRemove: Bool {
        runningJob == nil && removal.map { !$0.isEmpty } == true
    }

    /// Reads the preview again (also after the options changed, or a job ended).
    public func refresh() {
        let (path, access, folders, ignored) = (path, access, includesFolders, includesIgnored)
        items = nil
        removal = nil // nothing to remove until the new list is read
        onChange?()
        work.run("preview") { cancelled -> Preview in
            Self.read(path, folders: folders, ignored: ignored, access: access, cancelled: cancelled)
        } then: { [weak self] preview in
            guard let self else {
                return
            }
            folder = preview.folder
            items = preview.items
            removal = preview.removal
            skippedRepositories = preview.skipped
            problem = preview.problem
            onChange?()
        }
    }

    /// The items shown go to the Trash, as one job (undoable).
    @discardableResult
    public func moveToTrash() -> Bool {
        removal.map { start(.removeExactly($0, forGood: false)) } ?? false
    }

    /// The items shown are deleted for good. The caller has asked the user (unless the settings
    /// say not to ask, as for Delete Immediately).
    @discardableResult
    public func deleteForGood() -> Bool {
        removal.map { start(.removeExactly($0, forGood: true)) } ?? false
    }

    /// Whether the user is to be asked before deleting for good.
    public var asksBeforeDeleting: Bool {
        workspace.settings.confirmDelete
    }

    private struct Preview: Sendable {
        var folder: String
        var items: [String] = []
        var removal: RemovalPlan?
        var skipped: [String] = []
        var problem: String?
    }

    /// Off the main thread: the folder, git's list, and what each listed folder holds now.
    private nonisolated static func read(_ path: String, folders: Bool, ignored: Bool, access: GitCleanAccess,
                                         cancelled: CancellationFlag) -> Preview
    {
        let folder = access.isFolder(path) ? path : (path as NSString).deletingLastPathComponent
        var result = Preview(folder: folder)
        guard let preview = access.preview(folder, folders, ignored, cancelled) else {
            result.problem = "Git could not tell what is untracked here."
            return result
        }
        var files: [String] = []
        var folders: [String] = []
        let relative = { (path: String) in String(path.dropFirst(folder.count + 1)) }
        for listed in preview.removed {
            let isFolder = listed.hasSuffix("/")
            let full = folder + "/" + (isFolder ? String(listed.dropLast()) : listed)
            guard isFolder else {
                result.items.append(full)
                files.append(relative(full))
                continue
            }
            guard let contents = GitCleanAccess.contents(of: full, cancelled: cancelled) else {
                continue // unreadable: not offered
            }
            result.items.append(full)
            files += contents.files.map(relative)
            folders += contents.folders.map(relative)
        }
        result.removal = RemovalPlan.read(root: folder, files: files, folders: folders)
        result.skipped = preview.skippedRepositories.map { folder + "/" + $0 }
        return result
    }

    private func start(_ command: Command) -> Bool {
        guard canRemove, let job = workspace.startJob(by: command) else {
            return false
        }
        runningJob = job
        workspace.whenJobDone(job) { [weak self] _ in
            self?.runningJob = nil
            self?.refresh() // what is left now
        }
        onChange?()
        return true
    }
}
