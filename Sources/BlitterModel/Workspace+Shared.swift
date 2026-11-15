import BlitterCore
import Foundation

/// The state every window shares (#96) lives in `AppModel`; a window's workspace reads and
/// changes it here, as if it were its own. What changes it for one window changes it for all:
/// `settings` tells every window, and `notifyChange` (LiveUpdates) has every window look again.
public extension Workspace {
    /// The user's configuration; defaults until the settings file has been read. A change
    /// reaches every window (`settingsChanged`).
    internal(set) var settings: Settings {
        get { app.settings }
        set {
            let old = app.settings
            app.settings = newValue
            for workspace in app.workspaces {
                workspace.settingsChanged(from: old)
            }
        }
    }

    /// The colors the Settings window shows in every window (#93); nil: the settings' own.
    internal(set) var themeTrial: ThemeSettings? {
        get { app.themeTrial }
        set { app.themeTrial = newValue }
    }

    /// Messages for the user that stay until dismissed, e.g. problems in the settings file.
    internal(set) var notices: [Notice] {
        get { app.notices }
        set { app.notices = newValue }
    }

    /// A zoomed font size not yet in the settings file (#63).
    internal(set) var pendingFontSize: Double? {
        get { app.pendingFontSize }
        set { app.pendingFontSize = newValue }
    }

    /// How often the settings were read.
    internal(set) var settingsReads: Int {
        get { app.settingsReads }
        set { app.settingsReads = newValue }
    }

    /// How to undo the jobs done, oldest first (#61).
    internal(set) var undoJournal: [UndoEntry] {
        get { app.undoJournal }
        set { app.undoJournal = newValue }
    }

    /// Every action the user can run, by id (#15), built from the settings' tools.
    internal(set) var actionRegistry: ActionRegistry {
        get { app.actionRegistry }
        set { app.actionRegistry = newValue }
    }

    /// How a color scheme is downloaded (#34); tests replace it.
    var fetch: @Sendable (URL) async throws -> Data {
        get { app.fetch }
        set { app.fetch = newValue }
    }
}

extension Workspace {
    /// Another window (#96); the app makes it, sharing this window's `app`.
    func openWindow(at folder: String) -> Bool {
        system.openWindow(folder)
        return false
    }

    var settingsFile: String? {
        app.settingsFile
    }

    var settingsWork: Task<Void, Never>? {
        get { app.settingsWork }
        set { app.settingsWork = newValue }
    }

    var nextNoticeID: Int {
        get { app.nextNoticeID }
        set { app.nextNoticeID = newValue }
    }

    var settingsNotice: Notice? {
        get { app.settingsNotice }
        set { app.settingsNotice = newValue }
    }

    var fontSizeSave: Task<Void, Never>? {
        get { app.fontSizeSave }
        set { app.fontSizeSave = newValue }
    }

    var fontSizeSaveGeneration: Int {
        get { app.fontSizeSaveGeneration }
        set { app.fontSizeSaveGeneration = newValue }
    }

    var fontSizeSaveDelay: Duration {
        get { app.fontSizeSaveDelay }
        set { app.fontSizeSaveDelay = newValue }
    }

    var settingsFileBeforeReplace: (@Sendable () -> Void)? {
        get { app.settingsFileBeforeReplace }
        set { app.settingsFileBeforeReplace = newValue }
    }

    var settingsSave: Task<Void, Never>? {
        get { app.settingsSave }
        set { app.settingsSave = newValue }
    }

    var settingsSaveGeneration: Int {
        get { app.settingsSaveGeneration }
        set { app.settingsSaveGeneration = newValue }
    }

    var lastSettingsSaveProblem: String? {
        get { app.lastSettingsSaveProblem }
        set { app.lastSettingsSaveProblem = newValue }
    }

    var stateFavorites: [String] {
        get { app.stateFavorites }
        set { app.stateFavorites = newValue }
    }

    var pendingFavorites: [String]? {
        get { app.pendingFavorites }
        set { app.pendingFavorites = newValue }
    }

    var favoritesSave: Task<Void, Never>? {
        get { app.favoritesSave }
        set { app.favoritesSave = newValue }
    }

    var favoritesSaves: Int {
        get { app.favoritesSaves }
        set { app.favoritesSaves = newValue }
    }

    var schemeWork: [String: Task<Void, Never>] {
        get { app.schemeWork }
        set { app.schemeWork = newValue }
    }

    var jobQueue: JobQueue {
        app.jobQueue
    }

    var nextUndoID: Int {
        get { app.nextUndoID }
        set { app.nextUndoID = newValue }
    }

    var runningUndo: Int? {
        get { app.runningUndo }
        set { app.runningUndo = newValue }
    }
}
