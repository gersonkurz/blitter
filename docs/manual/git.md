# Git

Blitter shows where git working copies stand, and has windows for the log, a commit and syncing
with the remote. It needs git from Xcode or the Command Line Tools
(`xcode-select --install`); without it, Blitter shows nothing of git and never asks to install
it.

## Colors

In the file list and the tree, items in a working copy are colored by their git state:

| Color | Meaning |
|---|---|
| green | tracked and unchanged; a working copy with nothing to commit and in step with its upstream |
| red | a tracked file that changed, or a folder with such a file somewhere below it |
| orange | a working copy with nothing to commit, but commits ahead of or behind its upstream |

Untracked and ignored items keep their usual color. The colors are the theme's `git_clean`,
`git_modified` and `git_ahead_behind` [roles](settings.md#colors). Blitter reads the state
after every listing and again from time to time, because changes deep inside a working copy
reach no shown folder.

The **Git** column (right-click the list's header) says it in words: Unchanged, Modified,
Untracked, Ignored, or ↑2 ↓1 for commits ahead and behind.

**Color git working copies by their state** in [Settings](settings.md) turns all of this off;
then Blitter does not run git at all.

## Git Clone

**Git Clone…** clones a repository into a folder. It is in the folder's context menu (a
right-click on empty space in a list, or on a folder in the tree), in any folder, not only in a
working copy.

- **Repository**: the address, e.g. `https://github.com/me/project.git` or
  `git@github.com:me/project.git`. A folder on your Mac works too.
- **Folder name**: taken from the address until you type one of your own.
- **Clone** runs git as a job (in the strip at the bottom, with Cancel); the window shows git's
  output. When it is done, the window closes and the new folder is selected (a fast filter that would
  hide it ends). If it fails, the
  window says why.

Git runs without a terminal to ask in: for a private repository, the credentials must come from
your SSH keys or the macOS keychain, as for Git Sync.

## Git Clean

**Git Clean…** (in the context menus, inside a working copy) removes what git does not track,
in the selected folder, or in the side's folder.

- The window always shows first what would go: git's own list (`git clean -n`), so it is never a
  surprise. **Untracked folders too** (`-d`, on to start with) and **Ignored files too** (`-x`)
  change the list at once.
- **Move to Trash** (Return) moves exactly the files shown to the Trash, gathered in one folder
  named "Git Clean" with the date, at their paths; folders emptied that way are removed. **⌘Z**
  puts everything back where it was, the folders with their permissions and attributes. If the
  Trash refuses, everything is put back at once.
- **Delete for Good…** deletes them right away, without the Trash. It asks first; **Ask before
  Delete Immediately** in [Settings](settings.md) turns the question off here too.
- Only the items shown are touched, never what turned up after the list was made, also inside a
  listed folder: a folder goes only once it is empty, and one that something was added to stays
  (the job says so). Repositories inside the folder are left alone; the window says how many.

## Git Log, Git Commit and Git Sync

All three are in the context menus, inside a working copy. They act on the one selected item,
or on the side's folder when nothing is selected. With several items selected they are not
offered: select one, or clear the selection for the folder.

- **Git Log…**: the commits, newest first, with a filter by message, author or hash. Select a
  commit to see the files it changed; a double-click (or **Return**) on a file shows it before
  and after in the [compare tool](file-operations.md#compare). For a file or a folder, the log
  shows only the commits that changed it.
- **Git Commit…**: the changed and untracked files, each with a checkbox. **Space** checks or
  unchecks the selected files; **Check All** and **Uncheck All** do all of them. A
  double-click shows a file's changes in the compare tool. Write the message, or pick one under
  **Recent Messages**, then **Commit** or **Commit & Push**. Only the checked files are
  committed.
- **Git Sync…**: the branch, its upstream, how far ahead or behind it is, and the last fetch.
  **Fetch**, **Pull (rebase)**, **Fetch & Rebase** and **Push** run as jobs; their output shows
  in the window. Blitter never pushes with `--force`: a rejected push is shown, not retried. If
  a rebase stops on a conflict, **Abort Rebase** undoes it, or **Open in Terminal** lets you
  finish it there.

[Back to the contents](index.md)
