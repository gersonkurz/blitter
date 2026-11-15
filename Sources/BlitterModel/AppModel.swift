import BlitterCore
import Foundation

/// What all of Blitter's windows share (#96): the settings and everything written to or read
/// from the settings file, the notices, the colors being tried, the jobs and their undo journal,
/// and the actions the settings' tools make. Each window's `Workspace` keeps its own sides,
/// trees, watcher and git states, and reaches this through `Workspace+Shared`.
///
/// A change anywhere is a change for every window: `notifyAll` tells each one.
@MainActor
public final class AppModel {
    /// The windows' workspaces, oldest first; a closed window's goes when it is released.
    private var windows: [Weak] = []

    // MARK: Settings

    /// The user's configuration; defaults until the settings file has been read.
    var settings = Settings()
    /// The settings file, or nil to use the defaults only (tests).
    let settingsFile: String?
    var settingsWork: Task<Void, Never>?
    /// How often the settings were read: the Settings window reads the file again when it
    /// changed and nothing is edited.
    var settingsReads = 0
    /// The colors the Settings window shows in every window (#93): its draft's, from when it has
    /// read the file until it closes. Nil: the settings' own.
    var themeTrial: ThemeSettings?
    /// A zoomed font size not yet in the settings file (#63), and the saves writing it there,
    /// one after the other.
    var pendingFontSize: Double?
    var fontSizeSave: Task<Void, Never>?
    var fontSizeSaveGeneration = 0
    /// How long zooming must pause before the size is saved: a wheel zooms in many steps.
    var fontSizeSaveDelay: Duration = .milliseconds(500)
    /// Tests: runs between reading the settings file and replacing it (a zoom's or the Settings
    /// window's save), as an editor's save might.
    var settingsFileBeforeReplace: (@Sendable () -> Void)?
    /// The Settings window's saves (#64).
    var settingsSave: Task<Void, Never>?
    var settingsSaveGeneration = 0
    var lastSettingsSaveProblem: String?
    /// Favorites from the window state (the file's list wins), one not yet saved there, its save (#72).
    var stateFavorites: [String]
    var pendingFavorites: [String]?
    var favoritesSave: Task<Void, Never>?
    var favoritesSaves = 0
    /// Color schemes being fetched, by the name the settings give them (#34), and how.
    var schemeWork: [String: Task<Void, Never>] = [:]
    var fetch: @Sendable (URL) async throws -> Data = Downloads.fetch
    /// Every action the user can run, by id (#15), built from the settings' tools.
    var actionRegistry = ActionRegistry(tools: Tool.defaults)

    // MARK: Notices

    /// Messages for the user that stay until dismissed, e.g. problems in the settings file.
    var notices: [Notice] = []
    var nextNoticeID = 0
    var settingsNotice: Notice?

    // MARK: Jobs

    /// File operations in the background, of every window: each window's strip shows them all.
    let jobQueue: JobQueue
    /// How to undo the jobs done, oldest first (#61); whichever window started a job, and
    /// whichever undoes it, it is one journal, as in the Finder.
    var undoJournal: [UndoEntry] = []
    var nextUndoID = 0
    /// The undo job running, if any (#61).
    var runningUndo: Int?

    init(settingsFile: String?, jobs: JobQueue, favorites: [String]) {
        self.settingsFile = settingsFile
        jobQueue = jobs
        stateFavorites = favorites
        jobs.onChange = { [weak self] in self?.notifyAll() }
        jobs.onFinish = { [weak self] job in self?.jobFinished(job) }
    }

    /// The windows' workspaces, oldest first.
    var workspaces: [Workspace] {
        windows.compactMap(\.workspace)
    }

    func add(_ workspace: Workspace) {
        windows.removeAll { $0.workspace == nil }
        windows.append(Weak(workspace: workspace))
    }

    /// Every window looks again.
    func notifyAll() {
        for workspace in workspaces {
            workspace.onChange?()
        }
    }

    /// A job ended: its undo is recorded once, each window reads again what it changed (and the
    /// window that started it does what it asked for afterwards), and a job that worked leaves
    /// the strips.
    private func jobFinished(_ job: Job) {
        let all = workspaces
        all.first?.recordUndo(of: job)
        for workspace in all {
            workspace.jobFinished(job)
        }
        if job.state == .finished, job.errors.isEmpty {
            jobQueue.dismiss(job.id)
        }
        notifyAll()
    }

    private struct Weak {
        weak var workspace: Workspace?
    }
}
