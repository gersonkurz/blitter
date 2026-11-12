import Foundation

// What the Settings window's Tools & Menus tab (#65) does to the settings it edits. The checks
// stay those of the file: whatever the tab enters is written and read back (`Settings.problems`).

/// An action a menu can list: a built-in one or a tool, by its name in the settings file.
public struct ActionChoice: Equatable, Sendable, Identifiable {
    public let id: String
    public let title: String
}

public extension Settings {
    /// Every action the menus can list, built-in ones first, then these settings' tools.
    var actionChoices: [ActionChoice] {
        ActionRegistry.builtIn.all.map { ActionChoice(id: $0.id, title: $0.title) }
            + tools.map { ActionChoice(id: $0.id, title: $0.title) }
    }

    /// A new tool, titled `title`, at the end of the tools; its name in the settings file is made
    /// from the title and is free (not a built-in action, not another tool). It has no app yet:
    /// the window shows that as a problem until one is given. Returns its name.
    @discardableResult
    mutating func addTool(title: String) -> String {
        let id = Self.freeToolID(for: title, taken: Set(actionChoices.map(\.id)))
        tools.append(Tool(id: id, title: title, app: "", scope: .selection))
        return id
    }

    /// Whether the tool can be removed: Blitter's own tools always exist (the file can only
    /// change them), so they can only be left out of the menus.
    func canRemoveTool(_ id: String) -> Bool {
        tools.contains { $0.id == id } && !Tool.defaults.contains { $0.id == id }
    }

    /// Removes the tool, and every menu entry naming it, so no menu names an action that is gone.
    mutating func removeTool(_ id: String) {
        guard canRemoveTool(id) else {
            return
        }
        tools.removeAll { $0.id == id }
        contextMenus.items = contextMenus.items.removingAction(id)
        contextMenus.folder = contextMenus.folder.removingAction(id)
        menuBar.file.removeAll { $0.actionID == id }
        menuBar.edit.removeAll { $0.actionID == id }
    }

    /// "Open with Hex Editor" → "open-with-hex-editor", "Öffnen" → "offnen"; "tool" if nothing is left; "-2", "-3"...
    /// until the name is free.
    internal static func freeToolID(for title: String, taken: Set<String>) -> String {
        var words: [String] = []
        var word = ""
        for scalar in title.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil).unicodeScalars {
            if ("a" ... "z").contains(scalar) || ("0" ... "9").contains(scalar) {
                word.unicodeScalars.append(scalar)
            } else if !word.isEmpty {
                words.append(word)
                word = ""
            }
        }
        if !word.isEmpty {
            words.append(word)
        }
        let base = words.isEmpty ? "tool" : words.joined(separator: "-")
        var id = base
        var number = 2
        while taken.contains(id) {
            id = "\(base)-\(number)"
            number += 1
        }
        return id
    }
}

public extension [MenuEntry] {
    /// The entries of the submenu at `path`: the positions of the submenus on the way, outermost
    /// first; `[]` is the menu itself. A path that leads to no submenu reads as empty, and
    /// setting it changes nothing.
    subscript(submenu path: [Int]) -> [MenuEntry] {
        get {
            guard let first = path.first else {
                return self
            }
            guard indices.contains(first), case let .submenu(_, inner) = self[first] else {
                return []
            }
            return inner[submenu: [Int](path.dropFirst())]
        }
        set {
            guard let first = path.first else {
                self = newValue
                return
            }
            guard indices.contains(first), case .submenu(let title, var inner) = self[first] else {
                return
            }
            inner[submenu: [Int](path.dropFirst())] = newValue
            self[first] = .submenu(title, inner)
        }
    }

    /// The longest start of `path` that still leads through submenus, e.g. after the menu changed
    /// (Revert, a removal) under an editor that showed a submenu.
    func validSubmenuPath(_ path: [Int]) -> [Int] {
        guard let first = path.first, indices.contains(first), case let .submenu(_, inner) = self[first] else {
            return []
        }
        return [first] + inner.validSubmenuPath([Int](path.dropFirst()))
    }

    /// The titles of the submenus along a valid path, outermost first.
    func submenuTitles(_ path: [Int]) -> [String] {
        guard let first = path.first, indices.contains(first), case let .submenu(title, inner) = self[first] else {
            return []
        }
        return [title] + inner.submenuTitles([Int](path.dropFirst()))
    }

    /// The same menu without any entry naming `id`, in submenus too.
    func removingAction(_ id: String) -> [MenuEntry] {
        compactMap { entry in
            switch entry {
            case .action(id): nil
            case let .submenu(title, inner): .submenu(title, inner.removingAction(id))
            default: entry
            }
        }
    }
}

extension MenuBarItem {
    var actionID: String? {
        if case let .action(id, _, _) = self {
            return id
        }
        return nil
    }
}

extension Settings {
    /// `applying`'s part for the tools: each tool is an entry of its own, by name. One the
    /// window added, changed or removed is taken; the others stay as the file has them.
    static func tools(_ current: [Tool], changesFrom original: [Tool], to edited: [Tool]) -> [Tool] {
        var result = current
        var ids = original.map(\.id)
        ids += edited.map(\.id).filter { !ids.contains($0) }
        for id in ids {
            let before = original.first { $0.id == id }
            let after = edited.first { $0.id == id }
            guard before != after else {
                continue
            }
            let index = result.firstIndex { $0.id == id }
            switch (after, index) {
            case let (after?, index?): result[index] = after
            case let (after?, nil): result.append(after)
            case let (nil, index?): result.remove(at: index)
            case (nil, nil): break
            }
        }
        return result
    }
}

/// A menu the Tools & Menus tab edits.
public enum EditableMenu: CaseIterable, Sendable {
    case items, folder, file, edit
}

public extension Settings {
    /// Puts `menu` back as it comes with Blitter (#76): a file saved before an action existed
    /// keeps the menus it had, and this is the way to the new ones. A default entry naming a tool
    /// these settings no longer have is left out, as the file would.
    mutating func resetToDefault(_ menu: EditableMenu) {
        let known = Set(actionChoices.map(\.id))
        switch menu {
        case .items: contextMenus.items = ContextMenus.defaults.keepingKnown(known).menus.items
        case .folder: contextMenus.folder = ContextMenus.defaults.keepingKnown(known).menus.folder
        case .file: menuBar.file = MenuBarSettings.defaults.keepingKnown(known).menus.file
        case .edit: menuBar.edit = MenuBarSettings.defaults.keepingKnown(known).menus.edit
        }
    }

    /// Whether `menu` is as it comes with Blitter already.
    func isDefault(_ menu: EditableMenu) -> Bool {
        var reset = self
        reset.resetToDefault(menu)
        return reset == self
    }
}
