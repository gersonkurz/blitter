import BlitterModel
import Foundation

/// One main window as saved for the next launch (#96): its sides, and where it was.
struct SavedWindow: Codable, Equatable {
    var state: WorkspaceState
    /// `NSWindow.frameDescriptor`; nil: the window's usual place.
    var frame: String?
}

/// Keeps the main windows' states for the next launch in the user defaults. Saved whenever they
/// change, so even a crash loses nothing; writes only when something actually changed.
@MainActor
final class StateStore {
    private let defaults: UserDefaults
    /// Every window (#96), in the order they were opened.
    private let key = "Windows"
    /// The single window's state before #96: read when there is nothing newer, and still written
    /// with the first window's, so an older Blitter finds its window.
    private let singleKey = "WorkspaceState"
    private var lastSaved: [SavedWindow]?
    private(set) var writes = 0

    /// Tests pass a defaults domain of their own: the test host shares the app's defaults.
    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    /// The windows of the last session, oldest first; empty if there is nothing readable.
    func load() -> [SavedWindow] {
        let windows = read([SavedWindow].self, key).flatMap { $0.isEmpty ? nil : $0 }
            ?? read(WorkspaceState.self, singleKey).map { [SavedWindow(state: $0, frame: nil)] }
            ?? []
        lastSaved = windows.isEmpty ? nil : windows
        return windows
    }

    private func read<Value: Decodable>(_: Value.Type, _ key: String) -> Value? {
        defaults.data(forKey: key).flatMap { try? JSONDecoder().decode(Value.self, from: $0) }
    }

    func save(_ windows: [SavedWindow]) {
        guard windows != lastSaved, let data = try? JSONEncoder().encode(windows) else {
            return
        }
        defaults.set(data, forKey: key)
        if let first = windows.first, let single = try? JSONEncoder().encode(first.state) {
            defaults.set(single, forKey: singleKey)
        }
        lastSaved = windows
        writes += 1
    }
}
