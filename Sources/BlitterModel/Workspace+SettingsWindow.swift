import BlitterCore
import Foundation
import TOMLKit

/// What the Settings window (#64) edits: the settings file as written, nothing resolved (a
/// downloaded scheme stays a name).
public struct SettingsDocument: Equatable, Sendable {
    public let settings: Settings
    /// What is wrong in the file: those entries have their defaults here, and saving writes them so.
    public let problems: [String]
    /// False if the file cannot be read as a whole (not TOML, not text): saving would replace
    /// everything in it, so the window does not.
    public let canBeSaved: Bool
}

public extension Settings {
    /// These settings with what changed from `original` to `edited` — entry by entry — and
    /// everything else as it is: an entry changed in the file meanwhile (a zoom, an editor)
    /// stays unless the window changed that entry too.
    func applying(changesFrom original: Settings, to edited: Settings) -> Settings {
        var result = self
        func take(_ entry: WritableKeyPath<Settings, some Equatable>) {
            if original[keyPath: entry] != edited[keyPath: entry] {
                result[keyPath: entry] = edited[keyPath: entry]
            }
        }
        take(\.dateFormat)
        for column in ListColumn.allCases where original.columns.contains(column) != edited.columns.contains(column) {
            if edited.columns.contains(column) {
                result.columns.insert(column)
            } else {
                result.columns.remove(column)
            }
        }
        take(\.diffTool)
        take(\.confirmDelete)
        take(\.gitColors)
        take(\.tools)
        take(\.contextMenus)
        take(\.menuBar)
        take(\.font.face)
        take(\.font.mono)
        take(\.font.size)
        take(\.theme.light)
        take(\.theme.dark)
        for role in ThemeRole.allCases { // each role is a setting of its own
            take(\.theme.slots[role])
        }
        for name in Set(original.theme.schemes.keys).union(edited.theme.schemes.keys) {
            take(\.theme.schemes[name])
        }
        return result
    }

    /// The problems a text written from these settings would have: none, unless something
    /// was entered that the file cannot hold (an empty date pattern, a diff command without
    /// {left}, a scheme name that is none).
    var problems: [String] {
        Settings.parse(Settings.fileText(self)).problems
    }
}

public extension Workspace {
    /// The settings file for the Settings window. No file yet: the defaults.
    func readSettingsDocument() async -> SettingsDocument {
        guard let path = settingsFile else {
            return SettingsDocument(settings: settings, problems: [], canBeSaved: false)
        }
        return await Self.document(at: path)
    }

    /// Off the main actor: reading and parsing the file.
    private nonisolated static func document(at path: String) async -> SettingsDocument {
        let text: String?
        do {
            text = try await TextFiles.read(path)
        } catch {
            return SettingsDocument(settings: Settings(), problems: [
                "The settings file could not be read: \(error.localizedDescription)",
            ], canBeSaved: false)
        }
        guard let text else {
            return SettingsDocument(settings: Settings(), problems: [], canBeSaved: true)
        }
        let (settings, problems) = Settings.parse(text)
        return SettingsDocument(
            settings: settings,
            problems: problems,
            canBeSaved: (try? TOMLTable(string: text)) != nil
        )
    }
}

extension Workspace {
    /// Writes what the window changed (`original` → `edited`) into the file as it is now: a
    /// zoom still waiting is saved first, then the file is read, the changes applied entry by
    /// entry, and the whole file written from the result (comments are Blitter's own). A file
    /// that does not parse is never written. Problems become a notice; on success the settings
    /// are read again at once.
    func saveSettings(from original: Settings, to edited: Settings) -> Bool {
        guard let path = settingsFile, original != edited else {
            return false
        }
        settingsSaveGeneration += 1
        let generation = settingsSaveGeneration
        let previous = settingsSave
        let beforeReplace = settingsFileBeforeReplace
        settingsSave = Task { [weak self] in
            await previous?.value // saves run one after the other, in order
            guard let self else {
                return
            }
            await finishSavingFontSize()
            let (problem, created) = await Self.editSettingsFile(
                path, what: "settings", beforeReplace: beforeReplace,
                refusal: "the settings file has errors that make it unreadable as a whole; fix them in a text editor."
            ) { text in
                guard (try? TOMLTable(string: text)) != nil else {
                    return nil
                }
                let merged = Settings.parse(text).settings.applying(changesFrom: original, to: edited)
                return Settings.fileText(merged)
            }
            if created {
                updateWatchedFolders(retry: true) // its folder may only exist now
            }
            if let problem {
                addNotice(problem)
                notifyChange()
            }
            loadSettings() // at once, not when the watcher reports it
            lastSettingsSaveProblem = problem
            if generation == settingsSaveGeneration { // no newer save queued behind this one
                settingsSave = nil
            }
        }
        return false
    }
}

public extension Workspace {
    /// Waits for the settings saves under way; the problem of the last one, nil if it worked.
    func finishSavingSettings() async -> String? {
        while let save = settingsSave {
            await save.value
            if settingsSave == save { // ended without clearing (its workspace is gone)
                break
            }
        }
        return lastSettingsSaveProblem
    }

    /// Whether something is still to be written into the settings file: a zoomed size, a save.
    var isSavingSettings: Bool {
        pendingFontSize != nil || settingsSave != nil
    }

    /// Writes everything still to be written; the app waits for this before it quits.
    func finishSaving() async {
        await finishSavingFontSize()
        _ = await finishSavingSettings()
    }
}
