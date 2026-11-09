# Blitter: Plan

Last updated: 2026-11-09

## Goal

Replace Path Finder for daily work with a native macOS file manager: two sides, keyboard first, fast. The MVP (0.1.0) is out; from here, real use decides what comes next, one release at a time.

## Decisions

| Topic | Decision | Reason |
|---|---|---|
| Platform | macOS only | Most of the value is in macOS integration (APFS, FSEvents, File Provider, Quick Look, Spotlight), which wouldn't port anyway. |
| UI toolkit | AppKit (`NSTableView`, `NSOutlineView`, `NSSplitView`) | Smooth with 100k+ rows and full keyboard control. SwiftUI is acceptable for preferences and dialogs only. |
| Language | Swift | One language, no bridging layer. Speed comes from calling the kernel directly, not from the language. |
| Automation | A local socket with an MCP server, the `blitter` CLI and a Python module; no built-in scripting language | Claude or Codex can do more than a built-in scripting language. Changes need the user's Allow in Blitter. |
| Distribution | Developer ID, notarized, not sandboxed, no App Store | A sandboxed file manager isn't practical. Needs Full Disk Access. |
| Name | Blitter | After the Amiga chip. The earlier working name was too close to an existing trademark. |
| Manual | English, Markdown in `docs/manual/`, published to GitHub Pages; screenshots generated from the app | Many features have no obvious path to discovery. The manual lives and is reviewed with the code, so it stays true. |
| Versions | `MARKETING_VERSION` in `project.yml` is the one source; `just package` names the DMG after it | A release bumps that line and tags the commit (`v0.2.0`). |

## Layout

```
┌──────────┬──────────────────┬──────────┬──────────────────┐
│ Tree L   │ Files L          │ Tree R   │ Files R          │
│          │                  │          │                  │
├──────────┴──────────────────┴──────────┴──────────────────┤
│ Find panel (while searching)                              │
├───────────────────────────────────────────────────────────┤
│ Jobs and notices (while there are any)                    │
└───────────────────────────────────────────────────────────┘
```

- The two sides are always side by side, never stacked.
- Each side is a folder tree plus a detailed file list, with an editable path field at the top.
- **Source/destination is a core concept.** The active side is the source, and the other side is the destination. Copy, move and compare work from source to destination.
- No tabs. The recent-folders strip (0.2.0) covers what tabs would.

## Architecture

Three modules with dependencies pointing one way only:

```
BlitterApp  (AppKit UI)
   ↓
BlitterModel  (per-side state, commands)
   ↓
BlitterCore  (file system: enumeration, watching, file operation jobs; no AppKit)
```

- **BlitterCore** holds `getattrlistbulk` enumeration, FSEvents watching, the job queue for copy/move/delete/rename, and cloud placeholder handling. It must not import AppKit.
- **BlitterModel** holds the state of each side (location, history, selection, sort, active side) and the commands that act on it.
- **BlitterApp** holds the views and controllers. It renders model state and calls commands.

**Rule: every user action is a command in BlitterModel.** The UI only calls commands; the automation socket calls the same commands and actions, so it stays a thin adapter.

## Released

### 0.1.0: the MVP

Two sides with tree, file list and path field; Favorites, volumes and cloud drives; back, forward, parent; live updates; hidden files; copy, move, rename, new folder, Trash with a background job queue; clipboard and drag and drop; everything from the keyboard.

### Since 0.1.0 (goes out with 0.2.0)

- **Finding:** the fast filter (type to highlight, `*` to filter), Select by Pattern, the Find panel (names and contents, results as a folder of their own).
- **Files:** Delete Immediately (asks first), Batch Rename, folder sizes, the Permissions, Kind and Git columns, the status line with free space, compare with an external diff tool, Undo for file operations (#61).
- **Git:** working copies colored by state, Git Log, Git Commit, Git Sync.
- **Customizing:** the settings file (`~/.config/blitter/settings.toml`) and the Settings window; tools, context menus and the menu bar's items and shortcuts, with an editor; colors from Base16/Base24 schemes; fonts and zoom.
- **Automation:** the socket, the `blitter` CLI and MCP server, the Python module.
- **The manual** on GitHub Pages.

## 0.2.0

The next release. Done when these are in, the manual says so, and `just package` builds `Blitter-0.2.0.dmg`.

- **Git Clone** (#70): clone into the side's folder from any folder.
- **Git Clean** (#71): the dry run first, Move to Trash by default, Delete for Good on request.
- **Favorites** (#72): in the settings and the Settings window, a Go → Favorites menu with shortcuts, Add to Favorites from the file list.
- **Colors** (#73): pick a ready-made scheme (with the owner's Midnight Blue) instead of editing colors role by role.
- **Recent-folders strip** (#74): per side, ordered by frecency, with pinning.
- **Manual:** screenshots of open menus and context menus (#69).
- **Stability:** the flaky tests (#66).

## Later

Ideas wait here until real use asks for them; each becomes an issue when it is picked up.

- A viewer pane next to the file list.
- Per-folder column sets.
- Folder sync and compare inside Blitter (today: the external diff tool).

## Not doing

| What | Why |
|---|---|
| Archives as folders | The owner doesn't trust it and never uses it. |
| Tabs | Two sides plus the recent-folders strip. |
| A built-in scripting language | Automation goes through the socket: AI assistants, the CLI, Python. |
| App Store, sandbox | A sandboxed file manager isn't practical. |
| A Markdown viewer of its own | Quick Look extensions (QLMarkdown) preview in place with Space; a viewer app can be a tool. |

## Manual

Owner's decision (2026-11-07): the manual comes early, before more features, because much of Blitter is invisible without it (the fast filter, zoom, drag modifiers, tools and menus in the settings file, automation).

- **Source:** Markdown in `docs/manual/`, one page per area: getting started, the two sides, navigation, file operations and jobs, Find, Git, settings, tools and menus, keyboard, automation. English only.
- **Publishing:** a GitHub Actions workflow publishes only `docs/manual/` to GitHub Pages (https://gersonkurz.github.io/blitter/). The rest of `docs/` (this plan) is not published.
- **Screenshots:** generated, never taken by hand. An opt-in screenshot suite builds each scene from fixtures (demo folders, fixed window size, fixed theme, light and dark) and writes PNGs to `docs/manual/images/`; `just screenshots` regenerates them, so a UI change shows up as changed images in `git diff`. What only the real app can show (open menus, context menus) is captured from the real app driven over the automation socket (#69): `just menu-screenshots` runs Blitter isolated (`BLITTER_PROFILE`: its own settings and socket, no window state saved) on demo folders in `/Users/Shared/Blitter Demo`, opens each menu with `showMenu` and takes the menu's rectangle with `screencapture`. It needs Screen Recording for the terminal.
- **Generated reference:** the settings reference comes from `Settings.defaultFile`, the keyboard table from the default menu bar, the list of actions from the action registry, so they cannot drift from the code.
- **Rule:** a change users can see is not done until its manual page says so.

## Workflow

- Repo: https://github.com/gersonkurz/blitter
- Work is coordinated through GitHub issues.
