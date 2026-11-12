import AppKit
import BlitterModel
import SwiftUI
import UniformTypeIdentifiers

/// The Tools & Menus tab (#65): the tools, the two context menus, and the action items of the
/// File and Edit menus. What it enters is checked as the file is: written and read back.
struct ToolsSettings: View {
    @Binding var draft: BlitterModel.Settings
    /// What the shortcut fields hold that is no shortcut yet: Save waits for it.
    @Binding var inputProblems: [String: String]
    @Binding var pane: Pane
    @Binding var menuPath: [Int]
    /// The window's count of menu resets: part of each editor's identity (#76).
    let resets: Int
    let reset: (EditableMenu) -> Void

    enum Pane: CaseIterable {
        case tools, itemsMenu, folderMenu, fileMenu, editMenu

        var title: String {
            switch self {
            case .tools: "Tools"
            case .itemsMenu: "Context Menu for Items"
            case .folderMenu: "Context Menu for the Folder"
            case .fileMenu: "File Menu"
            case .editMenu: "Edit Menu"
            }
        }

        /// The menu this pane edits; the tools are none.
        var menu: EditableMenu? {
            switch self {
            case .tools: nil
            case .itemsMenu: .items
            case .folderMenu: .folder
            case .fileMenu: .file
            case .editMenu: .edit
            }
        }

        var note: String {
            switch self {
            case .tools: "Tools open items with an app or run a command line. Every tool is in the Tools menu; "
                + "add it to a context menu to have it there too."
            case .itemsMenu: "Right-click on items. Only the actions that fit what is selected are shown."
            case .folderMenu: "Right-click on empty space in a list, or on a folder in the tree."
            case .fileMenu: "The File menu's items and their shortcuts."
            case .editMenu: "The items after the Edit menu's own (Copy, Paste, Find…)."
            }
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Picker("Edit", selection: $pane) {
                ForEach(Pane.allCases, id: \.self) { Text($0.title).tag($0) }
            }
            .fixedSize()
            HStack(alignment: .firstTextBaseline) {
                Text(pane.note).font(.caption).foregroundStyle(.secondary)
                Spacer()
                if let menu = pane.menu {
                    // #76: a file saved before an action existed keeps the menu it had.
                    Button("Reset to Default") { reset(menu) }
                        .disabled(draft.isDefault(menu))
                        .help("Put this menu back as it comes with Blitter, with any actions added since. "
                            + "Revert undoes it until you save.")
                }
            }
            switch pane {
            case .tools:
                ToolsEditor(settings: $draft)
            case .itemsMenu:
                MenuEditor(menu: $draft.contextMenus.items, choices: draft.actionChoices, path: $menuPath)
                    .id(EditorID(pane: pane, resets: resets))
            case .folderMenu:
                MenuEditor(menu: $draft.contextMenus.folder, choices: draft.actionChoices, path: $menuPath)
                    .id(EditorID(pane: pane, resets: resets))
            case .fileMenu:
                MenuBarEditor(items: $draft.menuBar.file, choices: draft.actionChoices, problem: problem(.file))
                    .id(EditorID(pane: pane, resets: resets))
            case .editMenu:
                MenuBarEditor(items: $draft.menuBar.edit, choices: draft.actionChoices, problem: problem(.edit))
                    .id(EditorID(pane: pane, resets: resets))
            }
        }
        .padding()
        .onChange(of: pane) { menuPath = [] } // each menu starts at its top
    }

    /// The key of what a menu's shortcut field holds that is no shortcut yet; context menus
    /// have no shortcuts.
    static func inputKey(_ menu: EditableMenu) -> String? {
        switch menu {
        case .file: "File menu"
        case .edit: "Edit menu"
        case .items, .folder: nil
        }
    }

    private func problem(_ menu: EditableMenu) -> Binding<String?> {
        let key = Self.inputKey(menu) ?? ""
        return Binding(get: { inputProblems[key] }, set: { inputProblems[key] = $0 })
    }

    /// A menu editor is made anew for another pane, and after a reset.
    private struct EditorID: Hashable {
        let pane: Pane
        let resets: Int
    }
}

/// The tools on the left, the selected one's form on the right.
struct ToolsEditor: View {
    @Binding var settings: BlitterModel.Settings
    @State private var selection: String?
    @State private var newTitle = ""

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 6) {
                List(selection: $selection) {
                    ForEach(settings.tools, id: \.id) { Text($0.title).tag($0.id) }
                }
                HStack(spacing: 4) {
                    TextField("New tool's title", text: $newTitle).onSubmit(add)
                    Button(action: add) { Image(systemName: "plus") }
                        .disabled(newTitle.trimmingCharacters(in: .whitespaces).isEmpty)
                        .help("Add a tool with this title")
                    Button(action: remove) { Image(systemName: "minus") }
                        .disabled(!(selection.map(settings.canRemoveTool) ?? false))
                        .help("Remove the tool, and its entries in the menus")
                }
            }
            .frame(width: 210)
            if let id = selection, let index = settings.tools.firstIndex(where: { $0.id == id }) {
                VStack(alignment: .leading, spacing: 4) {
                    ToolForm(tool: toolBinding(index, id)).id(id)
                    if !settings.canRemoveTool(id) {
                        Text("Blitter's own tools can be changed, not removed; leave them out of the menus instead.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
            } else {
                Text("Select a tool, or add one.").foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .onAppear { selection = selection ?? settings.tools.first?.id }
    }

    /// The tool at `index`, as long as it is still `id` there (a removal may have moved it).
    private func toolBinding(_ index: Int, _ id: String) -> Binding<Tool> {
        let shown = settings.tools[index]
        return Binding(
            get: {
                settings.tools.indices.contains(index) && settings.tools[index].id == id ? settings
                    .tools[index] : shown
            },
            set: { tool in
                if settings.tools.indices.contains(index), settings.tools[index].id == id {
                    settings.tools[index] = tool
                }
            }
        )
    }

    private func add() {
        let title = newTitle.trimmingCharacters(in: .whitespaces)
        guard !title.isEmpty else {
            return
        }
        selection = settings.addTool(title: title)
        newTitle = ""
    }

    private func remove() {
        guard let id = selection else {
            return
        }
        settings.removeTool(id)
        selection = settings.tools.first?.id
    }
}

/// One tool: its title, what it works on, and the app it opens or the command line it runs.
struct ToolForm: View {
    @Binding var tool: Tool
    @State private var runsCommand = false
    /// The file types as typed: "bin, exe"; and the types it was last made from or turned into:
    /// only a change the user typed is written back, so showing a tool never changes it.
    @State private var types = ""
    @State private var shownTypes: [String] = []

    static let scopes: [(ActionScope, String)] = [
        (.selection, "The selected items"), (.files, "The selected files (no folders)"),
        (.selectionOrFolder, "The selection, or the folder when nothing is selected"),
        (.folder, "The side's folder"),
    ]

    /// "bin, .exe Tar.gz" → ["bin", "exe", "tar.gz"]: commas or spaces between, one leading dot
    /// dropped, lowercase, as the settings file keeps them.
    static func fileTypes(_ text: String) -> [String] {
        text.split { $0 == "," || $0.isWhitespace }.map { word in
            let type = word.lowercased()
            return type.hasPrefix(".") ? String(type.dropFirst()) : type
        }.filter { !$0.isEmpty }
    }

    /// Whether the field can show the types as they are: one with a comma or a space in it
    /// would come back as two. Such types are shown, not edited (the settings file can).
    static func fitsField(_ types: [String]) -> Bool {
        !types.contains { $0.contains(",") || $0.contains { $0.isWhitespace } }
    }

    var body: some View {
        Form {
            TextField("Title", text: $tool.title)
            LabeledContent("Name in the settings file") { Text(tool.id).textSelection(.enabled) }
            Picker("Works on", selection: $tool.scope) {
                ForEach(Self.scopes, id: \.0) { Text($0.1).tag($0.0) }
            }
            if tool.scope != .folder, Self.fitsField(tool.extensions) {
                TextField("File types", text: $types, prompt: Text("any, or e.g. bin, exe"))
                Text("With file types, the tool is offered only when every selected item is such a file.")
                    .font(.caption).foregroundStyle(.secondary)
            } else if tool.scope != .folder {
                LabeledContent("File types") {
                    Text(tool.extensions.map { "“\($0)”" }.joined(separator: " "))
                }
                Text("A file type has a comma or a space in it: change them in the settings file.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Picker("It", selection: $runsCommand) {
                Text("opens the items with an app").tag(false)
                Text("runs a command line").tag(true)
            }
            .pickerStyle(.radioGroup)
            if runsCommand {
                Section("The command line, one argument per line") {
                    ArgumentLinesEditor(command: $tool.command)
                    Text("{folder} is the side's folder; {paths}, on a line of its own, the items. It runs in the "
                        + "side's folder as a job, never in a shell.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            } else {
                HStack {
                    TextField("App", text: $tool.app, prompt: Text("name, bundle identifier or path"))
                    Button("Choose…", action: chooseApp)
                }
            }
        }
        .formStyle(.grouped)
        .onAppear {
            runsCommand = !tool.command.isEmpty
            showTypes()
        }
        .onChange(of: runsCommand) {
            if runsCommand {
                tool.app = ""
            } else {
                tool.command = []
            }
        }
        .onChange(of: types) {
            // Types the field cannot show are never edited there; and a text that is what was
            // shown, or a separator typed, is nothing new.
            guard Self.fitsField(shownTypes), Self.fileTypes(types) != shownTypes else {
                return
            }
            shownTypes = Self.fileTypes(types)
            tool.extensions = shownTypes
        }
        .onChange(of: tool) { followRevert() }
    }

    /// The draft changed from outside the form (Revert): show it.
    private func followRevert() {
        if tool.scope == .folder, !tool.extensions.isEmpty {
            tool.extensions = [] // a folder has no file type: the file refuses both together
        }
        if tool.extensions != shownTypes {
            showTypes()
        }
        if !tool.command.isEmpty, !runsCommand {
            runsCommand = true
        } else if !tool.app.isEmpty, runsCommand {
            runsCommand = false
        }
    }

    private func showTypes() {
        shownTypes = tool.extensions
        types = Self.fitsField(shownTypes) ? shownTypes.joined(separator: ", ") : ""
    }

    private func chooseApp() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.application]
        panel.directoryURL = URL(fileURLWithPath: "/Applications", isDirectory: true)
        if panel.runModal() == .OK, let url = panel.url {
            tool.app = url.path
        }
    }
}
