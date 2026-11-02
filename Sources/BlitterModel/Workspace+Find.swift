import BlitterCore
import Foundation

/// Find (#48): a search below a side's folder, shown on that side as a folder of its own, so
/// normal commands work on the results. While a side shows one, `load` runs the search again
/// instead of reading the folder: refreshing, a job that changed something below it and showing
/// hidden items all go through there. Changes the folder watcher reports do not: a search of a
/// busy tree (the home folder) would walk it again and again; its results are a snapshot.
extension Workspace {
    /// Searches below the side's folder (or the folder its search was in) for names matching
    /// `pattern` (as the fast filter does; with a wildcard, the whole name). Back returns to the
    /// folder. An empty pattern ends the search.
    func find(_ side: Side, _ pattern: String) -> Bool {
        guard var state = sides[side] else {
            return false
        }
        let text = pattern.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else {
            return endFind(side)
        }
        if state.find == nil { // Back leaves the results for the folder
            state.backStack.append(state.location)
            state.forwardStack.removeAll()
        }
        state.find = FindState(root: state.location, pattern: text)
        state.selection = []
        state.renameRequest = nil
        state.quickFilter = nil
        state.highlighted = []
        state.selectsFirstMatch = false
        state.pendingSelection = nil
        state.pendingAction = nil
        sides[side] = state
        cancelHighlightSearch(side)
        runFind(side, fresh: true)
        return true
    }

    /// Stops the walk; what it found so far stays.
    func stopFind(_ side: Side) -> Bool {
        guard sides[side]?.find?.isRunning == true else {
            return false
        }
        findStops[side]?.set() // the walk ends with what it has, which is then shown
        return false
    }

    /// Back to the searched folder's own listing.
    private func endFind(_ side: Side) -> Bool {
        guard let state = sides[side], let find = state.find else {
            return false
        }
        return state.backStack.last == find.root ? go(side, .back) : go(side, .path(find.root))
    }

    /// Ends the side's search when it goes somewhere: its walk is stopped and its results dropped.
    func leaveFind(_ side: Side) {
        findWork[side]?.cancel()
        findWork[side] = nil
        findStops[side] = nil
        sides[side]?.find = nil
    }

    /// Runs the side's search. `fresh`: a new search, whose results show as they come; otherwise
    /// (run again) the old results stay until the new ones are complete.
    func runFind(_ side: Side, fresh: Bool) {
        guard let state = sides[side], let find = state.find else {
            return
        }
        findWork[side]?.cancel()
        pendingWork[side]?.cancel() // a listing of the folder must not land on the results
        pendingWork[side] = nil
        sides[side]?.find?.isRunning = true
        if fresh {
            sides[side]?.status = .loading
            sides[side]?.allEntries = []
            sides[side]?.visibleEntries = []
            sides[side]?.visibleIndex = [:]
            sides[side]?.entriesVersion += 1
        }
        let (root, matcher, includeHidden) = (find.root, QuickFilter.Matcher(find.pattern, wholeName: true),
                                              showsHiddenFiles)
        let stop = CancellationFlag()
        findStops[side] = stop
        findWork[side] = Task { [weak self] in
            let batches = AsyncStream<FindBatch> { continuation in
                DispatchQueue.global(qos: .userInitiated).async {
                    FileFind.walk(root: root, matcher: matcher, includeHidden: includeHidden, cancelled: stop) {
                        continuation.yield($0)
                    }
                    continuation.finish()
                }
            }
            var found: [DirectoryEntry] = []
            var last = FindBatch()
            await withTaskCancellationHandler {
                for await batch in batches {
                    found += batch.entries
                    last = batch
                    guard !Task.isCancelled else {
                        return
                    }
                    self?.findProgressed(side, batch, found: fresh ? found : nil, final: false)
                }
            } onCancel: {
                stop.set()
            }
            guard !Task.isCancelled, let self else {
                return
            }
            findWork[side] = nil
            findStops[side] = nil
            sides[side]?.find?.isRunning = false
            findProgressed(side, last, found: found, final: true)
        }
    }

    /// Shows how far the walk got and, if given, the results so far: filtered and sorted off the
    /// main thread like a listing. While results are still being sorted, the next batches only
    /// count (sorts must not pile up on a big search); the `final` one always replaces them.
    private func findProgressed(_ side: Side, _ batch: FindBatch, found: [DirectoryEntry]?, final: Bool) {
        guard let state = sides[side], state.find != nil else {
            return
        }
        sides[side]?.find?.foldersSearched = batch.foldersSearched
        sides[side]?.find?.unreadableFolders = batch.unreadableFolders
        guard let found, final || pendingWork[side] == nil else {
            notifyChange()
            return
        }
        let (showHidden, sort, filter) = (showsHiddenFiles, state.sort, state.listFilter)
        startWork(on: side, location: state.location) {
            Listing.Result(all: found, visible: Listing.visibleEntries(found, showHidden: showHidden, sort: sort,
                                                                       filter: filter))
        }
        notifyChange()
    }
}
