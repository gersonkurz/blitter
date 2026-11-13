@testable import BlitterModel
import Testing

/// #65: what the Settings window's Tools & Menus tab does to the settings it edits.
struct ToolsEditingTests {
    @Test func aNewToolGetsAFreeNameFromItsTitle() {
        var settings = Settings()
        #expect(settings.addTool(title: "Open with Hex Editor!") == "open-with-hex-editor")
        #expect(settings.addTool(title: "Open with Hex Editor") == "open-with-hex-editor-2")
        #expect(settings.addTool(title: "Öffnen ¿?") == "offnen")
        #expect(settings.addTool(title: "!!!") == "tool")
        // Never the name of a built-in action or of a tool Blitter has.
        #expect(settings.addTool(title: "Rename") == "rename-2")
        #expect(settings.addTool(title: "Open in Terminal") == "open-in-terminal-2")
        #expect(settings.tools.last == Tool(id: "open-in-terminal-2", title: "Open in Terminal", app: "",
                                            scope: .selection))
    }

    /// A new tool has no app until one is given: the window shows the file's problem, and once an
    /// app is there, the tool is written and read back as it is.
    @Test func aNewToolIsAProblemUntilItHasAnApp() throws {
        var settings = Settings()
        let id = settings.addTool(title: "Hex")
        #expect(!settings.problems.isEmpty)
        let index = try #require(settings.tools.firstIndex { $0.id == id })
        settings.tools[index].app = "Hex Fiend"
        settings.tools[index].scope = .files
        settings.tools[index].extensions = ["bin"]
        #expect(settings.problems.isEmpty)
        #expect(Settings.parse(Settings.fileText(settings)).settings == settings)
    }

    @Test func removingAToolRemovesItFromEveryMenu() {
        var settings = Settings()
        let id = settings.addTool(title: "Hex")
        settings.tools[settings.tools.count - 1].app = "Hex Fiend"
        settings.contextMenus.items = [.action(id), .separator, .submenu("More", [.action("open"), .action(id)])]
        settings.contextMenus.folder = [.action(id)]
        settings.menuBar.file = [.action(id, shortcut: nil, alternate: false), .separator]
        settings.menuBar.edit = [.action("copy-path", shortcut: nil, alternate: false),
                                 .action(id, shortcut: Shortcut(.function(3)), alternate: false)]
        settings.removeTool(id)
        #expect(!settings.tools.contains { $0.id == id })
        #expect(settings.contextMenus.items == [.separator, .submenu("More", [.action("open")])])
        #expect(settings.contextMenus.folder.isEmpty)
        #expect(settings.menuBar.file == [.separator])
        #expect(settings.menuBar.edit == [.action("copy-path", shortcut: nil, alternate: false)])
        #expect(settings.problems.isEmpty)
    }

    /// Blitter's own tools always exist: the file can change them, not remove them.
    @Test func blittersOwnToolsCannotBeRemoved() {
        var settings = Settings()
        #expect(!settings.canRemoveTool("open-in-terminal"))
        settings.removeTool("open-in-terminal")
        #expect(settings == Settings())
        #expect(!settings.canRemoveTool("no-such-tool"))
    }

    @Test func theChoicesAreTheBuiltInActionsThenTheTools() {
        var settings = Settings()
        settings.addTool(title: "Hex")
        let choices = settings.actionChoices
        #expect(choices.first == ActionChoice(id: "open", title: "Open", symbol: "arrow.up.forward.app"))
        #expect(choices.last == ActionChoice(id: "hex", title: "Hex", symbol: "app.badge"))
        #expect(choices.count == ActionRegistry.builtIn.all.count + settings.tools.count)
    }

    @Test func aSubmenuIsReadAndChangedByItsPath() {
        var menu: [MenuEntry] = [
            .action("open"),
            .submenu("A", [.action("copy-path"), .submenu("B", [.action("rename")])]),
        ]
        #expect(menu[submenu: []] == menu)
        #expect(menu[submenu: [1, 1]] == [.action("rename")])
        #expect(menu[submenu: [0]].isEmpty) // not a submenu
        #expect(menu[submenu: [7]].isEmpty)
        menu[submenu: [1, 1]] = [.action("rename"), .separator]
        #expect(menu[1] == .submenu("A", [.action("copy-path"), .submenu("B", [.action("rename"), .separator])]))
        let before = menu
        menu[submenu: [0, 3]] = [.action("open")] // leads nowhere: nothing changes
        #expect(menu == before)
        #expect(menu.validSubmenuPath([1, 1]) == [1, 1] && menu.submenuTitles([1, 1]) == ["A", "B"])
        #expect(menu.validSubmenuPath([1, 1, 0]) == [1, 1]) // an action is no submenu
        #expect(menu.validSubmenuPath([1, 5]) == [1] && menu.validSubmenuPath([9]).isEmpty)
        menu[submenu: []] = []
        #expect(menu.isEmpty)
        #expect(menu.validSubmenuPath([1, 1]).isEmpty && menu.submenuTitles([1, 1]).isEmpty)
    }

    /// Saving merges tool by tool: a tool the file changed meanwhile stays as the file has it,
    /// unless the window changed that tool too.
    @Test func savingTakesOnlyTheToolsTheWindowChanged() {
        let original = Settings()
        var edited = original
        edited.tools[1].app = "Zed" // open-in-code
        let hex = edited.addTool(title: "Hex")
        edited.tools[edited.tools.count - 1].app = "Hex Fiend"
        var inFile = original
        inFile.tools[0].app = "Terminal" // open-in-terminal, changed in the file meanwhile
        inFile.tools.append(Tool(id: "fetch", title: "Fetch", app: "", scope: .folder, command: ["git", "fetch"]))
        let merged = inFile.applying(changesFrom: original, to: edited)
        #expect(merged.tools.map(\.id) == ["open-in-terminal", "open-in-code", "open-in-text-editor", "fetch", hex])
        #expect(merged.tools[0].app == "Terminal")
        #expect(merged.tools[1].app == "Zed")
        #expect(merged.tools[4].app == "Hex Fiend")

        // A tool the window removed goes; one the file removed meanwhile stays gone.
        var removed = edited
        removed.removeTool(hex)
        #expect(!merged.applying(changesFrom: edited, to: removed).tools.contains { $0.id == hex })
        var withoutFetch = inFile
        withoutFetch.tools.removeAll { $0.id == "fetch" }
        #expect(!withoutFetch.applying(changesFrom: original, to: edited).tools.contains { $0.id == "fetch" })
    }

    @Test func shortcutsReadAndShowAsInMenus() {
        #expect(Shortcut("shift+cmd+n")?.glyphs == "⇧⌘N")
        #expect(Shortcut("opt+cmd+backspace")?.glyphs == "⌥⌘⌫")
        #expect(Shortcut("f2")?.glyphs == "F2")
        #expect(Shortcut("cmd+shift+opt+ctrl+x")?.glyphs == "⌃⌥⇧⌘X")
        #expect(Shortcut("shift+cmd+n")?.text == "shift+cmd+n")
        #expect(Shortcut("cmd+") == nil)
    }

    /// #76: a file saved before an action existed keeps its old menus; Reset to Default brings
    /// one menu back as Blitter has it now, and leaves the others alone.
    @Test func aMenuIsResetToTheDefaultAlone() {
        let frozen = """
        [context_menu]
        items = ["open", "-", "rename"]
        folder = ["new-folder"]
        [menu_bar]
        edit = [{ action = "copy-path", key = "opt+cmd+c" }]
        """
        var settings = Settings.parse(frozen).settings
        let before = settings
        #expect(!settings.isDefault(.items) && !settings.isDefault(.folder) && !settings.isDefault(.edit))
        #expect(settings.isDefault(.file)) // the file has no File menu: it is the default

        settings.resetToDefault(.items)
        #expect(settings.isDefault(.items))
        #expect(settings.contextMenus.items.contains(.action("add-to-favorites")))
        #expect(settings.contextMenus.folder == before.contextMenus.folder && settings.menuBar == before.menuBar)

        settings.resetToDefault(.folder)
        settings.resetToDefault(.edit)
        #expect(EditableMenu.allCases.allSatisfy(settings.isDefault))
        #expect(settings == Settings()) // nothing else in the file differed
        #expect(settings.problems.isEmpty)
    }
}
