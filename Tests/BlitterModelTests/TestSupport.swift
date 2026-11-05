import BlitterCore
@testable import BlitterModel
import Foundation
import Synchronization
import Testing

extension Workspace {
    /// Waits until no read of any kind is pending. A finished read can start new ones (a listing
    /// reveals the folder in the tree, which reads its parents), so this repeats until idle.
    func settle() async {
        for _ in 0 ..< 20 {
            let pending = Array(rootsWork.values) + Array(pendingOpen.values) + Array(pendingWork.values)
                + [settingsWork, fontSizeSave].compactMap(\.self) + Array(gitWork.values)
                + treeWork.values.flatMap(\.values) + Array(highlightWork.values)
                + Array(schemeWork.values) + Array(findWork.values) + Array(freeSpaceWork.values)
                + Array(folderSizeWork.values) + Array(patternWork.values)
            guard !pending.isEmpty else {
                return
            }
            for task in pending {
                await task.value
            }
        }
        Issue.record("the workspace did not settle")
    }
}

/// Records which folders the workspace wants watched; tests report changes by calling
/// `Workspace.foldersChanged` directly, so nothing depends on FSEvents timing.
final class FakeWatcher: FolderWatching {
    private let folders = Mutex<Set<String>>([])
    private let calls = Mutex(0)

    var watched: Set<String> {
        folders.withLock { $0 }
    }

    /// How often the set was handed over, the same set again included.
    var watchCalls: Int {
        calls.withLock { $0 }
    }

    func watch(_ paths: Set<String>) {
        folders.withLock { $0 = paths }
        calls.withLock { $0 += 1 }
    }

    static func factory(_: @escaping @Sendable ([FolderChange]) -> Void) -> any FolderWatching {
        FakeWatcher()
    }
}

/// A temporary folder that is deleted when the test finishes.
final class TemporaryFolder {
    let path: String

    init() throws {
        path = NSTemporaryDirectory() + "BlitterModelTests-" + UUID().uuidString
        try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: false)
    }

    deinit {
        try? FileManager.default.removeItem(atPath: path)
    }
}
