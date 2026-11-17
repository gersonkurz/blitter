import BlitterCore
@testable import BlitterModel
import Foundation
import Testing

/// #109: Open With and Always Open … With, on real files.
@MainActor
@Suite(.serialized)
struct OpenWithTests {
    private func sides() async throws -> SidesOnDisk {
        let sides = try SidesOnDisk()
        try FileManager.default.createDirectory(atPath: sides.left + "/folder", withIntermediateDirectories: false)
        for name in ["a.txt", "B.TXT", "c.txt", "notes.md", "README", "data.blitter-unknown-kind"] {
            sides.file("left/" + name)
        }
        sides.workspace.perform(.refresh(.left))
        try await sides.settle()
        return sides
    }

    /// Open With fits any selected files; Always Open … With only files of one kind macOS
    /// knows, and its title names their extension.
    @Test func alwaysOpenWithNeedsFilesOfOneKnownKind() async throws {
        let sides = try await sides()
        let workspace = sides.workspace
        func fits(_ names: Set<String>) -> (open: Bool, always: Bool) {
            workspace.perform(.select(.left, names))
            return (workspace.canRun("open-with", on: .left), workspace.canRun("always-open-with", on: .left))
        }
        #expect(fits(["a.txt", "B.TXT", "c.txt"]) == (true, true)) // the extension's case does not matter
        #expect(workspace.menuTitle("always-open-with", on: .left) == "Always Open .txt Files With")
        #expect(workspace.menuTitle("open-with", on: .left) == "Open With")
        #expect(fits(["a.txt", "notes.md"]) == (true, false)) // two kinds
        #expect(fits(["README"]) == (true, false)) // no extension
        #expect(fits(["data.blitter-unknown-kind"]) == (true, false)) // a kind macOS does not know
        #expect(fits(["folder"]) == (false, false))
        #expect(fits(["a.txt", "folder"]) == (false, false))
        #expect(fits([]) == (false, false))
        #expect(workspace.menuTitle("always-open-with", on: .left) == "Always Open With")
    }

    /// The default context menu has both as submenus of apps, after Open; the tree's menu (folders)
    /// has neither.
    @Test func theContextMenuShowsThemAsSubmenusOfApps() async throws {
        let sides = try await sides()
        sides.workspace.perform(.select(.left, ["a.txt"]))
        let menu = sides.workspace.contextMenu(for: .left, folder: false)
        #expect(Array(menu.prefix(3)) == [
            .action(id: "open", title: "Open"),
            .apps(id: "open-with", title: "Open With", setsDefault: false),
            .apps(id: "always-open-with", title: "Always Open .txt Files With", setsDefault: true),
        ])
        sides.workspace.perform(.select(.left, ["a.txt", "notes.md"]))
        let mixed = sides.workspace.contextMenu(for: .left, folder: false)
        #expect(mixed.contains(.apps(id: "open-with", title: "Open With", setsDefault: false)))
        #expect(!mixed.contains {
            if case .apps(id: "always-open-with", _, _) = $0 {
                true
            } else {
                false
            }
        })
        let tree = sides.workspace.treeContextMenu(for: sides.left)
        #expect(!tree.contains {
            if case .apps = $0 {
                true
            } else {
                false
            }
        })
    }

    /// Setting the default goes to the system for the kind's content type, and says how it went.
    @Test func settingTheDefaultSaysHowItWent() async throws {
        let sides = try await sides()
        let workspace = sides.workspace
        var defaults: [(String, String)] = []
        var answer: String?
        workspace.system.setDefaultApp = { app, type, done in
            defaults.append((app, type))
            done(answer)
        }
        workspace.perform(.select(.left, ["a.txt", "c.txt"]))
        let kind = try #require(workspace.selectedKind(on: .left))
        #expect(kind == FileKind(pathExtension: "txt", contentType: .plainText))
        workspace.perform(.setDefaultApp("/Applications/TextEdit.app", for: kind))
        #expect(defaults.map(\.0) == ["/Applications/TextEdit.app"] && defaults.map(\.1) == ["public.plain-text"])
        #expect(workspace.notices.last?.text == ".txt files now open with TextEdit.")
        answer = "not allowed"
        workspace.perform(.setDefaultApp("/Applications/TextEdit.app", for: kind))
        #expect(workspace.notices.last?.text
            == "TextEdit could not be made the default for .txt files: not allowed")
        workspace.perform(.select(.left, ["a.txt", "notes.md"]))
        #expect(workspace.selectedKind(on: .left) == nil) // two kinds
    }

    /// Other… (or the action run on its own) asks for an app, then opens the files or sets the
    /// default; nothing chosen does nothing. Where the action does not fit, it does not ask.
    @Test func otherAsksForAnApp() async throws {
        let sides = try await sides()
        let workspace = sides.workspace
        var chosen: String?
        var asked = 0
        var opened: [(String, [String])] = []
        var defaults: [(String, String)] = []
        workspace.system.chooseApp = { done in
            asked += 1
            done(chosen)
        }
        workspace.system.openWithApp = { app, paths, _ in opened.append((app, paths)) }
        workspace.system.setDefaultApp = { app, type, done in
            defaults.append((app, type))
            done(nil)
        }
        workspace.perform(.select(.left, ["notes.md"]))
        workspace.perform(.runAction("open-with", .left)) // nothing chosen
        #expect(asked == 1 && opened.isEmpty)
        chosen = "/Applications/TextEdit.app"
        workspace.perform(.runAction("open-with", .left))
        #expect(opened.map(\.0) == ["/Applications/TextEdit.app"] && opened.map(\.1) == [[sides.left + "/notes.md"]])
        workspace.perform(.select(.left, ["a.txt"]))
        workspace.perform(.runAction("always-open-with", .left))
        #expect(defaults.map(\.0) == ["/Applications/TextEdit.app"] && defaults.map(\.1) == ["public.plain-text"])
        workspace.perform(.select(.left, ["folder"]))
        workspace.perform(.runAction("open-with", .left))
        workspace.perform(.chooseApp(.open([]))) // no files named
        #expect(asked == 3) // not asked for a folder, nor for nothing
    }

    /// #109 review: the files, or their kind, are taken when the panel opens. A selection that
    /// changes while the user chooses (from automation, say) changes nothing about the choice.
    @Test func theChooserActsOnWhatWasSelectedWhenItAsked() async throws {
        let sides = try await sides()
        let workspace = sides.workspace
        var answer: ((String?) -> Void)?
        var opened: [[String]] = []
        var defaults: [String] = []
        workspace.system.chooseApp = { done in answer = done }
        workspace.system.openWithApp = { _, paths, _ in opened.append(paths) }
        workspace.system.setDefaultApp = { _, type, done in
            defaults.append(type)
            done(nil)
        }
        workspace.perform(.select(.left, ["a.txt"]))
        workspace.perform(.runAction("always-open-with", .left))
        workspace.perform(.select(.left, ["notes.md"])) // meanwhile
        answer?("/Applications/TextEdit.app")
        #expect(defaults == ["public.plain-text"])

        workspace.perform(.select(.left, ["a.txt", "c.txt"]))
        workspace.perform(.runAction("open-with", .left))
        workspace.perform(.select(.left, ["README"]))
        answer?("/Applications/TextEdit.app")
        #expect(opened == [[sides.left + "/a.txt", sides.left + "/c.txt"]])
    }
}
