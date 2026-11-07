import Foundation

/// Whether names matching a pattern join the selection or leave it.
public enum PatternSelectionMode: Sendable {
    case select
    case deselect
}

// MARK: Select by pattern

/// Selecting by name pattern: "*.jpg", or several patterns separated by ";" ("*.jpg; *.png").
/// A pattern with a wildcard matches the whole name, one without matches anywhere in it,
/// ignoring case and accents (as in Find, #48). For search results, the name of the item itself
/// is matched, not its path below the folder.
extension Workspace {
    /// Adds the matching items to the selection or removes them, after matching in the background.
    /// Any navigation or new search cancels it (`dropViewWork`); a reload meanwhile does
    /// not, and only names still listed are applied. Folders take part only if `includesFolders`.
    func selectByPattern(_ side: Side, _ text: String, _ mode: PatternSelectionMode,
                         includesFolders: Bool = true) -> Bool
    {
        let patterns = text.split(separator: ";").map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        guard let state = sides[side], state.status == .loaded, !patterns.isEmpty else {
            return false
        }
        let names = state.visibleEntries.lazy.filter { includesFolders || $0.entry.kind != .directory }
            .map(\.entry.name)
        patternWork[side]?.cancel()
        patternWork[side] = Task { [weak self] in
            let matched = await Self.names(Array(names), matchingAnyOf: patterns)
            guard !Task.isCancelled, let self else {
                return // a newer request replaced it
            }
            patternWork[side] = nil
            guard let now = sides[side] else {
                return
            }
            // Checked against the listing as it is now: a reload meanwhile may have turned a
            // matched file into a folder of the same name (#56 review).
            let listed = matched.filter { name in
                now.listed(name).map { includesFolders || $0.entry.kind != .directory } ?? false
            }
            let selection = mode == .select ? now.selection.union(listed) : now.selection.subtracting(listed)
            if select(side, selection) {
                notifyChange()
            }
        }
        return false // the selection changes when the matching is done
    }

    /// The side goes elsewhere or starts a search: what was measured (#52) and a select by
    /// pattern still matching (#53) were for what it showed.
    func dropViewWork(_ side: Side) {
        dropFolderSizes(side)
        patternWork[side]?.cancel()
        patternWork[side] = nil
    }

    /// Off the main actor, stopping when cancelled.
    nonisolated static func names(_ names: [String], matchingAnyOf patterns: [String]) async -> Set<String> {
        let matchers = patterns.map { QuickFilter.Matcher($0, wholeName: true) }
        var matched: Set<String> = []
        for (index, name) in names.enumerated() {
            if index % 1024 == 0, Task.isCancelled {
                return []
            }
            let own = name.contains("/") ? (name as NSString).lastPathComponent : name
            if matchers.contains(where: { $0.matches(own) }) {
                matched.insert(name)
            }
        }
        return matched
    }
}
