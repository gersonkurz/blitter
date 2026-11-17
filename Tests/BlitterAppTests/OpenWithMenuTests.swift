import AppKit
@testable import Blitter
@testable import BlitterCore
@testable import BlitterModel
import Testing
import UniformTypeIdentifiers

/// Open With and Always Open … With (#109) through the real file list and Launch Services, on
/// real temporary files. The Mac's own defaults are never changed: setting a default goes to a
/// stand-in, except on a kind no real file has.
@MainActor
@Suite(.serialized)
final class OpenWithMenuTests {
    private let root = NSTemporaryDirectory() + "BlitterOpenWithTests-" + UUID().uuidString
    private let workspace: Workspace
    private let list: FileListViewController
    private let window: NSWindow

    init() async throws {
        try FileManager.default.createDirectory(atPath: root + "/left/sub", withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: root + "/left/a.txt", contents: Data("a".utf8))
        workspace = Workspace(initialLocation: root + "/left", home: root + "/home", directoryCheck: { _ in false },
                              volumes: { [] }, watcher: FakeWatcher.factory,
                              jobs: JobQueue(trash: { _ in throw POSIXError(.EPERM) }))
        list = FileListViewController(workspace: workspace, side: .left)
        window = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 700, height: 400),
                          styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentViewController = list
        workspace.onChange = { [list] in list.render() }
        try await waitUntil { self.names() == ["sub", "a.txt"] }
    }

    isolated deinit {
        window.close()
        try? FileManager.default.removeItem(atPath: root)
    }

    /// The context menu's Open With lists the apps Launch Services has for the file (TextEdit
    /// opens any text), found off the main thread: first "Looking for apps…", then the apps, the
    /// default first and marked, then Other…. Choosing one opens the file with it. Always Open
    /// .txt Files With checks the type's default and makes the chosen app the default — through
    /// a stand-in here (the real call is checked on a kind no file has, below).
    @Test func openWithListsTheAppsAndChoosingOneRunsTheCommand() async throws {
        var opened: [(String, [String])] = []
        var defaults: [(String, String)] = []
        workspace.system.openWithApp = { app, paths, _ in opened.append((app, paths)) }
        workspace.system.setDefaultApp = { app, type, done in
            defaults.append((app, type))
            done(nil)
        }
        workspace.perform(.select(.left, ["a.txt"]))
        let menu = NSMenu()
        list.prepareContextMenu(menu, clickedRow: nil)
        let openWith = try #require(menu.items.first { $0.title == "Open With" }?.submenu as? OpenWithMenu)
        let always = try #require(menu.items.first { $0.title == "Always Open .txt Files With" }?.submenu
            as? OpenWithMenu)

        openWith.menuNeedsUpdate(openWith)
        #expect(openWith.items.map(\.title) == ["Looking for apps…", "Other…"])
        workspace.perform(.select(.left, ["sub"])) // changed while open: the menu keeps its file
        try await waitUntil { openWith.items.count > 2 }
        let titles = openWith.items.map(\.title)
        #expect(titles.contains { $0.hasPrefix("TextEdit") })
        #expect(titles.last == "Other…")
        let found = OpenWithMenu.apps(for: [root + "/left/a.txt"])
        if let defaultApp = found.defaultApp { // a Mac always has one for text; be safe anyway
            #expect(titles.first == OpenWithMenu.displayName(of: defaultApp) + " (default)")
        }
        let textEdit = try #require(openWith.items.first { $0.title.hasPrefix("TextEdit") })
        let action = try #require(textEdit.action)
        NSApp.sendAction(action, to: textEdit.target, from: textEdit)
        let path = try #require(textEdit.representedObject as? String)
        #expect(path.hasSuffix("/TextEdit.app"))
        #expect(opened.map(\.0) == [path] && opened.map(\.1) == [[root + "/left/a.txt"]])

        workspace.perform(.select(.left, ["a.txt"]))
        always.menuNeedsUpdate(always)
        try await waitUntil { always.items.count > 2 }
        let typeDefault = NSWorkspace.shared.urlForApplication(toOpen: .plainText)
        #expect(always.items.filter { $0.state == .on }.map(\.title)
            == typeDefault.map { [OpenWithMenu.displayName(of: $0)] } ?? [])
        let alwaysTextEdit = try #require(always.items.first { $0.title == "TextEdit" })
        NSApp.sendAction(action, to: alwaysTextEdit.target, from: alwaysTextEdit)
        #expect(defaults.map(\.0) == [path] && defaults.map(\.1) == ["public.plain-text"])
    }

    /// #109 review: closing the menu cancels its lookup (and opening it again the one before),
    /// and a lookup that comes back anyway shows nothing: the placeholder stays.
    @Test func closingTheMenuCancelsItsLookUp() async throws {
        workspace.perform(.select(.left, ["a.txt"]))
        let menu = OpenWithMenu(setsDefault: false) { [workspace] in (workspace, .left) }
        menu.menuNeedsUpdate(menu)
        let first = try #require(menu.lookup)
        menu.menuNeedsUpdate(menu) // opened again
        #expect(first.isCancelled)
        let second = try #require(menu.lookup)
        menu.menuDidClose(menu)
        #expect(second.isCancelled)
        _ = await second.value
        await Task.yield()
        #expect(menu.items.map(\.title) == ["Looking for apps…", "Other…"])
    }

    /// A cancelled lookup asks Launch Services nothing more: it stops at the next file or app,
    /// and finds nothing.
    @Test func aCancelledLookUpStopsAtTheNextFile() {
        var paths: [String] = []
        for index in 0 ..< 20 {
            let path = root + "/left/n\(index).txt"
            #expect(FileManager.default.createFile(atPath: path, contents: Data()))
            paths.append(path)
        }
        var asked = 0
        #expect(OpenWithMenu.lookUp(paths, defaultFor: nil, isCancelled: {
            asked += 1
            return true
        }).isEmpty)
        #expect(asked == 1) // before the first question
        for cancelAfter in [2, 5, 15] { // during the apps, the defaults, the icons
            asked = 0
            let found = OpenWithMenu.lookUp(paths, defaultFor: nil, isCancelled: {
                asked += 1
                return asked > cancelAfter
            })
            #expect(found.isEmpty, "\(cancelAfter)")
            #expect(asked == cancelAfter + 1, "\(cancelAfter)") // not asked again once it said so
        }
        asked = 0
        #expect(!OpenWithMenu.lookUp(paths, defaultFor: nil, isCancelled: {
            asked += 1
            return false
        }).isEmpty)
        #expect(asked > 20) // a check per file's default at least
    }

    /// #109 review: Other… is for what the menu was opened for, as the listed apps are, whatever
    /// is selected when it is chosen.
    @Test func otherIsForWhatTheMenuWasOpenedFor() async throws {
        var asked: [(String?) -> Void] = []
        var opened: [[String]] = []
        var defaults: [String] = []
        workspace.system.chooseApp = { asked.append($0) }
        workspace.system.openWithApp = { _, paths, _ in opened.append(paths) }
        workspace.system.setDefaultApp = { _, type, done in
            defaults.append(type)
            done(nil)
        }
        workspace.perform(.select(.left, ["a.txt"]))
        let openWith = OpenWithMenu(setsDefault: false) { [workspace] in (workspace, .left) }
        let always = OpenWithMenu(setsDefault: true) { [workspace] in (workspace, .left) }
        openWith.menuNeedsUpdate(openWith)
        always.menuNeedsUpdate(always)
        let png = root + "/left/b.png"
        #expect(FileManager.default.createFile(atPath: png, contents: Data()))
        workspace.perform(.refresh(.left))
        try await waitUntil { self.names().contains("b.png") }
        workspace.perform(.select(.left, ["b.png"])) // meanwhile, e.g. from automation
        for menu in [openWith, always] {
            let other = try #require(menu.items.last)
            #expect(other.title == "Other…")
            let action = try #require(other.action)
            NSApp.sendAction(action, to: other.target, from: other)
        }
        #expect(asked.count == 2)
        for answer in asked {
            answer("/System/Applications/TextEdit.app")
        }
        #expect(opened == [[root + "/left/a.txt"]])
        #expect(defaults == ["public.plain-text"])
    }

    /// Several kinds: only the apps that open every one of them.
    @Test func openWithForSeveralKindsListsTheAppsTheyShare() {
        let image = root + "/left/b.png"
        #expect(FileManager.default.createFile(atPath: image, contents: Data()))
        let text = OpenWithMenu.apps(for: [root + "/left/a.txt"]).apps
        let png = OpenWithMenu.apps(for: [image]).apps
        let both = OpenWithMenu.apps(for: [root + "/left/a.txt", image]).apps
        #expect(Set(both) == Set(text).intersection(png))
        #expect(OpenWithMenu.apps(for: []).apps.isEmpty)
    }

    /// #109 review: a file can open with an app of its own (Get Info's Open with, for that file
    /// only). Open With marks a default only when every file opens with it; Always Open … With
    /// marks the type's default, which is what it changes. The override is set on a temporary
    /// file, which goes with the test's folder.
    @Test func aFileWithAnAppOfItsOwnIsNotMarkedWithTheTypesDefault() async throws {
        let own = root + "/left/own.txt"
        #expect(FileManager.default.createFile(atPath: own, contents: Data("x".utf8)))
        let plain = root + "/left/a.txt"
        let typeDefault = try #require(NSWorkspace.shared.urlForApplication(toOpen: .plainText)?.standardizedFileURL)
        let other = try #require(OpenWithMenu.apps(for: [own]).apps.first { $0 != typeDefault })
        try await NSWorkspace.shared.setDefaultApplication(at: other, toOpenFileAt: URL(fileURLWithPath: own))

        #expect(OpenWithMenu.apps(for: [own]).defaultApp == other)
        #expect(OpenWithMenu.apps(for: [plain]).defaultApp == typeDefault)
        #expect(OpenWithMenu.apps(for: [plain, own]).defaultApp == nil) // they differ
        #expect(OpenWithMenu.apps(for: [plain, own], defaultFor: .plainText).defaultApp == typeDefault)
    }

    /// #109 review: the real change of a kind's default, executed — on a kind no real file has
    /// (".blitterprobe", a type macOS makes up for it), so the Mac's own defaults stay as they
    /// are. Two apps one after the other, so the result is the change and not a coincidence.
    /// What stays behind is Launch Services' note that ".blitterprobe" files open with Preview.
    /// A long-running process (this test host) can see the change a moment late — a separate
    /// process sees it at once — so the answer is awaited for a few seconds. In a full test run
    /// Launch Services takes from a few seconds to over a minute to confirm, so this runs on its
    /// own: `just launch-services` (BLITTER_LAUNCH_SERVICES=1).
    @Test(.enabled(if: ProcessInfo.processInfo.environment["BLITTER_LAUNCH_SERVICES"] != nil))
    func settingTheDefaultForAKindChangesWhatItsFilesOpenWith() async throws {
        let probe = URL(fileURLWithPath: root + "/left/x.blitterprobe")
        #expect(FileManager.default.createFile(atPath: probe.path, contents: Data()))
        let type = try #require(UTType(filenameExtension: "blitterprobe"))
        for app in ["/System/Applications/TextEdit.app", "/System/Applications/Preview.app"] {
            let problem = await withCheckedContinuation { continuation in
                OpenWithMenu.setDefaultApp(app, type.identifier) { continuation.resume(returning: $0) }
            }
            #expect(problem == nil)
            var answers: (file: String?, type: String?) = (nil, nil)
            for _ in 0 ..< 50 {
                answers = (NSWorkspace.shared.urlForApplication(toOpen: probe)?.standardizedFileURL.path,
                           NSWorkspace.shared.urlForApplication(toOpen: type)?.standardizedFileURL.path)
                if answers == (app, app) {
                    break
                }
                try await Task.sleep(for: .milliseconds(100))
            }
            #expect(answers.file == app, "for a file, Launch Services still answers \(answers.file ?? "nil")")
            #expect(answers.type == app, "for the type, Launch Services still answers \(answers.type ?? "nil")")
        }
    }

    private func names() -> [String] {
        workspace.state(of: .left).visibleEntries.map(\.entry.name)
    }

    private func waitUntil(_ condition: () -> Bool) async throws {
        for _ in 0 ..< 300 where !condition() {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(condition())
    }
}
