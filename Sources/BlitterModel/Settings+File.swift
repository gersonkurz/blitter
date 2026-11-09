/// The settings file as text (#64): every entry with its explanation, written from settings.
/// `Settings…` creates the file with the defaults; the Settings window writes the whole file
/// from what it shows (comments of the user's own are not kept — the owner's choice).
/// `parse(fileText(settings))` gives `settings` back, whatever they are.
public extension Settings {
    /// What a new settings file holds: every entry with its default, commented.
    static let defaultFile = fileText(Settings())

    static func fileText(_ settings: Settings) -> String {
        let sections = [
            filesSection,
            favoritesSection,
            fontSection,
            toolsSection,
            menusSection,
            menuBarSection,
            diffSection,
            themeSection,
        ]
        return sections.map { $0(settings) }.joined(separator: "\n\n") + "\n"
    }

    // MARK: Sections

    private static func filesSection(_ settings: Settings) -> String {
        """
        # Blitter settings. Blitter reads this file at launch and again whenever it changes.
        # Anything missing or invalid falls back to its default; problems are shown in the window.

        [files]
        # How the Date Modified column shows dates (Unicode date pattern), e.g. "yyyy-MM-dd HH:mm".
        date_format = \(quoted(settings.dateFormat))
        # Whether Delete Immediately (⌥⌘⌫) asks before deleting for good. ⇧⌥⌘⌫ never asks.
        confirm_delete = \(settings.confirmDelete)
        # The file list's columns, from "name" (always shown), "size", "modified", "kind",
        # "permissions" and "git". A right-click on the list's header shows or hides them per side;
        # "Default Columns" there goes back to this list. Their order is dragged in the header.
        columns = \(list(ListColumn.names(of: settings.columns).map(quoted)))
        # Whether git working copies, and folders in them with changes, are colored by their state.
        # Off, nothing reads git: the Git column stays empty.
        git_colors = \(settings.gitColors)
        """
    }

    private static func favoritesSection(_ settings: Settings) -> String {
        let folders = settings.favorites.map { "folders = " + list($0.map(quoted)) }
            ?? "# folders = [\"~\", \"~/Desktop\", \"~/Documents\", \"~/Downloads\", \"/Applications\"]"
        return """
        # The tree's Favorites, in order; "~" is your home folder. Go > Favorites (ctrl-1 to ctrl-9)
        # goes to them. Without a list here, the Favorites set up in the tree stay as they are; the
        # first change from the tree (Add to Favorites, Move Up/Down, Remove) writes the list here.
        [favorites]
        \(folders)
        """
    }

    private static func fontSection(_ settings: Settings) -> String {
        """
        # The fonts of the file lists and folder trees; dialogs keep the system font. "system" is
        # macOS's own font; or a font family's name, e.g. face = "Helvetica Neue", mono = "Menlo".
        # mono is the fixed-width font of the date and permissions columns. size is in points (8 to 32).
        [font]
        face = \(quoted(settings.font.face ?? "system"))
        mono = \(quoted(settings.font.mono ?? "system"))
        size = \(number(settings.font.size))
        """
    }

    private static func toolsSection(_ settings: Settings) -> String {
        """
        # External tools: [tools.<id>] opens items with an app (name, bundle identifier or path).
        # on = "folder" opens the side's folder, "selection" the selected items, "files" selected files,
        # "selection-or-folder" the selected items or, with nothing selected, the folder.
        # Change a default by giving only what differs, e.g. app = "Terminal" for open-in-terminal.
        # A tool can run a command line instead, as a job, in the side's folder (never in a shell):
        #   [tools.git-fetch]
        #   title = "Git Fetch"
        #   command = ["git", "fetch"]
        #   on = "folder"
        # {folder} stands for the side's folder; {paths}, an argument of its own, for each item.
        # extensions = ["bin", "exe"] offers a tool only when every selected item is such a file.
        \(settings.tools.map(tool).joined(separator: "\n\n"))
        """
    }

    private static func menusSection(_ settings: Settings) -> String {
        """
        # The file list's context menus: action names in order, "-" for a separator, and
        # { title = "…", items = […] } for a submenu. Only actions that fit what was clicked are shown.
        # Actions: open, quick-look, copy, copy-path, copy-name, rename, batch-rename, copy-to-other-side,
        # move-to-other-side, reveal-in-finder, move-to-trash, delete-immediately,
        # delete-immediately-without-asking, new-folder, folder-sizes, copy-folder-path, add-to-favorites,
        # compare-files, compare-folders, undo, git-clone, git-log, git-commit, git-sync and git-clean
        # (only inside a git working copy), and the tools above.
        [context_menu]
        # For the clicked or selected items.
        items = \(menu(settings.contextMenus.items))
        # For the folder itself (a click on empty space).
        folder = \(menu(settings.contextMenus.folder))
        """
    }

    private static func menuBarSection(_ settings: Settings) -> String {
        """
        # The menu bar's action items: the File menu, and the Edit menu after its own items. An entry
        # is an action name, "-" for a separator, or { action = "…", key = "…" } with a shortcut such
        # as "shift+cmd+n", "f2", "opt+cmd+backspace"; alternate = true shows it in place of the item
        # before it while its extra modifier is held.
        [menu_bar]
        file = \(menuBar(settings.menuBar.file))
        edit = \(menuBar(settings.menuBar.edit))
        """
    }

    private static func diffSection(_ settings: Settings) -> String {
        """
        # Compare Files and Compare Folders show the two side by side in a visual diff tool. "auto"
        # takes Beyond Compare if it is installed, else FileMerge (which comes with Xcode). Or a
        # command line with {left} and {right}, e.g. ["bcomp", "{left}", "{right}"].
        [diff]
        tool = \(settings.diffTool.map { list($0.map(quoted)) } ?? "\"auto\"")
        """
    }

    private static func themeSection(_ settings: Settings) -> String {
        """
        # Colors: a Base16 or Base24 scheme for light mode and one for dark mode; "system" keeps
        # macOS's colors. Built in: default-dark, default-light, solarized-dark, solarized-light.
        # Any scheme of https://github.com/tinted-theming/schemes by its name, e.g. "dracula" or
        # "gruvbox-dark-hard": fetched once and kept in the "schemes" folder next to this file.
        # A scheme file: "~/themes/mine.yaml"; or an address: "https://…/mine.yaml".
        # Or your own: [theme.schemes.<name>] with base00 = "#181818" … base0F (… base17 for Base24).
        [theme]
        light = \(quoted(settings.theme.light))
        dark = \(quoted(settings.theme.dark))

        # Which of the scheme's colors each role takes: base00 … base0F, and base10 … base17 (a
        # Base16 scheme has those too, from Base24's fallbacks).
        [theme.roles]
        \(ThemeRole.allCases.map { role($0, settings.theme) }.joined(separator: "\n"))\(schemes(settings.theme))
        """
    }

    private static func role(_ role: ThemeRole, _ theme: ThemeSettings) -> String {
        let slot = theme.slots[role] ?? ThemeRole.defaultSlots[role] ?? 5
        return "\(role.rawValue) = \(quoted(Base24Scheme.slotName(slot)))"
    }

    // MARK: Values

    /// A TOML basic string: quotes, backslashes and control characters escaped.
    static func quoted(_ text: String) -> String {
        var result = "\""
        for scalar in text.unicodeScalars {
            switch scalar {
            case "\"": result += "\\\""
            case "\\": result += "\\\\"
            case "\n": result += "\\n"
            case "\t": result += "\\t"
            case "\r": result += "\\r"
            case _ where scalar.value < 0x20 || scalar.value == 0x7F:
                result += String(format: "\\u%04X", scalar.value)
            default: result.unicodeScalars.append(scalar)
            }
        }
        return result + "\""
    }

    /// A key as is if TOML allows it bare, else quoted.
    private static func key(_ name: String) -> String {
        let bare = !name.isEmpty && name.unicodeScalars.allSatisfy {
            ("a" ... "z").contains($0) || ("A" ... "Z").contains($0) || ("0" ... "9").contains($0) || $0 == "-"
                || $0 == "_"
        }
        return bare ? name : quoted(name)
    }

    private static func number(_ value: Double) -> String {
        value == value.rounded() ? String(Int(value)) : String(value)
    }

    static func list(_ items: [String]) -> String {
        "[" + items.joined(separator: ", ") + "]"
    }

    private static func tool(_ tool: Tool) -> String {
        var lines = tool.id == Tool
            .textEditorID ? ["# Its app also opens this file (Open Settings File, in Settings…)."] : []
        lines.append("[tools.\(key(tool.id))]")
        lines.append("title = \(quoted(tool.title))")
        lines.append(tool.command.isEmpty ? "app = \(quoted(tool.app))" : "command = \(list(tool.command.map(quoted)))")
        lines.append("on = \(quoted(Tool.word(for: tool.scope)))")
        if !tool.extensions.isEmpty {
            lines.append("extensions = \(list(tool.extensions.map(quoted)))")
        }
        return lines.joined(separator: "\n")
    }

    /// One line per group: a line ends after each separator.
    private static func menu(_ entries: [MenuEntry]) -> String {
        guard !entries.isEmpty else {
            return "[]"
        }
        var lines: [String] = []
        var line: [String] = []
        for entry in entries {
            switch entry {
            case let .action(id):
                line.append(quoted(id))
            case .separator:
                line.append("\"-\"")
                lines.append(line.joined(separator: ", "))
                line = []
            case let .submenu(title, items):
                line.append("{ title = \(quoted(title)), items = \(list(items.map(inline))) }")
            }
        }
        if !line.isEmpty {
            lines.append(line.joined(separator: ", "))
        }
        return "[\n" + lines.map { "    " + $0 + "," }.joined(separator: "\n") + "\n]"
    }

    /// A submenu's entry, on one line.
    private static func inline(_ entry: MenuEntry) -> String {
        switch entry {
        case let .action(id): quoted(id)
        case .separator: "\"-\""
        case let .submenu(title, items): "{ title = \(quoted(title)), items = \(list(items.map(inline))) }"
        }
    }

    private static func menuBar(_ items: [MenuBarItem]) -> String {
        guard !items.isEmpty else {
            return "[]"
        }
        let lines = items.map { item in
            switch item {
            case .separator:
                return "\"-\""
            case let .action(id, shortcut, alternate):
                var parts = ["action = \(quoted(id))"]
                if let shortcut {
                    parts.append("key = \(quoted(shortcut.text))")
                }
                if alternate {
                    parts.append("alternate = true")
                }
                return shortcut == nil && !alternate ? quoted(id) : "{ " + parts.joined(separator: ", ") + " }"
            }
        }
        return "[\n" + lines.map { "    " + $0 + "," }.joined(separator: "\n") + "\n]"
    }

    /// The user's own schemes, each a section after the roles.
    private static func schemes(_ theme: ThemeSettings) -> String {
        theme.schemes.keys.sorted().map { name in
            let colors = theme.schemes[name]?.colors ?? []
            let lines = colors.enumerated().map { "\(Base24Scheme.slotName($0)) = \(quoted($1.hex))" }
            return "\n\n[theme.schemes.\(key(name))]\n" + lines.joined(separator: "\n")
        }.joined()
    }
}

extension RGB {
    /// "#7cafc2", as the settings file writes it.
    var hex: String {
        String(format: "#%02x%02x%02x", red, green, blue)
    }
}

public extension Shortcut {
    /// As the settings file writes it: "shift+opt+cmd+backspace", "f2", "ctrl+plus".
    var text: String {
        let order: [(Modifier, String)] = [(.control, "ctrl"), (.shift, "shift"), (.option, "opt"), (.command, "cmd")]
        let keyName = switch key {
        case let .character(character): character == "+" ? "plus" : String(character)
        case let .function(number): "f\(number)"
        case .backspace: "backspace"
        case .forwardDelete: "forwarddelete"
        case .returnKey: "return"
        case .tab: "tab"
        case .space: "space"
        case .escape: "escape"
        case .upArrow: "up"
        case .downArrow: "down"
        case .leftArrow: "left"
        case .rightArrow: "right"
        case .home: "home"
        case .end: "end"
        case .pageUp: "pageup"
        case .pageDown: "pagedown"
        }
        return (order.filter { modifiers.contains($0.0) }.map(\.1) + [keyName]).joined(separator: "+")
    }
}
