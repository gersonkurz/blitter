import TOMLKit

/// One entry of a menu the user configures (#19): an action by id, a separator, or a submenu.
public enum MenuEntry: Equatable, Sendable {
    case action(String)
    case separator
    case submenu(String, [MenuEntry])
}

/// The file list's context menus, from `[context_menu]` in the settings file: one for the
/// clicked or selected items, one for the side's folder (a click on empty space).
public struct ContextMenus: Equatable, Sendable {
    public var items: [MenuEntry]
    public var folder: [MenuEntry]

    static let defaults = ContextMenus(
        items: [
            .action("open"), .action("quick-look"), .separator,
            .action("copy-path"), .action("copy-name"), .separator,
            .action("rename"), .action("move-to-trash"), .action("delete-immediately"), .separator,
            .action("compare-files"), .separator,
            .action("reveal-in-finder"), .action("open-in-terminal"), .action("open-in-code"),
            .action("open-in-text-editor"),
        ],
        folder: [
            .action("new-folder"), .separator, .action("copy-folder-path"), .action("compare-folders"), .separator,
            .action("open-in-terminal"), .action("open-in-code"),
        ]
    )

    /// Reads one menu: strings are action ids ("-" is a separator), an inline table
    /// `{ title = "…", items = […] }` is a submenu. Problems are listed; the entry is left out.
    static func entries(_ value: TOMLValueConvertible, at name: String) -> (entries: [MenuEntry], problems: [String]) {
        guard let array = value.array else {
            return ([], ["“\(name)”: expected a list such as [\"open\", \"-\", \"rename\"]."])
        }
        var entries: [MenuEntry] = []
        var problems: [String] = []
        for element in array {
            if let id = element.string {
                entries.append(id == "-" ? .separator : .action(id))
            } else if let table = element.table, let title = table["title"]?.string, !title.isEmpty,
                      let items = table["items"], table.keys.count == 2
            {
                let inner = Self.entries(items, at: "\(name) › \(title)")
                entries.append(.submenu(title, inner.entries))
                problems += inner.problems
            } else {
                problems.append("“\(name)”: an entry must be an action name, \"-\" or { title = \"…\", items = […] }.")
            }
        }
        return (entries, problems)
    }

    /// Leaves out entries naming an action that does not exist, each one reported.
    func keepingKnown(_ known: Set<String>) -> (menus: ContextMenus, problems: [String]) {
        var problems: [String] = []
        func filter(_ entries: [MenuEntry], _ name: String) -> [MenuEntry] {
            entries.compactMap { entry in
                switch entry {
                case let .action(id) where !known.contains(id):
                    problems.append("“\(name)”: there is no action “\(id)”.")
                    return nil
                case let .submenu(title, inner):
                    return .submenu(title, filter(inner, "\(name) › \(title)"))
                default:
                    return entry
                }
            }
        }
        let menus = ContextMenus(items: filter(items, "context_menu.items"),
                                 folder: filter(folder, "context_menu.folder"))
        return (menus, problems)
    }
}

/// A menu ready to show: only actions that can run now, no empty submenus, and separators only
/// between entries.
public enum ShownMenuEntry: Equatable, Sendable {
    case action(id: String, title: String)
    case separator
    case submenu(String, [ShownMenuEntry])
}

public extension Workspace {
    /// The context menu for the side as it is now: for its selection, or for its folder.
    func contextMenu(for side: Side, folder: Bool) -> [ShownMenuEntry] {
        shown(folder ? settings.contextMenus.folder : settings.contextMenus.items) { canRun($0.id, on: side) }
    }

    /// The tree's menu for a folder (#20): the folder menu's folder actions. They fit any folder,
    /// and run once the side shows it (`Command.runFolderAction`).
    func treeContextMenu() -> [ShownMenuEntry] {
        shown(settings.contextMenus.folder) { $0.scope.worksOnFolder }
    }

    private func shown(_ entries: [MenuEntry], where fits: (Action) -> Bool) -> [ShownMenuEntry] {
        var result: [ShownMenuEntry] = []
        for entry in entries {
            switch entry {
            case let .action(id):
                if let action = actionRegistry.action(id), fits(action) {
                    result.append(.action(id: id, title: action.title))
                }
            case .separator:
                if let last = result.last, last != .separator {
                    result.append(.separator)
                }
            case let .submenu(title, inner):
                let items = shown(inner, where: fits)
                if !items.isEmpty {
                    result.append(.submenu(title, items))
                }
            }
        }
        if result.last == .separator {
            result.removeLast()
        }
        return result
    }
}
