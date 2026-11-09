import BlitterCore
@testable import BlitterModel
import Foundation
import Testing

/// #74: each side's recent folders strip: pinned first, then by frecency; kept for the next launch.
@MainActor
struct RecentFoldersTests {
    private let day: TimeInterval = 86400

    @Test func pinnedFirstThenOftenAndRecent() {
        let now = Date(timeIntervalSince1970: 1_000_000_000)
        var recent = RecentFolders()
        for _ in 0 ..< 3 {
            recent.visit("/old-but-often", at: now - 100 * day) // 3 × 10
        }
        recent.visit("/twice-lately", at: now - day)
        recent.visit("/twice-lately", at: now - day) // 2 × 100
        recent.visit("/once-today", at: now) // 1 × 100
        recent.visit("/once-yesterday", at: now - day) // 1 × 100, older: after today's
        recent.visit("/here", at: now)
        recent.pin("/pinned")
        recent.pin("/old-but-often")
        #expect(recent.ordered(at: now, without: "/here") == [
            "/pinned", "/old-but-often", "/twice-lately", "/once-today", "/once-yesterday",
        ])
        recent.unpin("/old-but-often")
        #expect(recent.ordered(at: now, without: "/here").last == "/old-but-often")
        recent.remove("/pinned")
        #expect(!recent.ordered(at: now, without: "/here").contains("/pinned"))
    }

    @Test func theLeastFrecentGoFirstButNeverAPinnedOne() {
        let now = Date(timeIntervalSince1970: 1_000_000_000)
        var recent = RecentFolders()
        recent.visit("/pinned-but-old", at: now - 400 * day)
        recent.pin("/pinned-but-old")
        recent.visit("/old", at: now - 300 * day)
        for index in 0 ..< RecentFolders.limit - 1 {
            recent.visit("/f\(index)", at: now)
        }
        #expect(recent.visits.count == RecentFolders.limit)
        #expect(recent.visits["/old"] == nil && recent.visits["/pinned-but-old"] != nil)
    }

    /// A full history of often-visited folders: a new one still gets in, and stays for its next
    /// visits (#74 review).
    @Test func aNewFolderGetsInWhenTheHistoryIsFull() {
        let now = Date(timeIntervalSince1970: 1_000_000_000)
        var recent = RecentFolders()
        for index in 0 ..< RecentFolders.limit {
            for _ in 0 ..< 11 {
                recent.visit("/often\(index)", at: now - Double(index))
            }
        }
        for visit in 1 ... 3 {
            recent.visit("/new", at: now)
            #expect(recent.visits["/new"]?.count == visit)
        }
        #expect(recent.visits.count == RecentFolders.limit)
        #expect(recent.ordered(at: now, without: "/").contains("/new"))
    }

    /// Among equal scores the one visited longest ago goes, not a newer one (#74 review).
    @Test func amongEqualScoresTheOldestGoes() {
        let now = Date(timeIntervalSince1970: 1_000_000_000)
        var recent = RecentFolders()
        for index in 0 ..< RecentFolders.limit {
            recent.visit("/f\(index)", at: now - Double(RecentFolders.limit - index)) // f0 the oldest
        }
        recent.visit("/new", at: now)
        #expect(recent.visits["/f0"] == nil)
        #expect(recent.visits["/f1"] != nil && recent.visits["/new"] != nil)
    }

    private func makeWorkspace(restoring saved: WorkspaceState? = nil) async -> Workspace {
        let folders = FakeFolders(["/a": [], "/b": [], "/c": []])
        let workspace = Workspace(initialLocation: "/a", home: "/a", lister: folders.list,
                                  directoryCheck: folders.isDirectory, volumes: { [] }, watcher: FakeWatcher.factory,
                                  restoring: saved)
        await workspace.settle()
        return workspace
    }

    /// Going around: the folder a side started in counts too; the strip leaves out the folder the
    /// side shows; pins and visits are kept for the next launch.
    @Test func navigationFillsTheStripAndItIsKept() async throws {
        let workspace = await makeWorkspace()
        let ticks = Ticks()
        workspace.clock = { ticks.next() } // a second later each time: ties go to the later visit
        for folder in ["/b", "/c", "/b"] {
            workspace.perform(.navigate(.left, path: folder))
        }
        #expect(workspace.recentFolders(of: .left) == ["/c", "/a"]) // once each: /c later
        #expect(workspace.state(of: .left).recentFolders.visits["/b"]?.count == 2)
        workspace.perform(.recentFolder(.left, "/a", .pin))
        #expect(workspace.recentFolders(of: .left).first == "/a")
        #expect(workspace.recentFolders(of: .right).isEmpty) // each side its own

        let data = try JSONEncoder().encode(workspace.savedState)
        let restored = try await makeWorkspace(restoring: JSONDecoder().decode(WorkspaceState.self, from: data))
        #expect(restored.state(of: .left).recentFolders == workspace.state(of: .left).recentFolders)

        var changes = 0
        workspace.onChange = { changes += 1 }
        workspace.perform(.recentFolder(.left, "/a", .pin)) // already: nothing changes
        workspace.perform(.recentFolder(.left, "/zzz", .remove))
        #expect(changes == 0)
        workspace.perform(.recentFolder(.left, "/c", .remove))
        #expect(changes == 1 && !workspace.recentFolders(of: .left).contains("/c"))
    }

    /// A state saved before the strip existed still reads.
    @Test func anOlderStateStillReads() throws {
        let json = #"{"left":{"location":"/a","sort":{"column":"name","ascending":true}},"#
            + #""right":{"location":"/b","sort":{"column":"name","ascending":true}},"showsHiddenFiles":false}"#
        let state = try JSONDecoder().decode(WorkspaceState.self, from: Data(json.utf8))
        #expect(state.left.recentFolders == nil)
    }
}

final class Ticks: @unchecked Sendable {
    private let lock = NSLock()
    private var seconds: TimeInterval = 1_000_000_000

    /// A second later each time.
    func next() -> Date {
        lock.withLock {
            seconds += 1
            return Date(timeIntervalSince1970: seconds)
        }
    }
}
