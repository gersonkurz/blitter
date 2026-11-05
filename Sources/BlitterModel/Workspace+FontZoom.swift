import BlitterCore
import Foundation

/// Zooming the lists' and trees' font (#63): one size for both sides, shown at once and saved as
/// `[font] size` in the settings file — only that line changes, the rest of the file and its
/// comments stay as they are.
public enum FontZoom: Sendable {
    case larger, smaller, actualSize
}

extension Workspace {
    func zoomFont(_ zoom: FontZoom) -> Bool {
        let sizes = FontSettings.sizes
        let size = switch zoom {
        case .larger: min(settings.font.size.rounded(.down) + 1, sizes.upperBound)
        case .smaller: max(settings.font.size.rounded(.up) - 1, sizes.lowerBound)
        case .actualSize: FontSettings().size
        }
        guard size != settings.font.size else {
            return false
        }
        settings.font.size = size
        pendingFontSize = size
        saveFontSize()
        return true
    }

    /// Saves a zoomed size now instead of after the pause, and returns when it is in the file
    /// (or could not be saved). The app waits for this before it quits.
    public func finishSavingFontSize() async {
        guard pendingFontSize != nil, fontSizeSave != nil else {
            return
        }
        saveFontSize(after: .zero)
        await fontSizeSave?.value
    }

    /// After a pause, the newest size goes into the file. Saves run one after the other, and one
    /// that a newer zoom overtook writes nothing: the newer one cancels it, which only cuts its
    /// pause short (a write under way still completes; file access ignores cancellation).
    private func saveFontSize(after delay: Duration? = nil) {
        guard let path = settingsFile else {
            pendingFontSize = nil // the defaults only (tests): nothing to save
            return
        }
        fontSizeSaveGeneration += 1
        let generation = fontSizeSaveGeneration
        let previous = fontSizeSave
        previous?.cancel()
        let delay = delay ?? fontSizeSaveDelay
        let beforeReplace = settingsFileBeforeReplace
        fontSizeSave = Task { [weak self] in
            try? await Task.sleep(for: delay)
            await previous?.value
            guard let self, generation == fontSizeSaveGeneration, let size = pendingFontSize else {
                return // a newer zoom saves
            }
            let (problem, created) = await Self.editSettingsFile(
                path, what: "font size", beforeReplace: beforeReplace,
                refusal: "the settings file sets it in a way only a text editor can change; change [font] size there."
            ) { Settings.settingFontSize(size, in: $0) }
            if created {
                updateWatchedFolders(retry: true) // its folder may only exist now
            }
            if generation == fontSizeSaveGeneration { // no newer zoom meanwhile
                pendingFontSize = nil // the file has it now
                fontSizeSave = nil
            }
            if let problem {
                addNotice(problem)
                notifyChange()
            }
        }
    }
}
