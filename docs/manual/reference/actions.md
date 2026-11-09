<!-- Generated from Blitter's code by `just manual`; do not edit. -->
# Actions

Everything Blitter can do to files and folders is an action. Menus — the context menus and
the menu bar's File and Edit menus — list actions by their name in the settings file, and
a menu shows an action only where it fits what is selected. Tools you define in the
settings file are actions too, named by their `[tools.<name>]`.

| Name | Title | Works on |
|---|---|---|
| `open` | Open | one selected item |
| `quick-look` | Quick Look | the selected items |
| `copy` | Copy | the selected items |
| `copy-path` | Copy Path | the selected items |
| `copy-name` | Copy Name | the selected items |
| `rename` | Rename | one selected item |
| `batch-rename` | Batch Rename… | the selected items |
| `copy-to-other-side` | Copy to Other Side | the selected items |
| `move-to-other-side` | Move to Other Side | the selected items |
| `reveal-in-finder` | Reveal in Finder | the selected items |
| `move-to-trash` | Move to Trash | the selected items |
| `delete-immediately` | Delete Immediately | the selected items |
| `delete-immediately-without-asking` | Delete Immediately Without Asking | the selected items |
| `folder-sizes` | Calculate Folder Sizes | the selected folders, or every folder when nothing is selected |
| `new-folder` | New Folder | the side's folder |
| `copy-folder-path` | Copy Path | the side's folder |
| `compare-files` | Compare Files | two files: two selected on one side, or one on each side |
| `git-clone` | Git Clone… | the side's folder |
| `git-log` | Git Log… | the folder or its one selected item, inside a git working copy |
| `git-sync` | Git Sync… | the folder or its one selected item, inside a git working copy |
| `git-commit` | Git Commit… | the folder or its one selected item, inside a git working copy |
| `undo` | Undo | the last file operation, while one can be undone |
| `compare-folders` | Compare Folders | both sides' folders |

[Back to the contents](../index.md)
