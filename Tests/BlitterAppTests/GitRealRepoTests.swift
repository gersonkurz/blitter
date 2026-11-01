import AppKit
@testable import Blitter
@testable import BlitterCore
@testable import BlitterModel
import Testing

/// Git colors with the real git, on a real working copy, in a real file list (#22): every
/// folder with changes red, the clean one not.
@MainActor
@Suite(.serialized)
final class GitRealRepoTests {
    private let folder: TemporaryRepo
    private let workspace: Workspace
    private let controller: FileListViewController
    private let window: NSWindow

    init() async throws {
        folder = try TemporaryRepo()
        workspace = Workspace(initialLocation: folder.root, home: folder.root, volumes: { [] },
                              watcher: FakeWatcher.factory)
        controller = FileListViewController(workspace: workspace, side: .left)
        window = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 600, height: 400),
                          styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentViewController = controller
        workspace.onChange = { [controller] in controller.render() }
        window.makeKeyAndOrderFront(nil)
        for _ in 0 ..< 500 where workspace.gitState(ofFolder: folder.root) == nil {
            try await Task.sleep(for: .milliseconds(10))
        }
        controller.render()
        controller.view.layoutSubtreeIfNeeded()
    }

    isolated deinit {
        window.close()
    }

    /// #35, TortoiseGit style: tracked changes red, tracked and unchanged green, untracked and
    /// ignored uncolored - files as well as folders.
    @Test func trackedChangesRedTrackedCleanGreenUntrackedUncolored() throws {
        #expect(workspace.gitState(ofFolder: folder.root) == .modified)
        for name in ["modified", "deep", "changed.txt"] {
            #expect(try color(name) == .systemRed, "\(name)")
        }
        for name in ["clean", "README.md"] {
            #expect(try color(name) == .systemGreen, "\(name)")
        }
        for name in ["untracked", "new.txt", "build", "conf", "empty"] {
            let shown = try color(name)
            #expect(shown != .systemGreen && shown != .systemRed, "\(name)")
        }
    }

    private func color(_ name: String) throws -> NSColor {
        let row = try #require(controller.entries.firstIndex { $0.entry.name == name }, "\(name) listed")
        let cell = controller.tableView.view(atColumn: 0, row: row, makeIfNecessary: true) as? NSTableCellView
        return try #require(cell?.textField?.textColor)
    }
}

/// A git working copy in a temporary folder: modified/, untracked/, deep/a/b (a change two
/// levels down) and clean/.
final class TemporaryRepo {
    let root: String

    init() throws {
        let git = try #require(Git.executable, "no git on this Mac")
        root = FolderWatcher.realPath(NSTemporaryDirectory()) + "/BlitterGit-" + UUID().uuidString
        let files = ["modified/m.txt", "clean/c.txt", "deep/a/b/d.txt", "changed.txt", "README.md"]
        for file in files {
            let path = root + "/" + file
            try FileManager.default.createDirectory(atPath: (path as NSString).deletingLastPathComponent,
                                                    withIntermediateDirectories: true)
            try "x".write(toFile: path, atomically: true, encoding: .utf8)
        }
        try Self.run(git, ["init", "-q", "-b", "main"], in: root)
        try Self.run(git, ["add", "."], in: root)
        try Self.run(git, ["-c", "user.name=T", "-c", "user.email=t@example.invalid", "commit", "-q", "-m", "1"],
                     in: root)
        try "changed".write(toFile: root + "/modified/m.txt", atomically: true, encoding: .utf8)
        try "changed".write(toFile: root + "/deep/a/b/d.txt", atomically: true, encoding: .utf8)
        try "changed".write(toFile: root + "/changed.txt", atomically: true, encoding: .utf8)
        try "new".write(toFile: root + "/new.txt", atomically: true, encoding: .utf8)
        try FileManager.default.createDirectory(atPath: root + "/build", withIntermediateDirectories: false)
        try "o".write(toFile: root + "/build/out.o", atomically: true, encoding: .utf8)
        try FileManager.default.createDirectory(atPath: root + "/conf", withIntermediateDirectories: false)
        try "secret".write(toFile: root + "/conf/local.json", atomically: true, encoding: .utf8)
        try FileManager.default.createDirectory(atPath: root + "/empty", withIntermediateDirectories: false)
        try "build/\nconf/local.json\n".write(toFile: root + "/.git/info/exclude", atomically: true, encoding: .utf8)
        try FileManager.default.createDirectory(atPath: root + "/untracked", withIntermediateDirectories: false)
        try "u".write(toFile: root + "/untracked/u.txt", atomically: true, encoding: .utf8)
    }

    deinit {
        try? FileManager.default.removeItem(atPath: root)
    }

    private static func run(_ git: String, _ arguments: [String], in folder: String) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: git)
        process.arguments = ["-C", folder] + arguments
        process.standardOutput = FileHandle.nullDevice
        let errors = Pipe()
        process.standardError = errors
        try process.run()
        let message = String(bytes: errors.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        process.waitUntilExit()
        // A failed setup says so here, not later as a puzzling color.
        try #require(process.terminationStatus == 0, "git \(arguments.joined(separator: " ")): \(message)")
    }
}
