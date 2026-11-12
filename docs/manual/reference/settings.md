<!-- Generated from Blitter's code by `just manual`; do not edit. -->
# The settings file

Blitter reads its settings from `~/.config/blitter/settings.toml` at launch and again whenever
the file changes. **Settings…** (⌘,) opens a window for the common ones; **Open Settings File**
there opens the file itself. This is the file Blitter writes when there is none: every
setting with its default and what it means.

```toml
# Blitter settings. Blitter reads this file at launch and again whenever it changes.
# Anything missing or invalid falls back to its default; problems are shown in the window.

[files]
# How the Date Modified column shows dates (Unicode date pattern), e.g. "yyyy-MM-dd HH:mm".
date_format = "dd.MM.yyyy HH:mm"
# Whether Delete Immediately (⌥⌘⌫) asks before deleting for good. ⇧⌥⌘⌫ never asks.
confirm_delete = true
# The file list's columns, from "name" (always shown), "size", "modified", "kind",
# "permissions" and "git". A right-click on the list's header shows or hides them per side;
# "Default Columns" there goes back to this list. Their order is dragged in the header.
columns = ["name", "size", "modified"]
# Whether git working copies, and folders in them with changes, are colored by their state.
# Off, nothing reads git: the Git column stays empty.
git_colors = true

# The tree's Favorites, in order; "~" is your home folder. Go > Favorites (ctrl-1 to ctrl-9)
# goes to them. Without a list here, the Favorites set up in the tree stay as they are; the
# first change from the tree (Add to Favorites, Move Up/Down, Remove) writes the list here.
[favorites]
# folders = ["~", "~/Desktop", "~/Documents", "~/Downloads", "/Applications"]

# The fonts of the file lists and folder trees; dialogs keep the system font. "system" is
# macOS's own font; or a font family's name, e.g. face = "Helvetica Neue", mono = "Menlo".
# mono is the fixed-width font of the date and permissions columns. size is in points (8 to 32).
# folder_style (folders in the lists and trees) and file_style (all other names) are each
# "regular", "bold", "italic" or "bold italic".
[font]
face = "system"
mono = "system"
size = 11
folder_style = "regular"
file_style = "regular"

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
[tools.open-in-terminal]
title = "Open in Terminal"
app = "iTerm"
on = "folder"

[tools.open-in-code]
title = "Open in Code"
app = "Visual Studio Code"
on = "selection-or-folder"

# Its app also opens this file (Open Settings File, in Settings…).
[tools.open-in-text-editor]
title = "Open in Text Editor"
app = "TextEdit"
on = "files"

# The file list's context menus: action names in order, "-" for a separator, and
# { title = "…", items = […] } for a submenu. Only actions that fit what was clicked are shown.
# Actions: open, quick-look, copy, copy-path, copy-name, rename, batch-rename, copy-to-other-side,
# move-to-other-side, reveal-in-finder, move-to-trash, delete-immediately,
# delete-immediately-without-asking, new-folder, folder-sizes, copy-folder-path, add-to-favorites,
# compare-files, compare-folders, undo, git-clone, git-log, git-commit, git-sync and git-clean
# (only inside a git working copy), and the tools above.
[context_menu]
# For the clicked or selected items.
items = [
    "open", "quick-look", "folder-sizes", "-",
    "copy-path", "copy-name", "-",
    "rename", "batch-rename", "move-to-trash", "delete-immediately", "-",
    "compare-files", "git-log", "git-commit", "git-sync", "git-clean", "-",
    "reveal-in-finder", "add-to-favorites", "open-in-terminal", "open-in-code", "open-in-text-editor",
]
# For the folder itself (a click on empty space).
folder = [
    "new-folder", "folder-sizes", "-",
    "copy-folder-path", "add-to-favorites", "compare-folders", "git-clone", "git-log", "git-commit", "git-sync", "git-clean", "-",
    "open-in-terminal", "open-in-code",
]

# The menu bar's action items: the File menu, and the Edit menu after its own items. An entry
# is an action name, "-" for a separator, or { action = "…", key = "…" } with a shortcut such
# as "shift+cmd+n", "f2", "opt+cmd+backspace"; alternate = true shows it in place of the item
# before it while its extra modifier is held.
[menu_bar]
file = [
    { action = "new-folder", key = "shift+cmd+n" },
    { action = "rename", key = "f2" },
    { action = "batch-rename", key = "shift+f2" },
    "-",
    { action = "copy-to-other-side", key = "f5" },
    { action = "move-to-other-side", key = "f6" },
    { action = "reveal-in-finder", key = "opt+cmd+r" },
    { action = "folder-sizes", key = "opt+cmd+s" },
    "-",
    { action = "compare-files", key = "opt+cmd+d" },
    { action = "compare-folders", key = "shift+opt+cmd+d" },
    "-",
    { action = "move-to-trash", key = "cmd+backspace" },
    { action = "delete-immediately", key = "opt+cmd+backspace" },
    { action = "delete-immediately-without-asking", key = "shift+opt+cmd+backspace", alternate = true },
]
edit = [
    { action = "copy-path", key = "opt+cmd+c" },
    { action = "copy-name", key = "shift+opt+cmd+c" },
]

# Compare Files and Compare Folders show the two side by side in a visual diff tool. "auto"
# takes Beyond Compare if it is installed, else FileMerge (which comes with Xcode). Or a
# command line with {left} and {right}, e.g. ["bcomp", "{left}", "{right}"].
[diff]
tool = "auto"

# Colors: a Base16 or Base24 scheme for light mode and one for dark mode; "system" keeps
# macOS's colors. Built in: the schemes Settings… > Colors lists, e.g. "tomorrow-night-blue",
# "nord", "dracula", "solarized-light" (the names of BuiltInScheme.all).
# Any scheme of https://github.com/tinted-theming/schemes by its name, e.g. "dracula" or
# "gruvbox-dark-hard": fetched once and kept in the "schemes" folder next to this file.
# A scheme file: "~/themes/mine.yaml"; or an address: "https://…/mine.yaml".
# Or your own: [theme.schemes.<name>] with base00 = "#181818" … base0F (… base17 for Base24).
[theme]
light = "system"
dark = "system"

# Which of the scheme's colors each role takes: base00 … base0F, and base10 … base17 (a
# Base16 scheme has those too, from Base24's fallbacks).
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
executable = "base0B"
error = "base08"
git_clean = "base0B"
git_modified = "base08"
git_ahead_behind = "base0A"
```

[Back to the contents](../index.md)
