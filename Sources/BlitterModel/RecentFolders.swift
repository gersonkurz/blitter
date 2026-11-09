import Foundation

/// A side's recent folders (#74): every folder it went to, counted, with when it was last there,
/// and the folders pinned to the strip. The strip lists the pinned ones first, then the others by
/// frecency: how often, weighted by how recently. Saved with the window state.
public struct RecentFolders: Codable, Equatable, Sendable {
    public struct Visit: Codable, Equatable, Sendable {
        public var count: Int
        public var last: Date
    }

    public internal(set) var visits: [String: Visit] = [:]
    /// In the order they were pinned.
    public internal(set) var pinned: [String] = []

    /// Folders remembered; the least frecent go first.
    static let limit = 100

    public init() {}

    mutating func visit(_ path: String, at date: Date) {
        visits[path, default: Visit(count: 0, last: date)].count += 1
        visits[path]?.last = date
        guard visits.count > Self.limit else {
            return
        }
        // Never the folder just visited (a new one would score least and could never stay, #74
        // review), never a pinned one; among equal scores the one visited longest ago.
        let keep = Set(pinned + [path])
        if let least = visits.filter({ !keep.contains($0.key) }).min(by: { lhs, rhs in
            let (left, right) = (Self.score(lhs.value, at: date), Self.score(rhs.value, at: date))
            return left != right ? left < right : lhs.value.last < rhs.value.last
        }) {
            visits[least.key] = nil
        }
    }

    mutating func pin(_ path: String) {
        if !pinned.contains(path) {
            pinned.append(path)
        }
    }

    mutating func unpin(_ path: String) {
        pinned.removeAll { $0 == path }
    }

    /// Forgotten: neither recent nor pinned any more.
    mutating func remove(_ path: String) {
        visits[path] = nil
        unpin(path)
    }

    /// The strip's folders: the pinned ones, then the others by frecency (ties: the most recent),
    /// without `current`.
    public func ordered(at date: Date, without current: String) -> [String] {
        let pins = Set(pinned)
        let others = visits.filter { $0.key != current && !pins.contains($0.key) }.sorted { lhs, rhs in
            let (left, right) = (Self.score(lhs.value, at: date), Self.score(rhs.value, at: date))
            return left != right ? left > right : lhs.value.last > rhs.value.last
        }
        return pinned.filter { $0 != current } + others.map(\.key)
    }

    /// Visits weighted by how long ago the last one was.
    static func score(_ visit: Visit, at date: Date) -> Double {
        let days = date.timeIntervalSince(visit.last) / 86400
        let weight: Double = switch days {
        case ..<4: 100
        case ..<14: 70
        case ..<31: 50
        case ..<90: 30
        default: 10
        }
        return Double(visit.count) * weight
    }
}

// MARK: Commands

/// What the strip's menu does to a folder (#74).
public enum RecentFolderChange: Sendable {
    case pin, unpin, remove
}

extension Workspace {
    func changeRecentFolder(_ side: Side, _ path: String, _ change: RecentFolderChange) -> Bool {
        guard let before = sides[side]?.recentFolders else {
            return false
        }
        switch change {
        case .pin: sides[side]?.recentFolders.pin(path)
        case .unpin: sides[side]?.recentFolders.unpin(path)
        case .remove: sides[side]?.recentFolders.remove(path)
        }
        return sides[side]?.recentFolders != before
    }
}

public extension Workspace {
    /// The side's recent folders strip as it is now (the side's own folder left out).
    func recentFolders(of side: Side) -> [String] {
        let state = state(of: side)
        return state.recentFolders.ordered(at: clock(), without: state.location)
    }
}
