@testable import Blitter
import BlitterModel
import Foundation
import Testing

/// A defaults domain of its own: the test host is the app, and shares the app's real defaults.
@MainActor
final class StateStoreTests {
    private let suite = "Blitter.tests." + UUID().uuidString
    private let defaults: UserDefaults

    init() throws {
        defaults = try #require(UserDefaults(suiteName: suite))
    }

    isolated deinit {
        defaults.removePersistentDomain(forName: suite)
    }

    private let state = WorkspaceState(left: .init(location: "/a", sort: ListSort(column: .size, ascending: false)),
                                       right: .init(location: "/b", sort: ListSort()), showsHiddenFiles: true)

    private func windows(_ states: WorkspaceState...) -> [SavedWindow] {
        states.enumerated().map { SavedWindow(state: $1, frame: "\($0 * 20) 0 800 600 0 0 1440 900 ") }
    }

    /// #96: every window, in order, with where it was.
    @Test func savedWindowsAreLoadedByTheNextLaunch() {
        var other = state
        other.left.location = "/c"
        StateStore(defaults: defaults).save(windows(state, other))
        #expect(StateStore(defaults: defaults).load() == windows(state, other))
    }

    @Test func savingWritesOnlyWhenSomethingChanged() {
        let store = StateStore(defaults: defaults)
        store.save(windows(state))
        store.save(windows(state))
        store.save(windows(state))
        #expect(store.writes == 1)
        var changed = state
        changed.showsHiddenFiles = false
        store.save(windows(changed))
        #expect(store.writes == 2)
        store.save(windows(changed, state)) // a window more
        #expect(store.writes == 3)

        let next = StateStore(defaults: defaults) // a later launch: loading counts as saved
        _ = next.load()
        next.save(windows(changed, state))
        #expect(next.writes == 0)
    }

    /// The single window's state from before #96 is read when there is nothing newer, and the
    /// first window's is still written there for an older Blitter.
    @Test func theSingleWindowStateOfBeforeStillCounts() throws {
        try defaults.set(JSONEncoder().encode(state), forKey: "WorkspaceState")
        #expect(StateStore(defaults: defaults).load() == [SavedWindow(state: state, frame: nil)])

        var other = state
        other.left.location = "/c"
        StateStore(defaults: defaults).save(windows(other, state))
        let single = try JSONDecoder().decode(WorkspaceState.self,
                                              from: #require(defaults.data(forKey: "WorkspaceState")))
        #expect(single == other)
    }

    @Test func nothingOrSomethingUnreadableMeansNoState() {
        #expect(StateStore(defaults: defaults).load().isEmpty)
        defaults.set(Data("not json".utf8), forKey: "WorkspaceState")
        defaults.set(Data("not json".utf8), forKey: "Windows")
        #expect(StateStore(defaults: defaults).load().isEmpty)
    }
}
