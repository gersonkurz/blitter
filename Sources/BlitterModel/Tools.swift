import TOMLKit

/// An external app the user opens items with (#18): an action like any other, defined in the
/// settings file under `[tools.<id>]`. It opens the side's folder, or the selected items, with
/// the app.
public struct Tool: Equatable, Sendable {
    /// The action id; also the key in the settings file.
    public let id: String
    public var title: String
    /// An app name ("iTerm"), bundle identifier ("com.googlecode.iterm2") or path.
    public var app: String
    /// What it opens: `.folder` the side's folder, otherwise the selected items.
    public var scope: ActionScope

    /// iTerm is the owner's choice of terminal (#18); each can be changed in the settings file.
    static let defaults = [
        Tool(id: "open-in-terminal", title: "Open in Terminal", app: "iTerm", scope: .folder),
        Tool(id: "open-in-code", title: "Open in Code", app: "Visual Studio Code", scope: .folder),
        Tool(id: "open-in-text-editor", title: "Open in Text Editor", app: "TextEdit", scope: .files),
    ]

    var action: Action {
        Action(id, title, scope: scope) { [app, scope, title] workspace, side in
            let state = workspace.state(of: side)
            let paths = scope == .folder ? [state.entriesLocation] : workspace.selectedItems(on: side).map(\.path)
            return .openWithApp(app, paths: paths, title: title)
        }
    }

    /// The words for `on` in the settings file.
    private static let scopes: [String: ActionScope] = ["folder": .folder, "selection": .selection, "files": .files]

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
            for (key, value) in entries(definition) {
                if let problem = set(key, value, of: &tool) {
                    problems.append("“\(name).\(key)”: \(problem)")
                    valid = false
                }
            }
            if tool.app.isEmpty {
                problems.append("“\(name)” needs an app, e.g. app = \"TextEdit\".")
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
        case "on":
            guard let word = value?.string, let scope = scopes[word] else {
                return "expected \"folder\", \"selection\" or \"files\"."
            }
            tool.scope = scope
        default:
            return value == nil ? "its name has a control character (such as \\u0000)." : "unknown setting."
        }
        return nil
    }
}
