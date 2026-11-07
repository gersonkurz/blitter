import BlitterCore
@testable import BlitterModel
import Foundation
import Testing

/// The manual's reference pages (#67) are made from Blitter itself: the settings file, the
/// actions, the default menu shortcuts. This test fails when a page in `docs/manual/reference/`
/// is not what the code makes; `just manual` writes them (BLITTER_WRITE_MANUAL=1).
/// It also checks that every image a manual page shows exists.
struct ManualReferenceTests {
    /// The repository, found from this file: Tests/BlitterModelTests/ManualReferenceTests.swift.
    static let manual = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("docs/manual")

    static let pages: [(name: String, text: String)] = [
        ("reference/settings.md", settingsPage),
        ("reference/actions.md", actionsPage),
        ("reference/shortcuts.md", shortcutsPage),
    ]

    @Test func theReferencePagesAreCurrent() throws {
        let writes = ProcessInfo.processInfo.environment["BLITTER_WRITE_MANUAL"] != nil
        for page in Self.pages {
            let url = Self.manual.appendingPathComponent(page.name)
            if writes {
                try page.text.write(to: url, atomically: true, encoding: .utf8)
            }
            let current = try? String(contentsOf: url, encoding: .utf8)
            #expect(current == page.text, "\(page.name) is out of date: run `just manual`")
        }
    }

    @Test func everyImageAPageShowsExists() throws {
        let files = FileManager.default.enumerator(at: Self.manual, includingPropertiesForKeys: nil)?
            .compactMap { $0 as? URL }.filter { $0.pathExtension == "md" } ?? []
        #expect(!files.isEmpty)
        let image = #/!\[[^\]]*\]\(([^)\s]+)\)/#
        for file in files {
            let text = try String(contentsOf: file, encoding: .utf8)
            for match in text.matches(of: image) {
                let target = file.deletingLastPathComponent().appendingPathComponent(String(match.output.1))
                #expect(FileManager.default.fileExists(atPath: target.path),
                        "\(file.lastPathComponent) shows \(match.output.1), which does not exist")
            }
        }
    }

    /// Every link from one manual page to another leads to a page that exists, and a `#section`
    /// to one of its headings (as GitHub and Jekyll name them).
    @Test func everyLinkBetweenPagesLeadsSomewhere() throws {
        let files = FileManager.default.enumerator(at: Self.manual, includingPropertiesForKeys: nil)?
            .compactMap { $0 as? URL }.filter { $0.pathExtension == "md" } ?? []
        let link = #/\[[^\]]*\]\(([^)\s#:]+\.md)(?:#([^)\s]+))?\)/#
        var checked = 0
        for file in files {
            let text = try String(contentsOf: file, encoding: .utf8)
            for match in text.matches(of: link) {
                checked += 1
                let target = file.deletingLastPathComponent().appendingPathComponent(String(match.output.1))
                guard let page = try? String(contentsOf: target, encoding: .utf8) else {
                    Issue.record("\(file.lastPathComponent) links to \(match.output.1), which does not exist")
                    continue
                }
                if let anchor = match.output.2 {
                    #expect(Self.anchors(page).contains(String(anchor)),
                            "\(file.lastPathComponent) links to \(match.output.1)#\(anchor): no such heading")
                }
            }
        }
        #expect(checked > 0)
    }

    /// The anchors of a page's headings: lowercased, punctuation dropped, spaces as "-".
    static func anchors(_ page: String) -> Set<String> {
        Set(page.split(separator: "\n").filter { $0.hasPrefix("#") }.map { line in
            let title = line.drop { $0 == "#" }.trimmingCharacters(in: .whitespaces).lowercased()
            return String(title.unicodeScalars.compactMap { scalar -> Character? in
                guard scalar != " " else {
                    return "-"
                }
                let keeps = CharacterSet.alphanumerics.contains(scalar) || scalar == "-" || scalar == "_"
                return keeps ? Character(scalar) : nil
            })
        })
    }

    // MARK: Pages

    private static let generated = """
    <!-- Generated from Blitter's code by `just manual`; do not edit. -->

    """

    static var settingsPage: String {
        generated + """
        # The settings file

        Blitter reads its settings from `~/.config/blitter/settings.toml` at launch and again whenever
        the file changes. **Settings…** (⌘,) opens a window for the common ones; **Open Settings File**
        there opens the file itself. This is the file Blitter writes when there is none: every
        setting with its default and what it means.

        ```toml
        \(Settings.defaultFile.trimmingCharacters(in: .newlines))
        ```

        [Back to the contents](../index.md)

        """
    }

    static var actionsPage: String {
        let rows = ActionRegistry.builtIn.all.map { action in
            "| `\(action.id)` | \(action.title) | \(worksOn(action.scope)) |"
        }
        return generated + """
        # Actions

        Everything Blitter can do to files and folders is an action. Menus — the context menus and
        the menu bar's File and Edit menus — list actions by their name in the settings file, and
        a menu shows an action only where it fits what is selected. Tools you define in the
        settings file are actions too, named by their `[tools.<name>]`.

        | Name | Title | Works on |
        |---|---|---|
        \(rows.joined(separator: "\n"))

        [Back to the contents](../index.md)

        """
    }

    static var shortcutsPage: String {
        func rows(_ items: [MenuBarItem]) -> [String] {
            items.compactMap { item in
                guard case let .action(id, shortcut, alternate) = item else {
                    return nil
                }
                let title = ActionRegistry.builtIn.action(id)?.title ?? id
                let keys = shortcut.map { "`\($0.glyphs)`" } ?? ""
                return "| \(title) | \(keys) | `\(id)`\(alternate ? " (while the extra key is held)" : "") |"
            }
        }
        let menus = MenuBarSettings.defaults
        return generated + """
        # Default menu shortcuts

        The File menu's and Edit menu's actions and their shortcuts, as they are until the
        settings file's `[menu_bar]` changes them.

        ## File

        | Item | Shortcut | Action |
        |---|---|---|
        \(rows(menus.file).joined(separator: "\n"))

        ## Edit

        | Item | Shortcut | Action |
        |---|---|---|
        \(rows(menus.edit).joined(separator: "\n"))

        [Back to the contents](../index.md)

        """
    }

    // MARK: Words

    private static func worksOn(_ scope: ActionScope) -> String {
        switch scope {
        case .folder: "the side's folder"
        case .selection: "the selected items"
        case .single: "one selected item"
        case .files: "the selected files (no folders)"
        case .selectionOrFolder: "the selected items, or the folder when nothing is selected"
        case .filePair: "two files: two selected on one side, or one on each side"
        case .bothFolders: "both sides' folders"
        case .workingCopy: "the folder or its one selected item, inside a git working copy"
        case .folders: "the selected folders, or every folder when nothing is selected"
        }
    }
}
