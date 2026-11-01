import BlitterCore

/// What an action works on. Menus offer an action only where its scope fits, and running it
/// checks again, so an action never runs on something it was not made for.
public enum ActionScope: Equatable, Sendable {
    /// The side's folder itself, once it has been read; the selection does not matter.
    case folder
    /// One or more selected items.
    case selection
    /// Exactly one selected item.
    case single

    func fits(_ state: SideState) -> Bool {
        switch self {
        case .folder: state.status == .loaded
        case .selection: !state.selection.isEmpty
        case .single: state.selection.count == 1
        }
    }
}

/// Where an action's result goes, so a caller (the MCP server) knows what to expect from it.
public enum ActionOutput: Equatable, Sendable {
    /// It changes something (files, the view) and returns nothing.
    case none
    /// It puts the selection on the clipboard.
    case clipboard
}

/// A function the user can run on a side: from a menu, a shortcut, or later the MCP server. The
/// settings file and the menus refer to it by `id`. Built-in actions are thin wrappers around
/// commands, so nothing is implemented twice; running one goes through `Command.runAction`.
public struct Action: Sendable {
    public let id: String
    public let title: String
    public let scope: ActionScope
    public let output: ActionOutput
    /// The command that carries the action out on a side whose state fits the scope.
    let command: @MainActor @Sendable (Workspace, Side) -> Command

    init(_ id: String, _ title: String, scope: ActionScope, output: ActionOutput = .none,
         command: @escaping @MainActor @Sendable (Workspace, Side) -> Command)
    {
        self.id = id
        self.title = title
        self.scope = scope
        self.output = output
        self.command = command
    }
}

/// All actions, by id, in the order menus list them by default.
public struct ActionRegistry: Sendable {
    public let all: [Action]
    private let byID: [String: Action]

    init(_ actions: [Action]) {
        all = actions
        byID = Dictionary(actions.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
    }

    public func action(_ id: String) -> Action? {
        byID[id]
    }

    /// The built-in actions; later tickets add their own here (copy path, tools, git, ...).
    static let builtIn = ActionRegistry([
        Action("open", "Open", scope: .single) { workspace, side in
            .open(side, name: workspace.state(of: side).selection.first ?? "")
        },
        Action("quick-look", "Quick Look", scope: .selection) { _, side in .togglePreview(side) },
        Action("copy", "Copy", scope: .selection, output: .clipboard) { _, side in .copyToPasteboard(side) },
        Action("rename", "Rename", scope: .single) { _, side in .requestRename(side) },
        Action("copy-to-other-side", "Copy to Other Side", scope: .selection) { workspace, side in
            .copyItems(workspace.selectedItems(on: side).map(\.path),
                       toFolder: workspace.state(of: side.opposite).location)
        },
        Action("move-to-other-side", "Move to Other Side", scope: .selection) { workspace, side in
            .moveItems(workspace.selectedItems(on: side).map(\.path),
                       toFolder: workspace.state(of: side.opposite).location)
        },
        Action("reveal-in-finder", "Reveal in Finder", scope: .selection) { _, side in .revealInFinder(side) },
        Action("move-to-trash", "Move to Trash", scope: .selection) { _, side in .trashSelection(side) },
        Action("new-folder", "New Folder", scope: .folder) { _, side in .newFolder(side) },
    ])
}

public extension Workspace {
    /// The actions whose scope fits the side as it is now: what a menu for it offers.
    func actions(for side: Side) -> [Action] {
        let state = state(of: side)
        return actionRegistry.all.filter { $0.scope.fits(state) }
    }

    /// Whether `perform(.runAction(id, side))` would run the action now.
    func canRun(_ id: String, on side: Side) -> Bool {
        actionRegistry.action(id)?.scope.fits(state(of: side)) == true
    }

    internal func runAction(_ id: String, on side: Side) -> Bool {
        guard let action = actionRegistry.action(id), action.scope.fits(state(of: side)) else {
            return false
        }
        return apply(action.command(self, side))
    }
}
