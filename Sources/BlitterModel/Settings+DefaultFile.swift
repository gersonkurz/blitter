public extension Settings {
    /// What `Settings… (⌘,)` creates when there is no file yet: every entry, commented.
    static let defaultFile = """
    # Blitter settings. Blitter reads this file at launch and again whenever it changes.
    # Anything missing or invalid falls back to its default; problems are shown in the window.

    [files]
    # How the Date Modified column shows dates (Unicode date pattern), e.g. "yyyy-MM-dd HH:mm".
    date_format = "dd.MM.yyyy HH:mm"
    # Whether Delete Immediately (⌥⌘⌫) asks before deleting for good. ⇧⌥⌘⌫ never asks.
    confirm_delete = true
    # Whether git working copies, and folders in them with changes, are colored by their state.
    git_colors = true

    # External tools: [tools.<id>] opens items with an app (name, bundle identifier or path).
    # on = "folder" opens the side's folder, "selection" the selected items, "files" selected files.
    # Change a default by giving only what differs, e.g. app = "Terminal" for open-in-terminal.
    # A tool can run a command line instead, as a job, in the side's folder (never in a shell):
    #   [tools.git-fetch]
    #   title = "Git Fetch"
    #   command = ["git", "fetch"]
    #   on = "folder"
    # {folder} stands for the side's folder; {paths}, an argument of its own, for each item.
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

    # The menu bar's action items: the File menu, and the Edit menu after its own items. An entry
    # is an action name, "-" for a separator, or { action = "…", key = "…" } with a shortcut such
    # as "shift+cmd+n", "f2", "opt+cmd+backspace"; alternate = true shows it in place of the item
    # before it while its extra modifier is held.
    [menu_bar]
    file = [
        { action = "new-folder", key = "shift+cmd+n" },
        { action = "rename", key = "f2" },
        "-",
        { action = "copy-to-other-side", key = "f5" },
        { action = "move-to-other-side", key = "f6" },
        { action = "reveal-in-finder", key = "opt+cmd+r" },
        "-",
        { action = "move-to-trash", key = "cmd+backspace" },
        { action = "delete-immediately", key = "opt+cmd+backspace" },
        { action = "delete-immediately-without-asking", key = "shift+opt+cmd+backspace", alternate = true },
    ]
    edit = [
        { action = "copy-path", key = "opt+cmd+c" },
        { action = "copy-name", key = "shift+opt+cmd+c" },
    ]

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
    git_clean = "base0B"
    git_modified = "base08"
    git_ahead_behind = "base0A"

    """
}
