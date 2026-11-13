import AppKit
@testable import Blitter
@testable import BlitterModel
import Testing

/// #65: the Tools & Menus tab.
extension SettingsWindowTests {
    /// Showing every pane, a tool's form with a command line and file types included, never
    /// changes what was read: only what the user enters does.
    @Test func showingTheToolsAndMenusPanesChangesNothing() async throws {
        // Each with file types the field shows, and with ones it cannot (a comma, a space).
        let cases = [
            (#"["open", "-a", "Terminal", "{paths}"]"#, #"["bin", "tar.gz"]"#),
            (#"["open", "", "{paths}"]"#, #"["bin", "tar.gz"]"#),
            (#"["open", "-a", "Terminal", "{paths}"]"#, #"["foo,bar", "a b"]"#),
        ]
        for (command, extensions) in cases {
            try """
            [tools.open-in-terminal]
            command = \(command)
            on = "files"
            extensions = \(extensions)

            [context_menu]
            items = ["open", "-", { title = "More", items = ["copy-path", "open-in-terminal"] }]
            """.write(toFile: path, atomically: true, encoding: .utf8)
            SettingsWindowController.current?.close()
            let model = try await openWindow()
            let read = try #require(model.document?.settings)
            #expect(read.tools[0].extensions.count == 2)
            model.tab = .tools
            for pane in ToolsSettings.Pane.allCases {
                model.toolsPane = pane
                // Drawn for real, so the panes' views appear (onAppear) as they do on screen.
                try await draw()
                if pane == .tools { // the first tool's form: its command line in an editor, if it fits
                    #expect(try #require(SettingsWindowController.current?.window?.contentView)
                        .hasTextView == !command.contains("\"\""))
                }
                #expect(model.draft == read && !model.isDirty, "\(pane), \(command), \(extensions)")
            }
        }
    }

    @Test func aHalfTypedShortcutKeepsSaveWaiting() async throws {
        let model = try await openWindow()
        model.draft.gitColors = false
        #expect(model.canSave)
        model.inputProblems["File menu"] = "“cmd+” is not a shortcut."
        #expect(!model.canSave)
        model.revert()
        #expect(model.inputProblems.isEmpty && !model.isDirty)
    }

    /// A tool added in the window, and the menu entry naming it, are written into the file.
    @Test func aToolAddedInTheWindowIsSaved() async throws {
        let model = try await openWindow()
        let id = model.draft.addTool(title: "Open with Hex Editor")
        #expect(!model.canSave) // no app yet: the file could not hold it
        let index = try #require(model.draft.tools.firstIndex { $0.id == id })
        model.draft.tools[index].app = "Hex Fiend"
        model.draft.tools[index].scope = .files
        model.draft.tools[index].extensions = ["bin"]
        model.draft.contextMenus.items.append(.action(id))
        model.draft.menuBar.file.append(.action(id, shortcut: Shortcut("ctrl+cmd+h"), alternate: false))
        #expect(model.canSave)
        model.save()
        try await waitUntil { !model.isSaving }
        #expect(model.saveProblem == nil && !model.isDirty)
        let saved = try Settings.parse(String(contentsOfFile: path, encoding: .utf8))
        #expect(saved.problems.isEmpty)
        #expect(saved.settings.tools.last == model.draft.tools[index])
        #expect(saved.settings.contextMenus.items.last == .action(id))
        #expect(saved.settings.menuBar.file.last == .action(id, shortcut: Shortcut("ctrl+cmd+h"), alternate: false))
        #expect(saved.settings.dateFormat == "HH:mm") // the rest as it was
    }

    /// Revert while a submenu added since is open: the editor goes back to a submenu that is
    /// still there (it used to read past the end of the menu, and crash).
    @Test func revertingWhileInANewSubmenuIsSafe() async throws {
        let model = try await openWindow()
        model.tab = .tools
        model.toolsPane = .itemsMenu
        try await draw()
        model.draft.contextMenus.items.append(.submenu("New", [.action("open")]))
        model.menuPath = [model.draft.contextMenus.items.count - 1] // opened, as Open does
        try await draw()
        #expect(model.menuPath.count == 1)
        model.revert()
        try await draw()
        #expect(model.menuPath.isEmpty && !model.isDirty)
    }

    /// Text in a shortcut field that is no shortcut keeps Save waiting only while the field is
    /// there: switching panes, or removing its item, drops it.
    @Test func aHalfTypedShortcutGoesWithItsField() async throws {
        let model = try await openWindow()
        model.draft.gitColors = false
        model.tab = .tools
        model.toolsPane = .fileMenu
        try await draw()
        let content = try #require(SettingsWindowController.current?.window?.contentView)
        try await typeIntoShortcut("cmd+", content)
        #expect(!model.inputProblems.isEmpty && !model.canSave)
        model.toolsPane = .tools
        try await draw()
        #expect(model.inputProblems.isEmpty && model.canSave)

        model.toolsPane = .fileMenu
        try await draw()
        try await typeIntoShortcut("cmd+", content)
        #expect(!model.inputProblems.isEmpty)
        model.draft.menuBar.file.remove(at: 0) // as − does: another item at the same place
        try await draw()
        #expect(model.inputProblems.isEmpty && model.canSave)

        // The item that takes the place has the same (no) shortcut: the field still starts afresh.
        model.draft.menuBar.file = [.action("rename", shortcut: nil, alternate: false),
                                    .action("copy-path", shortcut: nil, alternate: false)]
        try await draw()
        try await typeIntoShortcut("cmd+", content)
        #expect(!model.inputProblems.isEmpty && !model.canSave)
        model.draft.menuBar.file.remove(at: 0)
        try await draw()
        #expect(model.inputProblems.isEmpty && model.canSave)
        let field = try #require(content.descendants(NSTextField.self).first {
            $0.placeholderString?.contains("shift+cmd+n") == true
        })
        #expect(field.stringValue.isEmpty) // copy-path's (no) shortcut, not the text typed for rename
    }

    /// #76: Reset to Default drops what was half typed for the menu that was, even when the
    /// default has as many items and the selected one keeps its shortcut (review of #76).
    @Test func resetDropsAHalfTypedShortcut() async throws {
        var custom = Settings()
        let rename = try #require(custom.menuBar.file.firstIndex(of: .action("rename", shortcut: Shortcut("f2"),
                                                                             alternate: false)))
        custom.menuBar.file[rename] = .action("rename", shortcut: Shortcut("f3"), alternate: false)
        try Settings.fileText(custom).write(toFile: path, atomically: true, encoding: .utf8)
        SettingsWindowController.current?.close()
        let model = try await openWindow()
        model.tab = .tools
        model.toolsPane = .fileMenu
        try await draw()
        let content = try #require(SettingsWindowController.current?.window?.contentView)
        try await typeIntoShortcut("cmd+", content) // New Folder, which the reset leaves as it is
        #expect(!model.inputProblems.isEmpty && !model.canSave)

        model.resetMenu(.file)
        try await draw()
        #expect(model.draft.isDefault(.file) && model.isDirty)
        #expect(model.inputProblems.isEmpty && model.canSave)
        let fields = content.descendants(NSTextField.self).filter {
            $0.placeholderString?.contains("shift+cmd+n") == true
        }
        #expect(fields.allSatisfy { $0.stringValue != "cmd+" }) // made anew, if shown at all
    }

    /// #88 review: typing a variant of the action's own icon ("trash" on the way to "trash.fill")
    /// keeps what is typed; the action's own name alone is no icon of its own.
    @Test func typingAnIconKeepsWhatIsTyped() async throws {
        let model = try await openWindow()
        model.tab = .tools
        model.toolsPane = .toolbar
        try await draw()
        let content = try #require(SettingsWindowController.current?.window?.contentView)
        let row = try #require(model.draft.toolbar.firstIndex(of: .action("move-to-trash", icon: nil)))
        try #require(content.descendants(NSTableView.self).first).select(row: row)
        try await draw()
        let field = try #require(content.descendants(NSTextField.self).first { $0.placeholderString == "trash" })
        func type(_ text: String) async throws {
            #expect(field.window?.makeFirstResponder(field) == true)
            let editor = try #require(field.currentEditor() as? NSTextView)
            editor.setSelectedRange(NSRange(location: editor.string.utf16.count, length: 0))
            for character in text {
                editor.insertText(String(character), replacementRange: editor.selectedRange())
                try await draw()
            }
        }
        // "trash", the action's own: no icon of its own, but the field keeps it, also when the
        // window is drawn anew for another change, and once left.
        try await type("trash")
        #expect(model.draft.toolbar[row] == .action("move-to-trash", icon: nil))
        model.draft.confirmDelete.toggle()
        try await draw()
        #expect(field.stringValue == "trash")
        #expect(field.window?.makeFirstResponder(nil) == true)
        try await draw()
        #expect(field.stringValue == "trash")
        try await type(".fill")
        #expect(field.stringValue == "trash.fill")
        #expect(model.draft.toolbar[row] == .action("move-to-trash", icon: "trash.fill"))
        model.revert()
        try await draw()
        #expect(field.stringValue.isEmpty || field.window == nil) // follows Revert, if still shown
    }

    /// Selects the File menu's first item and types into its shortcut field.
    private func typeIntoShortcut(_ text: String, _ content: NSView) async throws {
        let list = try #require(content.descendants(NSTableView.self).first)
        list.select(row: 0)
        try await draw()
        let field = try #require(content.descendants(NSTextField.self).first {
            $0.placeholderString?.contains("shift+cmd+n") == true
        })
        #expect(field.window?.makeFirstResponder(field) == true)
        let editor = try #require(field.currentEditor() as? NSTextView)
        editor.selectAll(nil)
        editor.insertText(text, replacementRange: editor.selectedRange())
        try await draw()
    }

    /// Drawn for real, so SwiftUI's views appear (onAppear) and update as they do on screen.
    func draw() async throws {
        for _ in 0 ..< 3 {
            try await Task.sleep(for: .milliseconds(100))
            let view = try #require(SettingsWindowController.current?.window?.contentView)
            view.layoutSubtreeIfNeeded()
            view.display()
        }
    }
}

extension NSView {
    func descendants<View: NSView>(_ type: View.Type) -> [View] {
        [self].compactMap { $0 as? View } + subviews.flatMap { $0.descendants(type) }
    }
}

extension NSTableView {
    /// As a click selects: the row, and the delegate told (SwiftUI's List hears it there).
    func select(row: Int) {
        selectRowIndexes([row], byExtendingSelection: false)
        delegate?.tableViewSelectionDidChange?(Notification(name: NSTableView.selectionDidChangeNotification,
                                                            object: self))
    }
}
