import Foundation
import TOMLKit

/// The user's configuration from the settings file (TOML). Every entry has a default; a missing
/// file means all defaults. New tickets add their sections here.
public struct Settings: Equatable, Sendable {
    /// How the Date Modified column shows dates, as a Unicode date pattern (#12).
    public var dateFormat = "dd.MM.yyyy HH:mm"
    /// The file list's columns for a side whose columns the user has not changed (#25).
    public var columns = ListColumn.defaults
    /// The diff tool's command line with {left} and {right} (#40); nil finds one that is installed.
    public var diffTool: [String]?
    /// Whether Delete Immediately asks first (#17). Delete Immediately Without Asking never does.
    public var confirmDelete = true
    /// Whether folders show their git state as a color (#22).
    public var gitColors = true
    /// External apps to open items with (#18), in menu order.
    public var tools = Tool.defaults
    /// The file list's context menus (#19).
    public var contextMenus = ContextMenus.defaults
    /// Colors (#21): Base16 schemes for light and dark mode, and the role of each color.
    public var theme = ThemeSettings()
    /// The action items of the File and Edit menus, with their shortcuts (#24).
    public var menuBar = MenuBarSettings.defaults
    /// The file lists' and folder trees' fonts (#62).
    public var font = FontSettings()
    /// The tree's Favorites in order (#72), as written ("~" for the home folder). Nil while the
    /// file has none: the favorites set up in the tree before (the saved window state) stay.
    public var favorites: [String]?

    public init() {}

    /// Parses a settings file. Never fails: problems (syntax errors, unknown entries, wrong types)
    /// are listed, and the entries they concern keep their defaults.
    public static func parse(_ text: String) -> (settings: Settings, problems: [String]) {
        var settings = Settings()
        let root: TOMLTable
        do {
            root = try TOMLTable(string: text)
        } catch let error as TOMLParseError {
            return (settings, ["Line \(error.source.begin.line): \(error.description)"])
        } catch {
            return (settings, ["The settings file could not be read: \(error.localizedDescription)"])
        }
        var problems: [String] = []
        for (section, value) in entries(of: root) {
            guard let value else {
                problems.append(unreadableKey(section))
                continue
            }
            guard let table = value.table else {
                problems.append("Unknown setting “\(section)”.")
                continue
            }
            switch section {
            case "context_menu":
                problems += readContextMenus(table, into: &settings)
            case "font":
                problems += readFont(table, into: &settings)
            case "favorites":
                problems += readFavorites(table, into: &settings)
            case "menu_bar":
                problems += readMenuBar(table, into: &settings)
            case "theme":
                problems += settings.theme.apply(table, entries: entries)
            case "tools":
                let reserved = Set(ActionRegistry.builtIn.all.map(\.id))
                problems += Tool.apply(table, to: &settings.tools, reservedIDs: reserved, entries: entries)
            default:
                problems += readSection(section, table, into: &settings)
            }
        }
        // Menus may name tools defined anywhere in the file, so they are checked last.
        let known = Set(ActionRegistry.builtIn.all.map(\.id) + settings.tools.map(\.id))
        let checked = settings.contextMenus.keepingKnown(known)
        settings.contextMenus = checked.menus
        let checkedBar = settings.menuBar.keepingKnown(known)
        settings.menuBar = checkedBar.menus
        return (settings, problems + checked.problems + checkedBar.problems)
    }

    private static func readMenuBar(_ table: TOMLTable, into settings: inout Settings) -> [String] {
        var problems: [String] = []
        for (key, value) in entries(of: table) {
            let name = "menu_bar.\(key)"
            guard let value, key == "file" || key == "edit" else {
                problems.append(value == nil ? unreadableKey(name) : "Unknown setting “\(name)”.")
                continue
            }
            let read = MenuBarSettings.items(value, at: name)
            if read.problems.isEmpty {
                if key == "file" {
                    settings.menuBar.file = read.items
                } else {
                    settings.menuBar.edit = read.items
                }
            }
            problems += read.problems
        }
        return problems
    }

    /// A section of plain entries, each checked by its schema function.
    private static func readSection(_ section: String, _ table: TOMLTable, into settings: inout Settings) -> [String] {
        guard let known = schema[section] else {
            return ["Unknown setting “\(section)”."]
        }
        var problems: [String] = []
        for (key, value) in entries(of: table) {
            guard let value else {
                problems.append(unreadableKey("\(section).\(key)"))
                continue
            }
            guard let apply = known[key] else {
                problems.append("Unknown setting “\(section).\(key)”.")
                continue
            }
            if let problem = apply(&settings, value) {
                problems.append("“\(section).\(key)”: \(problem)")
            }
        }
        return problems
    }

    private static func readFont(_ table: TOMLTable, into settings: inout Settings) -> [String] {
        var problems: [String] = []
        for (key, value) in entries(of: table) {
            let name = "font.\(key)"
            guard let value, FontSettings.keys.contains(key) else {
                problems.append(value == nil ? unreadableKey(name) : "Unknown setting “\(name)”.")
                continue
            }
            if let problem = settings.font.apply(key: key, value: value) {
                problems.append("“\(name)”: \(problem)")
            }
        }
        return problems
    }

    private static func readFavorites(_ table: TOMLTable, into settings: inout Settings) -> [String] {
        var problems: [String] = []
        for (key, value) in entries(of: table) {
            let name = "favorites.\(key)"
            guard let value, key == "folders" else {
                problems.append(value == nil ? unreadableKey(name) : "Unknown setting “\(name)”.")
                continue
            }
            let folders = value.array?.compactMap(\.string) ?? []
            guard let array = value.array, folders.count == array.count, !folders.contains(where: \.isEmpty),
                  !folders.contains(where: { $0.contains("\n") })
            else {
                problems
                    .append("“\(name)”: expected a list of folders such as [\"~\", \"~/Projects\", \"/Volumes/Data\"].")
                continue
            }
            settings.favorites = folders
        }
        return problems
    }

    private static func readContextMenus(_ table: TOMLTable, into settings: inout Settings) -> [String] {
        var problems: [String] = []
        for (key, value) in entries(of: table) {
            let name = "context_menu.\(key)"
            guard let value, key == "items" || key == "folder" else {
                problems.append(value == nil ? unreadableKey(name) : "Unknown setting “\(name)”.")
                continue
            }
            let read = ContextMenus.entries(value, at: name)
            if read.problems.isEmpty {
                if key == "items" {
                    settings.contextMenus.items = read.entries
                } else {
                    settings.contextMenus.folder = read.entries
                }
            }
            problems += read.problems
        }
        return problems
    }

    /// A table's entries in key order. TOMLKit's own iterator is not used: its keys go through C
    /// strings, so a key with an escaped NUL ("bad\u0000key") comes back cut short, and the
    /// iterator crashes when the lookup finds nothing. A cut-short key either finds nothing or —
    /// if it now reads like another key in the table — shows up twice, which the real, unique
    /// keys of a table never do. Either way the entry gets no value, so it is reported, not used.
    private static func entries(of table: TOMLTable) -> [(key: String, value: TOMLValueConvertible?)] {
        let keys = table.keys
        var counts: [String: Int] = [:]
        for key in keys {
            counts[key, default: 0] += 1
        }
        var entries: [(key: String, value: TOMLValueConvertible?)] = []
        for key in counts.keys.sorted() {
            entries.append((key, table[key]))
            for _ in 1 ..< (counts[key] ?? 1) {
                entries.append((key, nil)) // the extra one(s): cut-short keys with this prefix
            }
        }
        return entries
    }

    private static func unreadableKey(_ start: String) -> String {
        "A setting starting with “\(start)” has a control character (such as \\u0000) in its name."
    }

    /// Each known entry with a function that applies its value, or explains why it can't. The
    /// value keeps its TOML type: a date is not a string, a float is not an integer.
    private typealias Entry = @Sendable (inout Settings, TOMLValueConvertible) -> String?
    private static let schema: [String: [String: Entry]] = [
        "diff": [
            "tool": { settings, value in
                if value.string == "auto" {
                    settings.diffTool = nil
                    return nil
                }
                let words = value.array?.compactMap(\.string)
                guard let words, words.count == value.array?.count, let program = words.first, !program.isEmpty,
                      words.contains(where: { $0.contains("{left}") }),
                      words.contains(where: { $0.contains("{right}") })
                else {
                    return "expected \"auto\" or a command line such as [\"bcomp\", \"{left}\", \"{right}\"]."
                }
                settings.diffTool = words
                return nil
            },
        ],
        "files": [
            "date_format": { settings, value in
                guard let format = value.string, !format.isEmpty else {
                    return "expected a date pattern such as “dd.MM.yyyy HH:mm”."
                }
                settings.dateFormat = format
                return nil
            },
            "columns": { settings, value in
                let names = value.array?.compactMap(\.string)
                guard let names, names.count == value.array?.count,
                      names.allSatisfy({ ListColumn(rawValue: $0) != nil })
                else {
                    let known = ListColumn.allCases.map { "\"\($0.rawValue)\"" }.joined(separator: ", ")
                    return "expected a list of columns from \(known)."
                }
                settings.columns = ListColumn.set(named: names)
                return nil
            },
            "git_colors": { settings, value in
                guard let enabled = value.bool else {
                    return "expected true or false."
                }
                settings.gitColors = enabled
                return nil
            },
            "confirm_delete": { settings, value in
                guard let confirm = value.bool else {
                    return "expected true or false."
                }
                settings.confirmDelete = confirm
                return nil
            },
        ],
    ]
}
