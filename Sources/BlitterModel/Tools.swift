import TOMLKit

/// An external tool (#18, #30): an action like any other, defined in the settings file under
/// `[tools.<id>]`. It opens the side's folder, or the selected items, with an app — or runs a
/// command line in the side's folder, as a job.
public struct Tool: Equatable, Sendable {
    /// The action id; also the key in the settings file.
    public let id: String
    public var title: String
    /// An app name ("iTerm"), bundle identifier ("com.googlecode.iterm2") or path.
    public var app: String
    /// What it opens: `.folder` the side's folder, otherwise the selected items.
    public var scope: ActionScope
    /// A command line instead of an app (#30): the program, then its arguments. `{folder}` is
    /// the side's folder (also inside an argument); `{paths}`, an argument of its own, becomes
    /// one argument per item (the folder, for a folder tool). Never run through a shell.
    public var command: [String] = []
    /// File types it is for (#65), as name endings without the dot, lowercase: "bin", "tar.gz".
    /// Empty: any item. Otherwise it is offered, and runs, only when every selected item is a
    /// file whose name ends in one of them.
    public var extensions: [String] = []

    public init(id: String, title: String, app: String, scope: ActionScope, command: [String] = [],
                extensions: [String] = [])
    {
        self.id = id
        self.title = title
        self.app = app
        self.scope = scope
        self.command = command
        self.extensions = extensions
    }

    /// The text editor tool's app also opens the settings file (#36).
    static let textEditorID = "open-in-text-editor"
    /// The terminal tool also opens a working copy whose rebase stopped (#45).
    static let terminalID = "open-in-terminal"

    /// iTerm is the owner's choice of terminal (#18); each can be changed in the settings file.
    static let defaults = [
        Tool(id: terminalID, title: "Open in Terminal", app: "iTerm", scope: .folder),
        Tool(id: "open-in-code", title: "Open in Code", app: "Visual Studio Code", scope: .selectionOrFolder),
        Tool(id: textEditorID, title: "Open in Text Editor", app: "TextEdit", scope: .files),
    ]

    /// Blitter's own tools' icons in the toolbar (#88). Any other tool shows what it does: opens
    /// an app, or runs a command line.
    static let symbols = [
        terminalID: "apple.terminal",
        "open-in-code": "chevron.left.forwardslash.chevron.right",
        textEditorID: "doc.text",
    ]

    var action: Action {
        let effect: ActionEffect = command.isEmpty ? .opens : .changes
        let (app, scope, title, command) = (app, scope, title, command)
        let symbol = Self.symbols[id] ?? (command.isEmpty ? "app.badge" : "terminal")
        return Action(id, title, scope: scope, effect: effect, fileTypes: extensions,
                      symbol: symbol)
        { workspace, side in
            let folder = workspace.state(of: side).entriesLocation
            let selected = workspace.selectedItems(on: side).map(\.path)
            let usesFolder = scope == .folder || (scope == .selectionOrFolder && selected.isEmpty)
            let paths = usesFolder ? [folder] : selected
            if !command.isEmpty {
                return .runCommand(Self.arguments(command, folder: folder, paths: paths), folder: folder)
            }
            return .openWithApp(app, paths: paths, title: title)
        }
    }

    /// The command line with its placeholders filled in; the result goes to the program as is.
    static func arguments(_ command: [String], folder: String, paths: [String]) -> [String] {
        command.flatMap { argument in
            argument == "{paths}" ? paths : [argument.replacingOccurrences(of: "{folder}", with: folder)]
        }
    }

    /// The words for `on` in the settings file.
    static let scopes: [String: ActionScope] = [
        "folder": .folder, "selection": .selection, "files": .files, "selection-or-folder": .selectionOrFolder,
    ]

    /// The settings file's word for a tool's scope (a tool has only these four).
    static func word(for scope: ActionScope) -> String {
        scopes.first { $0.value == scope }?.key ?? "selection"
    }

    /// Applies `[tools.<id>]` to the tools: a known id changes only the entries given, a new id
    /// needs at least `app`. Problems are listed; a tool with one keeps its previous definition.
    static func apply(_ table: TOMLTable, to tools: inout [Tool], reservedIDs: Set<String>,
                      entries: (TOMLTable) -> [(key: String, value: TOMLValueConvertible?)]) -> [String]
    {
        var problems: [String] = []
        for (id, value) in entries(table) {
            let name = "tools.\(id)"
            guard let definition = value?.table else {
                problems.append("“\(name)” must be a section with app, title and on.")
                continue
            }
            guard !reservedIDs.contains(id) else {
                problems.append("“\(name)”: “\(id)” is the name of a built-in action.")
                continue
            }
            let existing = tools.firstIndex { $0.id == id }
            var tool = existing.map { tools[$0] } ?? Tool(id: id, title: id, app: "", scope: .selection)
            var valid = true
            let keys = Set(entries(definition).map(\.key))
            if keys.contains("app"), keys.contains("command") {
                problems.append("“\(name)”: give an app or a command, not both.")
                valid = false
            }
            for (key, value) in entries(definition) {
                if let problem = set(key, value, of: &tool) {
                    problems.append("“\(name).\(key)”: \(problem)")
                    valid = false
                }
            }
            if !tool.extensions.isEmpty, tool.scope == .folder {
                problems.append("“\(name)”: extensions need on = \"files\", \"selection\" or \"selection-or-folder\".")
                valid = false
            }
            if tool.app.isEmpty, tool.command.isEmpty {
                problems.append("“\(name)” needs an app, e.g. app = \"TextEdit\", "
                    + "or a command, e.g. command = [\"git\", \"fetch\"].")
                valid = false
            }
            guard valid else {
                continue
            }
            if let existing {
                tools[existing] = tool
            } else {
                tools.append(tool)
            }
        }
        return problems
    }

    private static func set(_ key: String, _ value: TOMLValueConvertible?, of tool: inout Tool) -> String? {
        switch key {
        case "title":
            guard let title = value?.string, !title.isEmpty else {
                return "expected a name for the menu."
            }
            tool.title = title
        case "app":
            guard let app = value?.string, !app.isEmpty else {
                return "expected an app name, bundle identifier or path."
            }
            tool.app = app
            tool.command = [] // an app replaces a command
        case "command":
            guard let array = value?.array else {
                return "expected a list such as [\"git\", \"-C\", \"{folder}\", \"fetch\"]."
            }
            let command = array.compactMap(\.string)
            guard command.count == array.count, let program = command.first, !program.isEmpty else {
                return "expected a list of strings, the program first."
            }
            guard !command.contains(where: { $0 != "{paths}" && $0.contains("{paths}") }) else {
                return "{paths} must be an argument of its own (it becomes one argument per item)."
            }
            tool.command = command
            tool.app = "" // a command replaces an app
        case "extensions":
            let words = value?.array?.compactMap(\.string) ?? []
            // One leading dot may be written ("bin" or ".bin"); what is kept has none, so it is
            // read back the same after the file is written: "..bin" and ".." are refused.
            let types = words.map { ($0.hasPrefix(".") ? String($0.dropFirst()) : $0).lowercased() }
            guard let array = value?.array, words.count == array.count, !types.isEmpty,
                  types.allSatisfy({ !$0.isEmpty && !$0.hasPrefix(".") && !$0.contains("/") })
            else {
                return "expected a list of file name endings such as [\"bin\", \"exe\", \"tar.gz\"]."
            }
            tool.extensions = types
        case "on":
            guard let word = value?.string, let scope = scopes[word] else {
                return "expected \"folder\", \"selection\", \"files\" or \"selection-or-folder\"."
            }
            tool.scope = scope
        default:
            return value == nil ? "its name has a control character (such as \\u0000)." : "unknown setting."
        }
        return nil
    }
}

public extension Workspace {
    /// What opens `folder` with the terminal tool, as the settings file defines it: its command
    /// line as a job, or its app. Nil if there is no such tool.
    func terminalCommand(for folder: String) -> Command? {
        guard let tool = settings.tools.first(where: { $0.id == Tool.terminalID }) else {
            return nil
        }
        return tool.command.isEmpty ? .openWithApp(tool.app, paths: [folder], title: tool.title)
            : .runCommand(Tool.arguments(tool.command, folder: folder, paths: [folder]), folder: folder)
    }
}
