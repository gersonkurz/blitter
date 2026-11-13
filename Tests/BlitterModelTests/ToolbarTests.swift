import BlitterCore
@testable import BlitterModel
import Foundation
import Testing

/// #88: the window's toolbar in the settings file, and what each button shows.
@MainActor
struct ToolbarTests {
    @Test func theDefaultsAreKnownActionsAndTheDefaultFileSpellsThemOut() {
        let ids = Settings().toolbar.compactMap(\.actionID)
        #expect(ids == [
            "toggle-hidden-files", "refresh", "new-folder", "copy-to-other-side", "move-to-other-side", "rename",
            "move-to-trash", "open-in-terminal", "open-in-code", "git-log", "git-commit", "git-sync",
        ])
        #expect(Settings().toolbar.filter { $0 == .gap }.count == 2)
        let known = Set(Settings().actionChoices.map(\.id))
        #expect(ids.allSatisfy(known.contains))
        #expect(Settings.parse(Settings.defaultFile) == (Settings(), []))
        #expect(Settings.defaultFile.contains("[toolbar]"))
    }

    @Test func aToolbarOfTheUsersOwnWithIconsGapsAndATool() {
        let (settings, problems) = Settings.parse("""
        [toolbar]
        items = ["refresh", "-", { action = "hex", icon = "hexagon" },
                 { action = "rename", icon = "character.cursor.ibeam" }]
        [tools.hex]
        app = "Hex Fiend"
        """)
        #expect(problems.isEmpty)
        #expect(settings.toolbar == [
            .action("refresh", icon: nil), .gap, .action("hex", icon: "hexagon"),
            .action("rename", icon: "character.cursor.ibeam"),
        ])
        #expect(Settings.parse(Settings.fileText(settings)).settings == settings)
    }

    @Test func anEmptyToolbarIsWrittenAndReadBack() {
        var settings = Settings()
        settings.toolbar = []
        #expect(Settings.fileText(settings).contains("items = []"))
        #expect(Settings.parse(Settings.fileText(settings)) == (settings, []))
    }

    /// A bad entry leaves the whole list as it was, as the menu bar's does; an unknown action is
    /// only left out. Each is reported.
    @Test func problemsAreReported() {
        for bad in [
            "items = \"refresh\"",
            "items = [{ action = \"refresh\" }]",
            "items = [{ action = \"refresh\", icon = \"\" }]",
            "items = [{ action = \"refresh\", icon = \"two words\" }]",
            "items = [{ action = \"refresh\", icon = \"star\", key = \"f5\" }]",
            "items = [42]",
            "buttons = []",
        ] {
            let (settings, problems) = Settings.parse("[toolbar]\n" + bad)
            #expect(settings.toolbar == Settings().toolbar, "\(bad)")
            #expect(problems.count == 1, "\(bad)")
        }
        let (settings, problems) = Settings.parse("[toolbar]\nitems = [\"refresh\", \"no-such-thing\"]")
        #expect(settings.toolbar == [.action("refresh", icon: nil)])
        #expect(problems == ["“toolbar.items”: there is no action “no-such-thing”."])
    }

    @Test func removingAToolRemovesItsButtonAndResetBringsBackTheDefaults() {
        var settings = Settings()
        let id = settings.addTool(title: "Hex")
        settings.tools[settings.tools.count - 1].app = "Hex Fiend"
        settings.toolbar = [.action(id, icon: "hexagon"), .gap, .action("refresh", icon: nil)]
        #expect(!settings.isDefault(.toolbar))
        settings.removeTool(id)
        #expect(settings.toolbar == [.gap, .action("refresh", icon: nil)])
        settings.resetToDefault(.toolbar)
        #expect(settings.isDefault(.toolbar))
        #expect(settings.toolbar == Settings().toolbar)
    }

    /// The window's changes to the toolbar are taken; the rest of the file stays as it is.
    @Test func savingTakesTheToolbarEntryByEntry() {
        var edited = Settings()
        edited.toolbar = [.action("refresh", icon: "arrow.2.circlepath")]
        var file = Settings()
        file.confirmDelete = false
        let merged = file.applying(changesFrom: Settings(), to: edited)
        #expect(merged.toolbar == edited.toolbar)
        #expect(!merged.confirmDelete)
    }

    @Test func everyActionHasASymbolAndToolsGetOneByWhatTheyDo() {
        #expect(ActionRegistry.builtIn.all.allSatisfy { !$0.symbol.isEmpty })
        #expect(Tool.defaults.allSatisfy { Tool.symbols[$0.id] == $0.action.symbol })
        #expect(Tool(id: "hex", title: "Hex", app: "Hex Fiend", scope: .files).action.symbol == "app.badge")
        #expect(Tool(id: "fetch", title: "Fetch", app: "", scope: .folder, command: ["git", "fetch"]).action
            .symbol == "terminal")
    }

    /// Show Hidden Files is on or off, as the View menu's item is; running it from the toolbar
    /// turns it over. Refresh fits any side; the others follow their scope on the active side.
    @Test func buttonsFollowTheActiveSide() async {
        let folders = FakeFolders(["/home": [entry("a.txt")], "/other": []])
        let workspace = Workspace(initialLocation: "/home", home: "/home", lister: folders.list,
                                  directoryCheck: folders.isDirectory, volumes: { [] }, watcher: FakeWatcher.factory)
        await workspace.settle()
        #expect(workspace.toolbarButton("toggle-hidden-files") == ToolbarButtonState(isEnabled: true, isOn: false))
        workspace.perform(.runAction("toggle-hidden-files", workspace.activeSide))
        #expect(workspace.showsHiddenFiles)
        #expect(workspace.toolbarButton("toggle-hidden-files").isOn == true)
        #expect(workspace.toolbarButton("refresh") == ToolbarButtonState(isEnabled: true, isOn: nil))
        #expect(!workspace.toolbarButton("move-to-trash").isEnabled)
        workspace.perform(.select(workspace.activeSide, ["a.txt"]))
        #expect(workspace.toolbarButton("move-to-trash") == ToolbarButtonState(isEnabled: true, isOn: nil))
        workspace.perform(.switchActiveSide)
        #expect(!workspace.toolbarButton("move-to-trash").isEnabled)
    }
}
