# Blitter: Plan

Last updated: 2026-10-15

## Goal

Replace Path Finder for daily work with a native macOS file manager that works like Directory Opus. Get to a usable MVP fast, then let real use decide what comes next.

## Decisions

| Topic | Decision | Reason |
|---|---|---|
| Platform | macOS only | DOpus already covers Windows. Most of the value is in macOS integration (APFS, FSEvents, File Provider, Quick Look, Spotlight), which wouldn't port anyway. |
| UI toolkit | AppKit (`NSTableView`, `NSOutlineView`, `NSSplitView`) | Smooth with 100k+ rows and full keyboard control. SwiftUI is acceptable for preferences and dialogs only. |
| Language | Swift | One language, no bridging layer. Speed comes from calling the kernel directly, not from the language. |
| Automation | MCP server (post-MVP), no built-in scripting language | Claude or Codex can do more than DOpus-style scripting. A small `blitter` CLI on the same socket gives Python access for free. |
| Distribution | Developer ID, notarized, not sandboxed, no App Store | A sandboxed file manager isn't practical. Needs Full Disk Access. |
| Name | Blitter | After the Amiga chip. "dupus" was too close to the DOpus trademark. |

## Layout

```
┌──────────┬──────────────────┬──────────┬──────────────────┐
│ Tree L   │ Files L          │ Tree R   │ Files R          │
│          │                  │          │                  │
├──────────┴──────────────────┴──────────┴──────────────────┤
│ (post-MVP) Find panel                                     │
└───────────────────────────────────────────────────────────┘
```

- The two sides are always side by side, never stacked.
- Each side is a folder tree plus a detailed file list, with an editable path field at the top.
- **Source/destination is a core concept.** The active side is the source, and the other side is the destination. Copy, move and compare work from source to destination.
- No tabs. A recent-folders strip per side comes after the MVP.

## MVP (v0.1)

The MVP is done when it can replace Path Finder for daily work.

**Layout**
- Two sides, each with a tree and a file list. Splitter positions are saved.
- Source/destination model, with Tab switching the active side.
- Editable path field per side, with history.

**Navigation**
- Tree with a fixed root section: Favorites, volumes, cloud drives (`~/Library/CloudStorage`).
- Back, forward and parent folder. Type-to-select in the file list.
- Open with the default app. Space opens Quick Look.

**File list**
- Detail view with Name, Size, Date modified and Kind columns, sortable and resizable.
- Enumeration with `getattrlistbulk`, off the main thread.
- Live updates via FSEvents.
- Toggle for hidden files.

**Operations**
- Copy and move to the other side, rename inline, new folder, delete to Trash.
- Background job queue with progress and cancel. Copies on the same volume use `clonefile`.
- Clipboard copy/paste, and drag and drop to and from Finder.

**Keyboard**
- Everything above works from the keyboard. Shortcuts are hardcoded in v0.1.

**Not in the MVP:** Find panel, recent-folders strip, MCP server, configurable toolbar and shortcuts, viewer pane, archives as folders, sync/compare, per-folder column sets, tabs.

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

**Rule: every user action is a command in BlitterModel.** The UI only calls commands. The future MCP server will call the same commands, so it stays a thin adapter.

## After the MVP

Use it daily, record friction points as GitHub issues, and set priorities from those. Current best guess for the order:

1. **Find panel.** Docked at the bottom across both sides. Results open as a virtual folder (`search://…`) in a lister, so normal commands work on them. The default search walks the folder tree live; Spotlight is an optional scope; content search runs on top of the walk. Searches run in the background, results stream in, and the search can be cancelled.
2. **MCP server.** A local Unix socket. It exposes both app state (locations, selections, history) and commands. Changes go through plan → preview → confirm, deletes go to the Trash, and every operation is recorded in an undo journal.
3. **Recent-folders strip.** At the bottom of each file list, ordered by frecency (recent and frequent), with pinning.

## Workflow

- Repo: https://github.com/gersonkurz/blitter
- Work is coordinated through GitHub issues.
