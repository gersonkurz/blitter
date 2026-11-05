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
        let beforeReplace = fontSizeBeforeReplace
        fontSizeSave = Task { [weak self] in
            try? await Task.sleep(for: delay)
            await previous?.value
            guard let self, generation == fontSizeSaveGeneration, let size = pendingFontSize else {
                return // a newer zoom saves
            }
            let (problem, created) = await Self.write(fontSize: size, to: path, beforeReplace: beforeReplace)
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

    /// Off the main actor: read, change the one line, swap the result in. If what the swap
    /// replaced is not what the edit was made from (an editor saved meanwhile), that text was
    /// kept in a file beside the settings file; it is edited and swapped in next, and its file
    /// is deleted once that swap confirms it is in place. Files whose text could not be brought
    /// in stay, and the notice names them. Returns the problem, if any, as a notice, and whether
    /// the file was created.
    private nonisolated static func write(fontSize size: Double, to path: String,
                                          beforeReplace: (@Sendable () -> Void)?) async -> (String?, Bool)
    {
        var created = false
        var kept: [String] = [] // other versions, newest last
        do {
            created = try await TextFiles.read(path) == nil
            try await TextFiles.createIfMissing(path, contents: Settings.defaultFile)
            var basis = try await TextFiles.read(path) ?? "" // the newest text that is not ours
            var inPlace = basis // what the file holds, as far as we know
            for _ in 0 ..< 3 {
                guard let edited = Settings.settingFontSize(size, in: basis) else {
                    return (kept.isEmpty ? "The font size could not be saved: the settings file sets it in a way " +
                        "only a text editor can change; change [font] size there." : conflict(kept), created)
                }
                if edited == basis, basis == inPlace {
                    return (nil, created)
                }
                beforeReplace?()
                switch try await TextFiles.swap(path, contents: edited, expecting: inPlace) {
                case .replacedExpected:
                    if let incorporated = kept.popLast() { // its text, with the size, is in the file now
                        unlink(incorporated)
                    }
                    return (kept.isEmpty ? nil : conflict(kept), created)
                case let .replacedOther(text, keptAt):
                    kept.append(keptAt)
                    guard let text else {
                        return (conflict(kept), created) // not UTF-8: only a person can sort it out
                    }
                    basis = text
                    inPlace = edited
                }
            }
            return (conflict(kept), created)
        } catch {
            let problem = "The font size could not be saved: \(error.localizedDescription)"
            return (kept.isEmpty ? problem : problem + " " + conflict(kept), created)
        }
    }

    private nonisolated static func conflict(_ kept: [String]) -> String {
        "The settings file changed while the font size was saved into it; the other version is kept in " +
            kept.joined(separator: ", ") + "."
    }
}
