# Blitter

A native, keyboard-driven two-sided file manager for macOS: a Path Finder replacement, in the tradition of
Directory Opus. Released (0.4.0); scope and order live in the GitHub issues. This file is the ground rules and the
decisions that hold; read it before starting any work.

## Ground rules

- **Mac only, Swift and AppKit.** SwiftUI only for preferences and dialogs, never for the file list or tree.
- **Module boundaries:** see Architecture. Core, Model and Git never import AppKit, Cocoa or SwiftUI; Model never
  touches views (`just check-boundaries`, part of `just verify`).
- **Every user action is a command in BlitterModel.** The UI calls commands and never changes file system state or
  model state directly. The automation socket (the `blitter` tool, MCP, Python) runs the same commands and actions.
- **Speed comes first:**
  - Enumerate with `getattrlistbulk`, not `FileManager` or per-file `URL` resource values.
  - Nothing blocking on the main thread. File system access runs in background tasks that can be cancelled.
  - The table views reuse cells. Avoid per-row allocations in hot paths.
  - Cloud and network folders must never stall the other side.
- **Safety:** deletes go to the Trash by default. Long operations go through the job queue with progress and cancel.
  Changes asked for over the automation socket need the user's Allow in Blitter.
- **Scope:** work on what the GitHub issues ask for. Record new ideas as issues (label `later` for ideas that wait
  for real use) instead of building them.
- **Manual:** a change users can see is not done until its page in `docs/manual/` says so (see Manual).

## Decisions

| Topic | Decision | Reason |
|---|---|---|
| Platform | macOS only | Most of the value is in macOS integration (APFS, FSEvents, File Provider, Quick Look, Spotlight), which wouldn't port anyway. |
| UI toolkit | AppKit (`NSTableView`, `NSOutlineView`, `NSSplitView`) | Smooth with 100k+ rows and full keyboard control. SwiftUI only for preferences and dialogs. |
| Language | Swift, no dependencies beyond Apple's frameworks and TOMLKit | One language, no bridging layer. Speed comes from calling the kernel directly, not from the language. |
| Automation | A local socket with an MCP server, the `blitter` CLI and a Python module; no built-in scripting language | Claude or Codex can do more than a built-in scripting language. |
| Distribution | Developer ID signed and notarized (since 0.4.0), not sandboxed, no App Store | A sandboxed file manager isn't practical; it needs Full Disk Access. |
| Name | Blitter | After the Amiga chip. The earlier working name was too close to an existing trademark. |
| Settings | One TOML file (`~/.config/blitter/settings.toml`), also edited by the Settings window | Readable, diffable, travels between Macs. |

**Releases:** `MARKETING_VERSION` (and `CURRENT_PROJECT_VERSION`) in `project.yml` are the one source of the version.
A release bumps them, runs `just package` (signs with `$MACOS_CODESIGN_IDENTITY`) and `just notarize` (keychain profile
`blitter-notary`; notarizes and staples the app, then the DMG), commits the version, tags it (`v0.4.0`) and publishes
the DMG and `checksums.txt` as a GitHub release with notes. README.md's Version history turns its Unreleased line
into the new version's, in a few words (the details stay in the release notes).

## Architecture

```
BlitterApp (AppKit: windows, views, menus)
   ↓
BlitterGit (the Git windows' models)     BlitterCLI (the `blitter` tool: CLI, MCP)
   ↓                                        ↓
BlitterModel (state and commands)          │
   ↓                                        │
BlitterCore (file system, jobs, FSEvents, automation socket; no AppKit)
```

- **BlitterCore:** `getattrlistbulk` enumeration, FSEvents watching, the job queue (copy, move, Trash, delete,
  rename), cloud placeholders, git processes, the automation socket and its client.
- **BlitterModel:** each window's `Workspace` (its two sides: location, history, selection, sort, tree, active
  side) and the commands that act on it. What all windows share (the settings and their file, notices, the job
  queue and its undo journal, the colors being tried) is one `AppModel`; a change there is a change for every
  window.
- **BlitterGit:** Log, Commit, Sync, Clone and Clean as models the app's windows render. Core and Model never
  import it.
- **BlitterApp:** views and controllers. They render model state and call commands.
- One deliberate exception to "every action is a command": **Install Command-Line Tool…** changes the Mac, not the
  workspace, and asks for an administrator's password. It is an app menu item only, so automation can never trigger
  that prompt; its file-system work still runs off the main thread.

## Not doing

| What | Why |
|---|---|
| Tabs | Two sides, several windows, and the recent folders in the path field's menu. |
| Archives as folders | The owner doesn't trust it and never uses it. |
| A built-in scripting language | Automation goes through the socket: AI assistants, the CLI, Python. |
| App Store, sandbox | A sandboxed file manager isn't practical. |
| A Markdown viewer of its own | Quick Look extensions (QLMarkdown) preview in place with Space; a viewer app can be a tool. |

## Manual

English Markdown in `docs/manual/`, one page per area; a GitHub Actions workflow publishes only `docs/manual/` to
GitHub Pages (https://gersonkurz.github.io/blitter/).

- Screenshots are generated, never taken by hand: `just screenshots` builds each scene from demo folders (fixed
  sizes, dates and window size; light and dark) and writes `docs/manual/images/`, so a UI change shows up as changed
  images. Restore re-rendered images that did not visibly change.
- Open menus come from the real app: `just menu-screenshots` runs Blitter isolated (`BLITTER_PROFILE`) on demo
  folders and opens each menu over the automation socket. It needs Screen Recording for the terminal and the Mac to
  itself while it runs.
- The reference pages (settings file, actions, shortcuts) are generated from the code with `just manual`, so they
  cannot drift.
- README.md's picture is a screenshot scene too (`readme-light.png`, `readme-dark.png`).

## Commands

Everything goes through the `justfile` (`just` with no arguments lists the recipes).

## Workflow

- Work is coordinated through GitHub issues on `gersonkurz/blitter`.
- Git: work directly on `main`, one task per commit. Commit messages reference the issue (`Fixes #N`). Commit and push only after `just verify` passes and the review loop approves; pushing approved commits to `main` needs no further confirmation. Experimental or risky work goes on a short-lived branch that is merged or deleted afterwards. Releases are tagged (`v0.1.0`).

## Review loop

One import line per machine — Claude Code skips an import whose path does not
exist and loads the others, so both can stand:

@C:/Projects/yaaadabi/protocol.md
@~/development/yaaadabi/protocol.md

Loop parameters:
- Verify: `just verify` - add whatever verification is typical for Swift projects on the mac
- Yardstick docs: CLAUDE.md (ground rules, decisions, architecture, not doing)
- Review focus: Stability, Speed, Code Simplicity / Maintainability, Functionality - roughly in that order.
- Task list: GitHub issues on gersonkurz/blitter, one issue per [task] finding, label `review-task`
