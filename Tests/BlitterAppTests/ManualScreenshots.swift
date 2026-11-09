import AppKit
@testable import Blitter
import BlitterCore
@testable import BlitterModel
import Testing

/// The manual's screenshots (#67), made from the app itself: each scene is built from demo
/// folders that exist only here (fixed names, sizes and dates, so nothing of the user's shows),
/// in a fixed window size, in light and dark. Off unless BLITTER_SCREENSHOTS is set:
/// `just screenshots` runs it and writes the PNGs to docs/manual/images.
@MainActor
@Suite(.serialized, .enabled(if: ProcessInfo.processInfo.environment["BLITTER_SCREENSHOTS"] != nil))
final class ManualScreenshots {
    static let images = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("docs/manual/images")

    @Test func mainWindow() async throws {
        for (appearance, name) in [(NSAppearance.Name.aqua, "light"), (.darkAqua, "dark")] {
            let workspace = Self.demoWorkspace()
            let controller = MainWindowController(workspace: workspace)
            let window = try #require(controller.window)
            window.appearance = NSAppearance(named: appearance)
            window.setContentSize(NSSize(width: 1280, height: 440))
            controller.showWindow(nil)
            NSApp.activate()
            window.makeKeyAndOrderFront(nil) // a key window draws its selection in the accent color
            defer { controller.close() }
            workspace.perform(.navigate(.right, path: Demo.pictures))
            try await Self.waitUntil {
                Side.allCases.allSatisfy { workspace.state(of: $0).visibleEntries.count > 3 }
            }
            workspace.perform(.select(.left, ["README.md", "Sources"]))
            try await Self.capture(window, as: "main-window-\(name).png")
        }
    }

    /// The fast filter: "14" typed in the right list highlights the matching pictures.
    @Test func fastFilter() async throws {
        let scene = try await Self.mainScene()
        let (workspace, controller, window) = (scene.workspace, scene.controller, scene.window)
        defer { controller.close() }
        workspace.perform(.activate(.right))
        workspace.perform(.setQuickFilter(.right, QuickFilter("14", mode: .highlight)))
        try await Self.waitUntil { !workspace.state(of: .right).highlighted.isEmpty }
        try await Self.capture(window, as: "fast-filter-light.png")
    }

    /// Batch Rename over the selected pictures: a template with a counter, and the preview.
    @Test func batchRename() async throws {
        let scene = try await Self.mainScene()
        let (workspace, controller, window) = (scene.workspace, scene.controller, scene.window)
        defer { controller.close() }
        let pictures = workspace.state(of: .right).visibleEntries.map(\.entry.name).filter { $0.hasPrefix("IMG") }
        workspace.perform(.activate(.right))
        workspace.perform(.select(.right, Set(pictures)))
        workspace.perform(.requestBatchRename(.right))
        try await Self.waitUntil { window.attachedSheet != nil }
        let sheet = try #require(window.attachedSheet)
        defer { window.endSheet(sheet) }
        let model = try #require(controller.batchRename)
        model.rule.template = "Iceland {n:2}"
        try await Self.capture(sheet, as: "batch-rename-light.png")
    }

    @Test func settingsWindow() async throws {
        for (appearance, name) in [(NSAppearance.Name.aqua, "light"), (.darkAqua, "dark")] {
            // A settings file of its own that does not exist yet: all defaults, nothing to warn about.
            let folder = NSTemporaryDirectory() + "BlitterScreenshots-" + UUID().uuidString
            defer { try? FileManager.default.removeItem(atPath: folder) }
            let workspace = Self.demoWorkspace(settingsFile: folder + "/settings.toml")
            SettingsWindowController.show(workspace)
            let controller = try #require(SettingsWindowController.current)
            defer { controller.close() }
            controller.model.now = { Demo.date(28, 14) } // the preview shows the same moment every time
            let window = try #require(controller.window)
            window.appearance = NSAppearance(named: appearance)
            try await Self.waitUntil { controller.model.document != nil }
            let document = try #require(controller.model.document)
            try #require(document.canBeSaved && document.problems.isEmpty && controller.model.draftProblems.isEmpty)
            for tab in SettingsTab.allCases {
                controller.model.tab = tab
                try await Self.capture(window, as: "settings-\(tab)-\(name).png")
            }
            // Schemes chosen, each with its preview (#73).
            controller.model.tab = .colors
            controller.model.draft.theme.light = "solarized-light"
            controller.model.draft.theme.dark = "tomorrow-night-blue"
            try await Self.capture(window, as: "settings-colors-chosen-\(name).png")
            controller.model.revert()
            // The Tools & Menus tab's menu editors (#65).
            controller.model.tab = .tools
            for (pane, file) in [(ToolsSettings.Pane.itemsMenu, "items"), (.fileMenu, "file")] {
                controller.model.toolsPane = pane
                try await Self.capture(window, as: "settings-menus-\(file)-\(name).png")
            }
        }
    }

    // MARK: Scenes

    /// Demo folders: a project on the left, holiday pictures on the right.
    private enum Demo {
        static let home = "/Users/demo"
        static let project = home + "/Projects/blitter"
        static let pictures = home + "/Pictures/Iceland 2026"
        static func date(_ day: Int, _ hour: Int) -> Date {
            DateComponents(calendar: .current, year: 2026, month: 10, day: day, hour: hour, minute: 12).date
                ?? .distantPast
        }

        static let listings: [String: [DirectoryEntry]] = [
            project: [
                folder("Sources", day: 30), folder("Tests", day: 30), folder("docs", day: 28),
                file("README.md", 4812, day: 28), file("justfile", 3406, day: 27),
                file("project.yml", 2210, day: 21), file("Package.resolved", 1190, day: 12),
                file("LICENSE", 1067, day: 2),
            ],
            pictures: (1 ... 9).map { number in
                file(String(format: "IMG_%04d.jpg", 4100 + number * 7), Int64(3_100_000 + number * 211_337),
                     day: 3 + number)
            } + [file("Route.gpx", 88420, day: 14)],
        ]

        static func folder(_ name: String, day: Int) -> DirectoryEntry {
            DirectoryEntry(name: name, kind: .directory, size: 0, modificationDate: date(day, 9), isHidden: false,
                           isDataless: false, error: 0)
        }

        static func file(_ name: String, _ size: Int64, day: Int) -> DirectoryEntry {
            DirectoryEntry(name: name, kind: .file, size: size, modificationDate: date(day, 14), isHidden: false,
                           isDataless: false, error: 0)
        }
    }

    /// The main window in light mode, both demo folders listed.
    private struct Scene {
        let workspace: Workspace
        let controller: MainWindowController
        let window: NSWindow
    }

    private static func mainScene() async throws -> Scene {
        let workspace = demoWorkspace()
        let controller = MainWindowController(workspace: workspace)
        let window = try #require(controller.window)
        window.appearance = NSAppearance(named: .aqua)
        window.setContentSize(NSSize(width: 1280, height: 440))
        controller.showWindow(nil)
        workspace.perform(.navigate(.right, path: Demo.pictures))
        try await waitUntil { Side.allCases.allSatisfy { workspace.state(of: $0).visibleEntries.count > 3 } }
        return Scene(workspace: workspace, controller: controller, window: window)
    }

    private static func demoWorkspace(settingsFile: String? = nil) -> Workspace {
        let listings = Demo.listings
        return Workspace(initialLocation: Demo.project, home: Demo.home, lister: { listings[$0] ?? [] },
                         directoryCheck: { _ in true }, volumes: { [] }, watcher: FakeWatcher.factory,
                         settingsFile: settingsFile)
    }

    // MARK: Capture

    /// The whole window, title bar included, drawn as it is on screen.
    private static func capture(_ window: NSWindow, as name: String) async throws {
        try await Task.sleep(for: .milliseconds(300)) // SwiftUI and icons settle
        let view = try #require(window.contentView?.superview)
        view.layoutSubtreeIfNeeded()
        view.display()
        let bitmap = try #require(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: bitmap)
        let png = try #require(bitmap.representation(using: .png, properties: [:]))
        try FileManager.default.createDirectory(at: images, withIntermediateDirectories: true)
        try png.write(to: images.appendingPathComponent(name))
    }

    private static func waitUntil(_ condition: () -> Bool) async throws {
        for _ in 0 ..< 300 where !condition() {
            try await Task.sleep(for: .milliseconds(10))
        }
        try #require(condition())
    }
}
