import BlitterCore
import Foundation

/// A message for the user that stays in the window until dismissed.
public struct Notice: Identifiable, Equatable, Sendable {
    public let id: Int
    public let text: String
}

/// The settings file: read at launch and again whenever it changes (its folder is watched like
/// any shown folder). Problems in it become one notice, replaced on every read; the settings
/// themselves never stop the app — whatever is invalid keeps its default.
extension Workspace {
    var settingsFolder: String? {
        settingsFile.map { ($0 as NSString).deletingLastPathComponent }
    }

    func loadSettings() {
        guard let path = settingsFile else {
            return
        }
        settingsWork?.cancel()
        settingsWork = Task { [weak self] in
            let result: (settings: Settings, problems: [String])
            do {
                result = try await Self.readSettings(path)
            } catch {
                result = (Settings(), ["The settings file could not be read: \(error.localizedDescription)"])
            }
            guard !Task.isCancelled, let self else {
                return
            }
            settingsWork = nil
            apply(result.settings, problems: result.problems)
        }
    }

    /// Off the main actor: reading and parsing the file.
    private nonisolated static func readSettings(_ path: String) async throws
        -> (settings: Settings, problems: [String])
    {
        guard let text = try await TextFiles.read(path) else {
            return (Settings(), []) // no file: all defaults
        }
        return Settings.parse(text)
    }

    private func apply(_ newSettings: Settings, problems: [String]) {
        var changed = false
        if newSettings != settings {
            settings = newSettings
            changed = true
        }
        let text = problems.isEmpty ? nil : "Settings file: " + problems.joined(separator: " ")
        if text != settingsNotice?.text {
            if let old = settingsNotice {
                notices.removeAll { $0.id == old.id }
                settingsNotice = nil
            }
            if let text {
                settingsNotice = addNotice(text)
            }
            changed = true
        }
        if changed {
            notifyChange()
        }
    }

    func openWithApp(_ app: String, _ paths: [String], title: String) -> Bool {
        guard !paths.isEmpty else {
            return false
        }
        system.openWithApp(app, paths) { [weak self] message in
            self?.addNotice("\(title): \(message)")
            self?.notifyChange()
        }
        return false
    }

    @discardableResult
    func addNotice(_ text: String) -> Notice {
        nextNoticeID += 1
        let notice = Notice(id: nextNoticeID, text: text)
        notices.append(notice)
        return notice
    }

    func dismissNotice(_ id: Int) -> Bool {
        guard notices.contains(where: { $0.id == id }) else {
            return false
        }
        notices.removeAll { $0.id == id }
        if settingsNotice?.id == id {
            settingsNotice = nil
        }
        return true
    }

    /// Creates the file with the commented defaults if there is none (never overwrites), then
    /// opens it for editing. Saving it is enough: the change is picked up by the watcher.
    func openSettingsFile() -> Bool {
        guard let path = settingsFile else {
            return false
        }
        Task { [weak self] in
            do {
                try await TextFiles.createIfMissing(path, contents: Settings.defaultFile)
            } catch {
                self?.addNotice("The settings file could not be created: \(error.localizedDescription)")
                self?.notifyChange()
                return
            }
            guard let self else {
                return
            }
            system.editText(path)
            updateWatchedFolders() // its folder may only exist now
            loadSettings()
        }
        return false
    }
}
