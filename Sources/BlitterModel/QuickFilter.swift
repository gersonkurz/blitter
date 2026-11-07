import Foundation

/// The file list's fast filter (#39): typing highlights the items that match; starting with `*`
/// filters the list down to them. It belongs to the side and ends when the side goes to another
/// folder.
public struct QuickFilter: Equatable, Sendable {
    public enum Mode: Equatable, Sendable {
        /// Every item stays; the matching ones are marked and the first of them selected.
        case highlight
        /// Only the matching items are listed.
        case filter
    }

    public var text: String
    public var mode: Mode

    public init(_ text: String, mode: Mode) {
        self.text = text
        self.mode = mode
    }

    /// Whether `name` contains the text, ignoring case and accents. `*` stands for any number
    /// of characters, `?` for one. No text matches everything.
    public func matches(_ name: String) -> Bool {
        Matcher(text).matches(name)
    }

    /// The text prepared once, for matching many names (a whole folder, off the main thread).
    struct Matcher {
        private let pattern: [Character]

        /// `wholeName` (Find, #48): text with a wildcard is matched against the whole name, so
        /// `*.swift` means names ending in ".swift"; text without one still matches anywhere.
        init(_ text: String, wholeName: Bool = false) {
            let folded = Array(Self.fold(text))
            if wholeName, folded.contains(where: { $0 == "*" || $0 == "?" }) {
                pattern = folded
            } else {
                pattern = ["*"] + folded + ["*"] // anywhere in the name: as if surrounded by `*`
            }
        }

        private static func fold(_ text: String) -> String {
            text.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: nil)
        }

        func matches(_ name: String) -> Bool {
            Self.glob(pattern, Array(Self.fold(name)))
        }

        /// Wildcard matching without recursion: on a mismatch, the last `*` takes one more
        /// character. Linear in practice; never exponential.
        private static func glob(_ pattern: [Character], _ name: [Character]) -> Bool {
            var patternIndex = 0
            var nameIndex = 0
            var star: (pattern: Int, name: Int)?
            while nameIndex < name.count {
                if patternIndex < pattern.count, pattern[patternIndex] == "*" {
                    star = (patternIndex, nameIndex)
                    patternIndex += 1
                } else if patternIndex < pattern.count,
                          pattern[patternIndex] == "?" || pattern[patternIndex] == name[nameIndex]
                {
                    patternIndex += 1
                    nameIndex += 1
                } else if let last = star {
                    star = (last.pattern, last.name + 1)
                    patternIndex = last.pattern + 1
                    nameIndex = last.name + 1
                } else {
                    return false
                }
            }
            return pattern[patternIndex...].allSatisfy { $0 == "*" }
        }
    }
}

extension Workspace {
    /// Sets the side's fast filter, or ends it (nil). An empty text in highlight mode is no
    /// filter at all; in filter mode it lists everything until something is typed.
    func setQuickFilter(_ side: Side, _ filter: QuickFilter?) -> Bool {
        let filter = filter?.mode == .highlight && filter?.text.isEmpty == true ? nil : filter
        guard let state = sides[side], state.quickFilter != filter else {
            return false
        }
        sides[side]?.quickFilter = filter
        // A key press asks for the first match; the request stands until a match is selected,
        // also across a listing that arrives meanwhile (#39 review).
        sides[side]?.selectsFirstMatch = filter?.mode == .highlight
        if state.listFilter != sides[side]?.listFilter {
            relist(side)
        }
        updateHighlights(side)
        return true
    }

    /// Selects the next (or previous) highlighted item after the selected one, wrapping around.
    func selectQuickFilterMatch(_ side: Side, forward: Bool) -> Bool {
        // The highlights may still be those of the listing before (a search is running): the
        // listing can be empty meanwhile.
        guard let state = sides[side], state.quickFilter?.mode == .highlight, !state.highlighted.isEmpty,
              !state.visibleEntries.isEmpty
        else {
            return false
        }
        let entries = state.visibleEntries
        let current = entries.firstIndex { state.selection.contains($0.entry.name) }
        let start = current ?? (forward ? entries.count - 1 : 0)
        for step in 1 ... entries.count {
            let index = ((forward ? start + step : start - step) % entries.count + entries.count) % entries.count
            if state.highlighted.contains(entries[index].entry.name) {
                return select(side, [entries[index].entry.name])
            }
        }
        return false
    }

    /// Finds the highlighted names off the main thread: a big folder takes a noticeable time,
    /// and every key press starts over (the previous search is cancelled). Also after every
    /// listing, as the names may have changed. An outstanding key press selects the first match.
    func updateHighlights(_ side: Side) {
        cancelHighlightSearch(side)
        guard let state = sides[side], let filter = state.quickFilter, filter.mode == .highlight else {
            if sides[side]?.highlighted.isEmpty == false {
                sides[side]?.highlighted = [] // the caller notifies
            }
            return
        }
        let names = state.visibleEntries.map(\.entry.name)
        highlightWork[side] = Task { [weak self] in
            let matched = await Self.matching(names, filter.text)
            // Still the same filter: navigation or a newer key press may have ended this one.
            guard !Task.isCancelled, let self, sides[side]?.quickFilter == filter else {
                return
            }
            highlightWork[side] = nil
            sides[side]?.highlighted = Set(matched)
            if sides[side]?.selectsFirstMatch == true, let first = matched.first {
                _ = select(side, [first]) // which ends the request
            }
            notifyChange()
        }
    }

    func cancelHighlightSearch(_ side: Side) {
        highlightWork[side]?.cancel()
        highlightWork[side] = nil
    }

    /// The names that match, in list order; off the main actor, stopping when cancelled.
    private nonisolated static func matching(_ names: [String], _ text: String) async -> [String] {
        let matcher = QuickFilter.Matcher(text)
        var matched: [String] = []
        for (index, name) in names.enumerated() {
            if index % 1024 == 0, Task.isCancelled {
                return []
            }
            if matcher.matches(name) {
                matched.append(name)
            }
        }
        return matched
    }
}

extension SideState {
    /// The filter the listing applies: only in filter mode.
    var listFilter: String? {
        quickFilter?.mode == .filter ? quickFilter?.text : nil
    }
}
