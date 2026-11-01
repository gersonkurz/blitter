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

    @Test func aSavedStateIsLoadedByTheNextLaunch() {
        StateStore(defaults: defaults).save(state)
        #expect(StateStore(defaults: defaults).load() == state)
    }

    @Test func savingWritesOnlyWhenSomethingChanged() {
        let store = StateStore(defaults: defaults)
        store.save(state)
        store.save(state)
        store.save(state)
        #expect(store.writes == 1)
        var changed = state
        changed.showsHiddenFiles = false
        store.save(changed)
        #expect(store.writes == 2)

        let next = StateStore(defaults: defaults) // a later launch: loading counts as saved
        _ = next.load()
        next.save(changed)
        #expect(next.writes == 0)
    }

    @Test func nothingOrSomethingUnreadableMeansNoState() {
        #expect(StateStore(defaults: defaults).load() == nil)
        defaults.set(Data("not json".utf8), forKey: "WorkspaceState")
        #expect(StateStore(defaults: defaults).load() == nil)
    }
}
