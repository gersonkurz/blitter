import TOMLKit

/// A keyboard shortcut as the settings file writes it: modifiers and a key joined by "+", e.g.
/// "shift+cmd+n", "f2", "opt+cmd+backspace". The app turns it into a menu key equivalent.
public struct Shortcut: Equatable, Hashable, Sendable {
    public enum Modifier: String, CaseIterable, Sendable {
        case control, option, shift, command
    }

    public enum Key: Equatable, Hashable, Sendable {
        /// A printable key, lowercase: "n", ",", "[".
        case character(Character)
        /// F1 … F20.
        case function(Int)
        case backspace, forwardDelete, returnKey, tab, space, escape
        case upArrow, downArrow, leftArrow, rightArrow, home, end, pageUp, pageDown
    }

    public let key: Key
    public let modifiers: Set<Modifier>

    public init(_ key: Key, _ modifiers: Set<Modifier> = []) {
        self.key = key
        self.modifiers = modifiers
    }

    private static let modifierNames: [String: Modifier] = [
        "cmd": .command, "command": .command, "⌘": .command,
        "shift": .shift, "⇧": .shift,
        "opt": .option, "option": .option, "alt": .option, "⌥": .option,
        "ctrl": .control, "control": .control, "⌃": .control,
    ]

    private static let keyNames: [String: Key] = [
        "backspace": .backspace, "delete": .backspace, "forwarddelete": .forwardDelete,
        "return": .returnKey, "enter": .returnKey, "tab": .tab, "space": .space,
        "escape": .escape, "esc": .escape, "up": .upArrow, "down": .downArrow, "left": .leftArrow,
        "right": .rightArrow,
        "home": .home, "end": .end, "pageup": .pageUp, "pagedown": .pageDown, "plus": .character("+"),
    ]

    /// Nil if a part is not a modifier or the last part not a key.
    public init?(_ text: String) {
        let parts = text.lowercased().split(separator: "+", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespaces) }
        guard let last = parts.last, !last.isEmpty else {
            return nil
        }
        var modifiers: Set<Modifier> = []
        for part in parts.dropLast() {
            guard let modifier = Self.modifierNames[part], modifiers.insert(modifier).inserted else {
                return nil
            }
        }
        if let named = Self.keyNames[last] {
            key = named
        } else if last.hasPrefix("f"), let number = Int(last.dropFirst()), (1 ... 20).contains(number) {
            key = .function(number)
        } else if last.count == 1, let character = last.first, !character.isWhitespace, !character.isNewline {
            key = .character(character)
        } else {
            return nil
        }
        self.modifiers = modifiers
    }
}

/// One item of a configurable menu in the menu bar (#24): an action, optionally with a shortcut;
/// an alternate item replaces the one before it while its extra modifier is held.
public enum MenuBarItem: Equatable, Sendable {
    case action(String, shortcut: Shortcut?, alternate: Bool)
    case separator
}

/// `[menu_bar]`: the action items of the File menu, and those after the Edit menu's own items.
public struct MenuBarSettings: Equatable, Sendable {
    public var file: [MenuBarItem]
    public var edit: [MenuBarItem]

    /// The menus as they were before they became configurable.
    static let defaults = MenuBarSettings(
        file: [
            item("new-folder", "shift+cmd+n"), item("rename", "f2"), item("batch-rename", "shift+f2"), .separator,
            item("copy-to-other-side", "f5"), item("move-to-other-side", "f6"),
            item("reveal-in-finder", "opt+cmd+r"), item("folder-sizes", "opt+cmd+s"), item("eject", "cmd+e"),
            .separator,
            item("compare-files", "opt+cmd+d"), item("compare-folders", "shift+opt+cmd+d"), .separator,
            item("move-to-trash", "cmd+backspace"), item("delete-immediately", "opt+cmd+backspace"),
            item("delete-immediately-without-asking", "shift+opt+cmd+backspace", alternate: true),
        ],
        edit: [item("copy-path", "opt+cmd+c"), item("copy-name", "shift+opt+cmd+c")]
    )

    private static func item(_ id: String, _ key: String, alternate: Bool = false) -> MenuBarItem {
        .action(id, shortcut: Shortcut(key), alternate: alternate)
    }

    /// Reads one menu's list: "-" is a separator, a string an action without a shortcut, and
    /// `{ action = "…", key = "…", alternate = true }` an action with one. Any problem leaves
    /// the list as it was.
    static func items(_ value: TOMLValueConvertible, at name: String) -> (items: [MenuBarItem], problems: [String]) {
        guard let array = value.array else {
            return ([], ["“\(name)”: expected a list such as [{ action = \"rename\", key = \"f2\" }, \"-\"]."])
        }
        var items: [MenuBarItem] = []
        var problems: [String] = []
        for element in array {
            if let id = element.string {
                items.append(id == "-" ? .separator : .action(id, shortcut: nil, alternate: false))
                continue
            }
            // Every key must find its value: TOMLKit cuts a key at an escaped NUL ("key\u0000x"
            // reads as "key", which then finds nothing), and that must not pass as "no shortcut".
            guard let table = element.table, let id = table["action"]?.string,
                  Set(table.keys).isSubset(of: ["action", "key", "alternate"]),
                  table.keys.count == Set(table.keys).count, table.keys.allSatisfy({ table[$0] != nil })
            else {
                problems.append("“\(name)”: an entry must be an action name, \"-\" or { action = \"…\", key = \"…\" }.")
                continue
            }
            var shortcut: Shortcut?
            if let keyValue = table["key"] {
                guard let text = keyValue.string, let parsed = Shortcut(text) else {
                    problems
                        .append("“\(name)”: “\(id)” has a key that is not a shortcut, e.g. \"shift+cmd+n\" or \"f2\".")
                    continue
                }
                shortcut = parsed
            }
            let alternate = table["alternate"]?.bool
            if table["alternate"] != nil, alternate == nil {
                problems.append("“\(name)”: “\(id)”: alternate must be true or false.")
                continue
            }
            items.append(.action(id, shortcut: shortcut, alternate: alternate ?? false))
        }
        return (problems.isEmpty ? items : [], problems)
    }

    /// Leaves out items naming an action that does not exist, each one reported.
    func keepingKnown(_ known: Set<String>) -> (menus: MenuBarSettings, problems: [String]) {
        var problems: [String] = []
        func filter(_ items: [MenuBarItem], _ name: String) -> [MenuBarItem] {
            items.filter { item in
                guard case let .action(id, _, _) = item, !known.contains(id) else {
                    return true
                }
                problems.append("“\(name)”: there is no action “\(id)”.")
                return false
            }
        }
        return (MenuBarSettings(file: filter(file, "menu_bar.file"), edit: filter(edit, "menu_bar.edit")), problems)
    }
}

public extension Shortcut {
    /// As macOS menus show it: ⌃⌥⇧⌘ in that order, then the key, e.g. "⇧⌘N", "⌥⌘⌫", "F2".
    var glyphs: String {
        let order: [(Modifier, String)] = [(.control, "⌃"), (.option, "⌥"), (.shift, "⇧"), (.command, "⌘")]
        let keyGlyph = switch key {
        case let .character(character): String(character).uppercased()
        case let .function(number): "F\(number)"
        case .backspace: "⌫"
        case .forwardDelete: "⌦"
        case .returnKey: "↩"
        case .tab: "⇥"
        case .space: "Space"
        case .escape: "⎋"
        case .upArrow: "↑"
        case .downArrow: "↓"
        case .leftArrow: "←"
        case .rightArrow: "→"
        case .home: "↖"
        case .end: "↘"
        case .pageUp: "⇞"
        case .pageDown: "⇟"
        }
        return order.filter { modifiers.contains($0.0) }.map(\.1).joined() + keyGlyph
    }
}
