import BlitterCore
import BlitterModel
import Foundation

func folder(_ name: String) -> DirectoryEntry {
    DirectoryEntry(name: name, kind: .directory, size: 0, modificationDate: .distantPast, isHidden: false,
                   isDataless: false, error: 0)
}

func file(_ name: String) -> DirectoryEntry {
    DirectoryEntry(name: name, kind: .file, size: 1, modificationDate: .distantPast, isHidden: false,
                   isDataless: false, error: 0)
}

/// The app tests drive the UI with fake folders; nothing is watched.
final class FakeWatcher: FolderWatching {
    func watch(_: Set<String>) {}

    static func factory(_: @escaping @Sendable ([FolderChange]) -> Void) -> any FolderWatching {
        FakeWatcher()
    }
}
