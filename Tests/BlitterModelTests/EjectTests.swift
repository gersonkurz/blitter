import BlitterCore
@testable import BlitterModel
import Foundation
import Testing

/// #84: Eject, for a side on a volume other than the startup disk, from the menus and the tree.
@MainActor
struct EjectTests {
    private let tree: [String: [DirectoryEntry]] = [
        "/": [entry("Users", .directory)],
        "/Users": [entry("me", .directory)],
        "/Users/me": [entry("notes.txt")],
        "/Volumes/Backup": [entry("2026", .directory)],
        "/Volumes/Backup/2026": [entry("photo.jpg")],
    ]

    private func makeWorkspace(at location: String, slow: Set<String> = []) async -> Workspace {
        let volumes = [
            MountedVolume(name: "Macintosh HD", path: "/", isLocal: true, isRoot: true),
            MountedVolume(name: "Backup", path: "/Volumes/Backup", isLocal: true, isRoot: false),
            // Not in `tree`: it cannot be listed (a broken or stalled disk).
            MountedVolume(name: "Broken", path: "/Volumes/Broken", isLocal: true, isRoot: false),
        ]
        let folders = FakeFolders(tree, slow: slow, delay: 5)
        let workspace = Workspace(initialLocation: location, home: "/Users/me", lister: folders.list,
                                  directoryCheck: folders.isDirectory, volumes: { volumes },
                                  watcher: FakeWatcher.factory)
        await workspace.settle()
        return workspace
    }

    @Test func onAVolumeItEjectsThatVolume() async {
        let workspace = await makeWorkspace(at: "/Volumes/Backup/2026")
        var ejected: [String] = []
        workspace.system.eject = { path, _ in ejected.append(path) }
        #expect(workspace.ejectableVolume(containing: "/Volumes/Backup/2026")?.title == "Backup")
        #expect(workspace.canRun("eject", on: .left))
        #expect(workspace.actions(for: .left).contains { $0.id == "eject" })
        workspace.perform(.runAction("eject", .left))
        #expect(ejected == ["/Volumes/Backup"])
    }

    @Test func notOnTheStartupDisk() async {
        let workspace = await makeWorkspace(at: "/Users/me")
        var ejected: [String] = []
        workspace.system.eject = { path, _ in ejected.append(path) }
        #expect(workspace.ejectableVolume(containing: "/Users/me") == nil)
        #expect(!workspace.canRun("eject", on: .left))
        #expect(!workspace.actions(for: .left).contains { $0.id == "eject" })
        workspace.perform(.runAction("eject", .left))
        workspace.perform(.eject("/")) // nor when asked directly
        workspace.perform(.eject("/Volumes/Backup/2026")) // only a volume itself
        #expect(ejected.isEmpty)
    }

    /// The tree's menu offers it on a volume (and folders on it), not elsewhere; the defaults
    /// have it in the folder menu and in the File menu as ⌘E.
    @Test func theTreeAndTheDefaultMenusOfferIt() async {
        let workspace = await makeWorkspace(at: "/Users/me")
        let eject = ShownMenuEntry.action(id: "eject", title: "Eject")
        #expect(workspace.treeContextMenu(for: "/Volumes/Backup").contains(eject))
        #expect(workspace.treeContextMenu(for: "/Volumes/Backup/2026").contains(eject))
        #expect(!workspace.treeContextMenu(for: "/Users/me").contains(eject))
        #expect(Settings().contextMenus.folder.contains(.action("eject")))
        #expect(Settings().menuBar.file.contains(.action("eject", shortcut: Shortcut("cmd+e"), alternate: false)))
    }

    @Test func aFailureIsANoticeNamingTheVolume() async {
        let workspace = await makeWorkspace(at: "/Volumes/Backup")
        workspace.system.eject = { _, failed in failed("The volume is in use by “Preview”.") }
        workspace.perform(.runAction("eject", .left))
        #expect(workspace.notices.map(\.text) == ["Eject “Backup”: The volume is in use by “Preview”."])
    }

    /// #84 review: from the tree, Eject does not wait for the volume's listing: a volume that
    /// cannot be read, or is still being read, is ejected at once.
    @Test func theTreeEjectsAVolumeThatCannotBeRead() async {
        let workspace = await makeWorkspace(at: "/Users/me")
        var ejected: [String] = []
        workspace.system.eject = { path, _ in ejected.append(path) }
        workspace.perform(.navigate(.left, path: "/Volumes/Broken"))
        await workspace.settle()
        guard case .failed = workspace.state(of: .left).status else {
            Issue.record("expected the listing to fail")
            return
        }
        workspace.perform(.runFolderAction("eject", .left, folder: "/Volumes/Broken"))
        #expect(ejected == ["/Volumes/Broken"])
    }

    @Test func theTreeEjectsAVolumeStillBeingRead() async {
        let workspace = await makeWorkspace(at: "/Users/me", slow: ["/Volumes/Backup"])
        var ejected: [String] = []
        workspace.system.eject = { path, _ in ejected.append(path) }
        workspace.perform(.navigate(.left, path: "/Volumes/Backup"))
        #expect(workspace.state(of: .left).status == .loading)
        workspace.perform(.runFolderAction("eject", .left, folder: "/Volumes/Backup"))
        #expect(ejected == ["/Volumes/Backup"])
    }

    /// #84 review: what automation shows before it ejects is the volume, whatever is selected,
    /// and that the disk's other volumes go too.
    @Test func automationAsksAboutTheVolumeNotTheSelection() async throws {
        let workspace = await makeWorkspace(at: "/Volumes/Backup/2026")
        var ejected: [String] = []
        workspace.system.eject = { path, _ in ejected.append(path) }
        for names: [String] in [[], ["photo.jpg"]] {
            workspace.perform(.select(.left, Set(names)))
            let preview = try await call(workspace, "preview", ["action": "eject", "side": "left"])["result"]
            #expect(preview?["items"] == ["/Volumes/Backup"], "\(names)")
            #expect(preview?["detail"]?.string?.contains("every other volume on its disk") == true)
            #expect(preview?["needsConfirmation"] == true)
        }
        let running = Task { try await call(workspace, "run", ["action": "eject", "side": "left"]) }
        for _ in 0 ..< 300 where workspace.automationConfirmation == nil {
            try await Task.sleep(for: .milliseconds(10))
        }
        let asked = try #require(workspace.automationConfirmation)
        #expect(asked.plan.items == ["/Volumes/Backup"]) // the selection is photo.jpg
        workspace.perform(.answerAutomation(token: asked.token, allow: false))
        _ = try await running.value
        #expect(ejected.isEmpty)
    }

    private func call(_ workspace: Workspace, _ method: String, _ params: JSONValue) async throws -> JSONValue {
        let request: JSONValue = ["jsonrpc": "2.0", "id": 1, "method": .string(method), "params": params]
        let reply = try #require(await workspace.handleAutomation(request.line, client: "test (pid 1)"))
        return try JSONDecoder().decode(JSONValue.self, from: Data(reply.utf8))
    }
}
