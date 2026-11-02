@testable import BlitterModel
import Foundation
import Testing

/// The context menus in the settings file (#19).
struct ContextMenuSettingsTests {
    @Test func theDefaultsAreTheIssuesListAndTheDefaultFileSpellsThemOut() {
        let menus = Settings().contextMenus
        #expect(menus.items.compactMap {
            if case let .action(id) = $0 {
                id
            } else {
                nil
            }
        } == [
            "open", "quick-look", "folder-sizes", "copy-path", "copy-name", "rename", "move-to-trash",
            "delete-immediately",
            "compare-files", "git-log", "git-commit", "git-sync", "reveal-in-finder", "open-in-terminal",
            "open-in-code",
            "open-in-text-editor",
        ])
        #expect(menus.folder == [
            .action("new-folder"),
            .action("folder-sizes"),
            .separator,
            .action("copy-folder-path"),
            .action("compare-folders"),
            .action("git-log"),
            .action("git-commit"),
            .action("git-sync"),
            .separator,
            .action("open-in-terminal"),
            .action("open-in-code"),
        ])
        #expect(Settings.parse(Settings.defaultFile) == (Settings(), []))
    }

    @Test func aMenuWithASubmenuAndAToolDefinedLaterInTheFile() {
        let (settings, problems) = Settings.parse("""
        [context_menu]
        items = ["open", "-", { title = "Open With", items = ["open-in-code", "preview"] }]
        [tools.preview]
        app = "Preview"
        on = "files"
        """)
        #expect(problems.isEmpty)
        #expect(settings.contextMenus.items == [
            .action("open"), .separator, .submenu("Open With", [.action("open-in-code"), .action("preview")]),
        ])
        #expect(settings.contextMenus.folder == ContextMenus.defaults.folder)
    }

    @Test func anUnknownActionIsReportedAndLeftOutTheRestStays() {
        let (settings, problems) = Settings.parse("""
        [context_menu]
        folder = ["new-folder", "make-coffee", { title = "More", items = ["also-unknown"] }]
        """)
        #expect(settings.contextMenus.folder == [.action("new-folder"), .submenu("More", [])])
        #expect(problems.count == 2)
        #expect(problems.contains { $0.contains("make-coffee") && $0.contains("context_menu.folder") })
        #expect(problems.contains { $0.contains("also-unknown") && $0.contains("More") })
    }

    @Test func aMalformedMenuKeepsTheDefault() {
        let (settings, problems) = Settings.parse("""
        [context_menu]
        items = ["open", 3, { title = "No items" }]
        folder = "new-folder"
        extra = []
        """)
        #expect(settings.contextMenus == ContextMenus.defaults)
        #expect(problems.count == 4)
        #expect(problems.contains { $0.contains("context_menu.extra") })
        #expect(problems.contains { $0.contains("context_menu.folder") && $0.contains("expected a list") })
    }
}

@MainActor
@Suite(.serialized)
struct ContextMenuTests {
    @Test func onlyWhatFitsIsShownWithTidySeparators() async throws {
        let sides = try SidesOnDisk()
        try FileManager.default.createDirectory(atPath: sides.left + "/folder", withIntermediateDirectories: false)
        sides.file("left/a.txt")
        sides.workspace.perform(.refresh(.left))
        try await sides.settle()
        sides.workspace.settings.contextMenus.items = [
            .separator, .action("rename"), .separator, .separator, .action("open-in-text-editor"),
            .submenu("Empty", [.action("open-in-text-editor")]), .separator,
        ]

        sides.workspace.perform(.select(.left, ["folder"]))
        // A folder: no text editor, the submenu with nothing in it goes, no stray separators.
        #expect(sides.workspace.contextMenu(for: .left, folder: false) == [.action(id: "rename", title: "Rename")])

        sides.workspace.perform(.select(.left, ["a.txt"]))
        #expect(sides.workspace.contextMenu(for: .left, folder: false) == [
            .action(id: "rename", title: "Rename"), .separator,
            .action(id: "open-in-text-editor", title: "Open in Text Editor"),
            .submenu("Empty", [.action(id: "open-in-text-editor", title: "Open in Text Editor")]),
        ])
        sides.workspace.perform(.select(.left, []))
        #expect(sides.workspace.contextMenu(for: .left, folder: true).map { entry in
            if case let .action(id, _) = entry {
                id
            } else {
                "-"
            }
        } == ["new-folder", "folder-sizes", "-", "copy-folder-path", "compare-folders", "-", "open-in-terminal",
              "open-in-code"])
    }
}
