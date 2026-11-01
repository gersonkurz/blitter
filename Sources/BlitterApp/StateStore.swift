import BlitterModel
import Foundation

/// Keeps the workspace state for the next launch in the user defaults. Saved whenever it changes,
/// so even a crash loses nothing; writes only when something actually changed.
@MainActor
final class StateStore {
    private let defaults: UserDefaults
    private let key = "WorkspaceState"
    private var lastSaved: WorkspaceState?
    private(set) var writes = 0

    /// Tests pass a defaults domain of their own: the test host shares the app's defaults.
    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func load() -> WorkspaceState? {
        guard let data = defaults.data(forKey: key) else {
            return nil
        }
        let state = try? JSONDecoder().decode(WorkspaceState.self, from: data)
        lastSaved = state
        return state
    }

    func save(_ state: WorkspaceState) {
        guard state != lastSaved, let data = try? JSONEncoder().encode(state) else {
            return
        }
        defaults.set(data, forKey: key)
        lastSaved = state
        writes += 1
    }
}
