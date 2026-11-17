import BlitterCore
import Foundation

/// Select Differences (#108): on each side, what the other side lacks or has older — so F5 on
/// either side copies just those. It compares the two listings as shown (hidden files and the
/// fast filter as they are), never the disk, so it is instant.
/// - A name only on one side is selected there; names match ignoring case, as APFS does.
/// - A file on both sides is selected where it is newer by more than `tolerance` (FAT, SMB and
///   others round dates), or on both sides if the dates match but the sizes differ.
/// - A folder (a package too) on both sides is never selected: F5 would replace it whole, not
///   merge into it — comparing what is inside is a sync's job (#106).
extension Workspace {
    /// Two seconds: the coarsest dates a volume Blitter meets keeps (FAT).
    nonisolated static let dateTolerance: TimeInterval = 2

    func selectDifferences() -> Bool {
        let (left, right) = (state(of: .left), state(of: .right))
        guard left.status == .loaded, right.status == .loaded, left.find == nil, right.find == nil else {
            return false // search results are no folder to compare (#108 review)
        }
        let (leftEntries, rightEntries) = (left.visibleEntries.map(\.entry), right.visibleEntries.map(\.entry))
        // What was compared: a result counts only while both sides still show exactly these
        // listings — not another folder, a search, or a reload that changed them (#108 review).
        let compared = (left.entriesVersion, right.entriesVersion)
        differenceWork?.cancel()
        differenceWork = Task { [weak self] in
            let found = await Self.differences(leftEntries, rightEntries)
            guard let self, let found, !Task.isCancelled else {
                return
            }
            differenceWork = nil
            let (left, right) = (state(of: .left), state(of: .right))
            guard left.entriesVersion == compared.0, right.entriesVersion == compared.1,
                  left.find == nil, right.find == nil
            else {
                return // the listings changed meanwhile: what was found is not about them any more
            }
            _ = select(.left, found.left)
            _ = select(.right, found.right)
            notifyChange()
        }
        return false
    }

    /// Off the main actor, stopping when cancelled (nil then): `differences` in steps.
    nonisolated static func differences(_ left: [DirectoryEntry],
                                        _ right: [DirectoryEntry]) async -> (left: Set<String>, right: Set<String>)?
    {
        differences(left, right, cancelled: { Task.isCancelled })
    }

    /// The names to select on each side.
    nonisolated static func differences(_ left: [DirectoryEntry], _ right: [DirectoryEntry],
                                        tolerance: TimeInterval = dateTolerance)
        -> (left: Set<String>, right: Set<String>)
    {
        differences(left, right, tolerance: tolerance, cancelled: { false }) ?? ([], [])
    }

    /// `cancelled` is asked every 1024 entries; once it says so, nil.
    nonisolated static func differences(_ left: [DirectoryEntry], _ right: [DirectoryEntry],
                                        tolerance: TimeInterval = dateTolerance, cancelled: () -> Bool)
        -> (left: Set<String>, right: Set<String>)?
    {
        func key(_ name: String) -> String {
            name.precomposedStringWithCanonicalMapping.lowercased()
        }
        let rightByName = Dictionary(right.map { (key($0.name), $0) }, uniquingKeysWith: { first, _ in first })
        var (onLeft, onRight) = (Set<String>(), Set<String>())
        var matched = Set<String>()
        for (index, entry) in left.enumerated() {
            if index % 1024 == 0, cancelled() {
                return nil
            }
            let name = key(entry.name)
            guard let other = rightByName[name] else {
                onLeft.insert(entry.name) // only here
                continue
            }
            matched.insert(name)
            guard entry.kind != .directory, other.kind != .directory else {
                continue // a folder on both sides: not compared
            }
            let newer = entry.modificationDate.timeIntervalSince(other.modificationDate)
            if newer > tolerance {
                onLeft.insert(entry.name)
            } else if newer < -tolerance {
                onRight.insert(other.name)
            } else if entry.size != other.size {
                onLeft.insert(entry.name)
                onRight.insert(other.name)
            }
        }
        for entry in right where !matched.contains(key(entry.name)) {
            onRight.insert(entry.name) // only there
        }
        return (onLeft, onRight)
    }
}
