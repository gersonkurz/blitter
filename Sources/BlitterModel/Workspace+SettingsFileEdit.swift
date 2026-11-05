import BlitterCore
import Darwin

/// Changing the settings file from Blitter (#63, #64): a font size zoomed, the Settings window
/// saved. Whatever an editor saves meanwhile is never lost.
extension Workspace {
    /// Off the main actor: creates the file if needed, reads it, makes the new text with
    /// `transform`, and swaps it in. If what the swap replaced is not what the text was made
    /// from (an editor saved meanwhile), that text was kept in a file beside the settings file;
    /// it is transformed and swapped in next, and its file is deleted once that swap confirms
    /// it is in place. Files whose text could not be brought in stay, and the notice names them.
    /// `transform` returns nil for a text it must not change (`refusal` says why). Returns the
    /// problem, if any, as a notice, and whether the file was created.
    nonisolated static func editSettingsFile(
        _ path: String, what: String, beforeReplace: (@Sendable () -> Void)?, refusal: String,
        _ transform: @Sendable (String) -> String?
    ) async -> (String?, Bool) {
        var created = false
        var kept: [String] = [] // other versions, newest last
        do {
            created = try await TextFiles.read(path) == nil
            try await TextFiles.createIfMissing(path, contents: Settings.defaultFile)
            var basis = try await TextFiles.read(path) ?? "" // the newest text that is not ours
            var inPlace = basis // what the file holds, as far as we know
            for _ in 0 ..< 3 {
                guard let edited = transform(basis) else {
                    return (kept.isEmpty ? "The \(what) could not be saved: \(refusal)" : conflict(kept, what), created)
                }
                if edited == basis, basis == inPlace {
                    return (nil, created)
                }
                beforeReplace?()
                switch try await TextFiles.swap(path, contents: edited, expecting: inPlace) {
                case .replacedExpected:
                    if let incorporated = kept.popLast() { // its text, changed, is in the file now
                        unlink(incorporated)
                    }
                    return (kept.isEmpty ? nil : conflict(kept, what), created)
                case let .replacedOther(text, keptAt):
                    kept.append(keptAt)
                    guard let text else {
                        return (conflict(kept, what), created) // not UTF-8: only a person can sort it out
                    }
                    basis = text
                    inPlace = edited
                }
            }
            return (conflict(kept, what), created)
        } catch {
            let problem = "The \(what) could not be saved: \(error.localizedDescription)"
            return (kept.isEmpty ? problem : problem + " " + conflict(kept, what), created)
        }
    }

    private nonisolated static func conflict(_ kept: [String], _ what: String) -> String {
        "The settings file changed while the \(what) was saved into it; the other version is kept in " +
            kept.joined(separator: ", ") + "."
    }
}
