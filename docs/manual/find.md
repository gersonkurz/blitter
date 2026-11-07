# Find

**⌘F** (Edit → Find…) opens the Find panel below the sides. It searches below the active side's
folder; the panel says which folder that is.

- **Find**: a part of the name, or a pattern. Without a wildcard, a name matches when it contains
  the text anywhere. With one, the whole name must match: `*.swift` finds names that end in
  ".swift". `*` stands for any number of characters, `?` for one. Case and accents do not
  matter.
- **Containing** (optional): a text the files must contain, also ignoring case and accents. With
  only this field filled in, every file name counts.
- Press **Return** in either field to start.

## The results

The results appear in the active side, as a folder of their own: each item under its path below
the searched folder, e.g. `Sources/App/main.swift`. The path field shows the search as
`search://…`.

- Results come in while the search runs; the panel counts the folders searched and, with
  **Containing**, the files read. **Stop** ends the search and keeps what it found.
- The results are a list like any other: sort them, filter them by typing, select them, copy,
  move, trash, compare or open them. Renaming and New Folder are not offered there.
- **Back** (**⌘[**) returns to the folder; going anywhere else ends the search too.
- **⌘R** runs the search again. The results do not follow changes on disk by themselves.
- **Escape** or **✕** hides the panel. The results stay in the side.

## What is searched

- Hidden folders and files only while hidden files are shown (**⇧⌘.**).
- Not searched: the inside of packages (an app is one item), folders behind symbolic links,
  and other volumes mounted below the folder.
- With **Containing**, only files are found, never folders. Binary files and cloud files that
  are not downloaded are skipped; reading them would download them. A folder that cannot be read
  is skipped and counted.

[Back to the contents](index.md)
