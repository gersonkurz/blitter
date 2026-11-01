import AppKit
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

/// Reads an open menu's titles and closes it.
@MainActor
final class MenuReader {
    let menu: NSMenu
    var titles: [String]?
    private(set) lazy var timer = Timer(timeInterval: 0.1, repeats: true) { [weak self] _ in
        MainActor.assumeIsolated {
            guard let self, self.titles == nil, !self.menu.items.isEmpty else {
                return
            }
            self.titles = self.menu.items.map { $0.isSeparatorItem ? "-" : $0.title }
            self.menu.cancelTracking()
        }
    }

    init(_ menu: NSMenu) {
        self.menu = menu
    }
}
