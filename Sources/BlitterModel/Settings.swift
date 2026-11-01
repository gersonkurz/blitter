import Foundation
import TOMLKit

/// The user's configuration from the settings file (TOML). Every entry has a default; a missing
/// file means all defaults. New tickets add their sections here.
public struct Settings: Equatable, Sendable {
    /// How the Date Modified column shows dates, as a Unicode date pattern (#12).
    public var dateFormat = "dd.MM.yyyy HH:mm"
    /// Whether Delete Immediately asks first (#17). Delete Immediately Without Asking never does.
    public var confirmDelete = true
    /// External apps to open items with (#18), in menu order.
    public var tools = Tool.defaults
    /// The file list's context menus (#19).
    public var contextMenus = ContextMenus.defaults
    /// Colors (#21): Base16 schemes for light and dark mode, and the role of each color.
    public var theme = ThemeSettings()

    public init() {}

    /// What `Settings… (⌘,)` creates when there is no file yet: every entry, commented.
    public static let defaultFile = """
    # Blitter settings. Blitter reads this file at launch and again whenever it changes.
    # Anything missing or invalid falls back to its default; problems are shown in the window.

    [files]
    # How the Date Modified column shows dates (Unicode date pattern), e.g. "yyyy-MM-dd HH:mm".
    date_format = "dd.MM.yyyy HH:mm"
    # Whether Delete Immediately (⌥⌘⌫) asks before deleting for good. ⇧⌥⌘⌫ never asks.
    confirm_delete = true

    # External tools: [tools.<id>] opens items with an app (name, bundle identifier or path).
    # on = "folder" opens the side's folder, "selection" the selected items, "files" selected files.
    # Change a default by giving only what differs, e.g. app = "Terminal" for open-in-terminal.
    [tools.open-in-terminal]
    title = "Open in Terminal"
    app = "iTerm"
    on = "folder"

    [tools.open-in-code]
    title = "Open in Code"
    app = "Visual Studio Code"
    on = "folder"

    [tools.open-in-text-editor]
    title = "Open in Text Editor"
    app = "TextEdit"
    on = "files"

    # The file list's context menus: action names in order, "-" for a separator, and
    # { title = "…", items = […] } for a submenu. Only actions that fit what was clicked are shown.
    # Actions: open, quick-look, copy, copy-path, copy-name, rename, copy-to-other-side,
    # move-to-other-side, reveal-in-finder, move-to-trash, delete-immediately,
    # delete-immediately-without-asking, new-folder, and the tools above.
    [context_menu]
    # For the clicked or selected items.
    items = [
        "open", "quick-look", "-",
        "copy-path", "copy-name", "-",
        "rename", "move-to-trash", "delete-immediately", "-",
        "reveal-in-finder", "open-in-terminal", "open-in-code", "open-in-text-editor",
    ]
    # For the folder itself (a click on empty space).
    folder = ["new-folder", "-", "open-in-terminal", "open-in-code"]

    # Colors: a Base16 scheme for light mode and one for dark mode; "system" keeps macOS's colors.
    # Built in: default-dark, default-light, solarized-dark, solarized-light. Add your own as
    # [theme.schemes.<name>] with base00 = "#181818" … base0F = "#a16946".
    [theme]
    light = "system"
    dark = "system"

    # Which of the scheme's 16 colors each role takes.
    [theme.roles]
    background = "base00"
    stripe = "base01"
    selection = "base02"
    text = "base05"
    dim_text = "base04"
    folder = "base0D"
    hidden = "base03"
    symlink = "base0C"
    cloud = "base04"
    package = "base0E"
    error = "base08"

    """

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
        return (settings, problems + checked.problems)
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
        "files": [
            "date_format": { settings, value in
                guard let format = value.string, !format.isEmpty else {
                    return "expected a date pattern such as “dd.MM.yyyy HH:mm”."
                }
                settings.dateFormat = format
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
