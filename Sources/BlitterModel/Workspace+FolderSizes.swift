import BlitterCore
import Foundation

/// A folder's size in the list (#52): being measured, or measured.
public enum FolderSize: Equatable, Sendable {
    case measuring
    case measured(Int64)

    public var bytes: Int64? {
        if case let .measured(bytes) = self {
            return bytes
        }
        return nil
    }
}

// MARK: Folder sizes (#52)

/// Sizes are measured on demand, on a GCD thread of the side's own (a slow volume blocks only
/// it), one folder after the other; results come in batches. They stay while the side shows the
/// folder, across reloads too, and go when it navigates or starts a search.
extension Workspace {
    /// Measures the selected folders, or all folders listed when nothing is selected. A new
    /// request replaces one still running; its folders are measured again.
    func measureFolders(_ side: Side) -> Bool {
        guard let state = sides[side], state.status == .loaded else {
            return false
        }
        let folders = (state.selection.isEmpty ? state.visibleEntries : state.selectedEntries)
            .filter { $0.entry.kind == .directory }.map(\.entry.name)
        guard !folders.isEmpty else {
            return false
        }
        stopMeasuring(side)
        for name in folders {
            sides[side]?.folderSizes[name] = .measuring
        }
        let location = state.entriesLocation
        let stop = CancellationFlag()
        folderSizeStops[side] = stop
        let batches = Self.measured(folders, in: location, cancelled: stop, measure: measureFolder)
        folderSizeWork[side] = Task { [weak self] in
            await withTaskCancellationHandler {
                for await batch in batches {
                    guard !Task.isCancelled else {
                        return
                    }
                    self?.foldersMeasured(side, batch, in: location)
                }
            } onCancel: {
                stop.set()
            }
            guard !Task.isCancelled, let self else {
                return
            }
            folderSizeWork[side] = nil
            folderSizeStops[side] = nil
        }
        return true
    }

    /// Stops the side's measuring; folders not measured yet lose their "measuring" mark.
    func stopMeasuring(_ side: Side) {
        folderSizeStops[side]?.set()
        folderSizeWork[side]?.cancel()
        folderSizeWork[side] = nil
        folderSizeStops[side] = nil
        if let sizes = sides[side]?.folderSizes {
            sides[side]?.folderSizes = sizes.filter { $0.value != .measuring }
        }
    }

    /// Stops measuring and forgets the sizes: the side goes elsewhere.
    func dropFolderSizes(_ side: Side) {
        stopMeasuring(side)
        sides[side]?.folderSizes = [:]
    }

    /// Sizes stay for every folder still in the listing, also one the fast filter or the hidden
    /// toggle leaves out for now (#52 review); a folder that is gone loses its size. Only looks
    /// at the listing when there are sizes.
    static func keepingListedFolders(_ sizes: [String: FolderSize],
                                     in entries: [DirectoryEntry]) -> [String: FolderSize]
    {
        guard !sizes.isEmpty else {
            return sizes
        }
        let folders = Set(entries.lazy.filter { $0.kind == .directory }.map(\.name))
        return sizes.filter { folders.contains($0.key) }
    }

    /// A result counts only for a folder still waiting for it: one that went meanwhile (deleted,
    /// so pruned by a reload) or whose request was replaced gets nothing back (#52 review).
    private func foldersMeasured(_ side: Side, _ batch: [(String, Int64)], in location: String) {
        guard let state = sides[side], state.entriesLocation == location else {
            return
        }
        for (name, bytes) in batch where state.folderSizes[name] == .measuring {
            sides[side]?.folderSizes[name] = .measured(bytes)
        }
        // The rows stay where they are, even when sorted by size: nothing moves under the cursor
        // (#57). Sorting again, or a reload, puts the folders in size order.
        notifyChange()
    }

    /// The folders measured one after the other, handed over at most every `interval` seconds.
    static func measured(_ names: [String], in location: String, cancelled: CancellationFlag,
                         measure: @escaping @Sendable (String, CancellationFlag) -> Int64?,
                         interval: TimeInterval = 0.2) -> AsyncStream<[(String, Int64)]>
    {
        AsyncStream { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                var batch: [(String, Int64)] = []
                var lastYield = Date()
                for name in names {
                    guard let bytes = measure(Paths.appending(name, to: location), cancelled) else {
                        break
                    }
                    batch.append((name, bytes))
                    if Date().timeIntervalSince(lastYield) >= interval {
                        continuation.yield(batch)
                        batch = []
                        lastYield = Date()
                    }
                }
                if !batch.isEmpty {
                    continuation.yield(batch)
                }
                continuation.finish()
            }
        }
    }
}
