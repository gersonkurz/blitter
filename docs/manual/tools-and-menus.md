# Tools and menus

Everything Blitter does to files is an [action](reference/actions.md), with a name such as
`copy-to-other-side` or `move-to-trash`. Tools you define are actions too. The context menus and
the menu bar's File and Edit menus list actions by name, so you decide what is in them and in
what order.

All of this is set in the [settings file](settings.md); **Open Settings File** in Settings…
opens it. Blitter applies a change as soon as you save the file. A mistake is listed at the
bottom of the window, and the rest of the file still applies.

## Tools

A tool opens items with an app, or runs a command line. Each one is a section
`[tools.<name>]`:

| Key | Meaning |
|---|---|
| `title` | the name in the menus |
| `app` | an app's name (`"Hex Fiend"`), bundle identifier or path |
| `command` | instead of `app`: a command line, e.g. `["git", "fetch"]` |
| `on` | what it acts on: `"folder"` (the side's folder), `"selection"` (the selected items), `"files"` (selected files, no folders), `"selection-or-folder"` (the selection, or the folder when nothing is selected) |
| `extensions` | only for these file types, e.g. `["bin", "exe"]`: the tool is offered only when every selected item is such a file |

Three tools come with Blitter: `open-in-terminal` (iTerm), `open-in-code` (Visual Studio Code)
and `open-in-text-editor` (TextEdit, which also opens the settings file). To change one, give
only what differs:

```toml
[tools.open-in-terminal]
app = "Terminal"
```

Every tool is in the menu bar's **Tools** menu. To have it in a context menu too, add its name
there (see below).

### Command lines

A command line runs as a job in the side's folder, with Cancel in the jobs strip. It is never
run through a shell, so `*`, `|` and `$HOME` mean nothing special.

- `{folder}` stands for the side's folder, also inside an argument.
- `{paths}`, as an argument of its own, becomes one argument per selected item.
- Programs are looked for in `/opt/homebrew/bin`, `/usr/local/bin`, `~/.local/bin`, `/usr/bin`,
  `/bin`, `/usr/sbin` and `/sbin`, or give the full path.

### Examples

Open binaries with a hex editor, offered only for `.bin` and `.exe` files:

```toml
[tools.hex-editor]
title = "Open with Hex Editor"
app = "Hex Fiend"
on = "files"
extensions = ["bin", "exe"]
```

Compare the two items selected on one side with Beyond Compare, two folders included (this
needs Beyond Compare's command-line tool `bcomp`; the job ends when `bcomp` returns):

```toml
[tools.compare-selected]
title = "Compare with Beyond Compare"
command = ["bcomp", "{paths}"]
on = "selection"
```

To compare the two **sides'** folders, no tool is needed: **Compare Folders** (**⌥⇧⌘D**) uses
Beyond Compare when it is installed.

## Context menus

`[context_menu]` has two lists:

- `items`: the menu for the clicked or selected items;
- `folder`: the menu for the side's folder, shown by a right-click on empty space in the list,
  and on a folder in the tree.

Each entry is an action name, `"-"` for a separator, or `{ title = "…", items = […] }` for a
submenu. A menu shows only the actions that fit what was clicked; Git Log, for example, appears
only inside a git working copy. A list replaces the default list as a whole: copy the default
from the [reference](reference/settings.md) and change it.

```toml
[context_menu]
items = [
    "open", "quick-look", "-",
    "rename", "move-to-trash", "-",
    { title = "Open With", items = ["hex-editor", "open-in-code", "open-in-text-editor"] },
    "compare-selected",
]
```

## The menu bar

`[menu_bar]` lists the File menu's items (`file`) and the items at the end of the Edit menu
(`edit`). An entry is an action name, `"-"`, or an action with a shortcut:

```toml
{ action = "copy-to-other-side", key = "f5" }
```

- Keys are written like `"shift+cmd+n"`, `"f2"` or `"opt+cmd+backspace"`; modifiers are `cmd`,
  `shift`, `opt` and `ctrl`.
- `alternate = true` shows the item in place of the one before it while its extra modifier is
  held, as Delete Immediately Without Asking does.

The [default shortcuts](reference/shortcuts.md) are those Blitter starts with.

[Back to the contents](index.md)
