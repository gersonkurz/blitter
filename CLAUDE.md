# Blitter

A native macOS file manager in the spirit of Directory Opus. Read `docs/PLAN.md` for scope and decisions before starting any work.

## Ground rules

- **Mac only, Swift and AppKit.** SwiftUI only for preferences and dialogs, never for the file list or tree.
- **Module boundaries:** `BlitterApp` → `BlitterModel` → `BlitterCore`. Core must never import AppKit. Model must never touch views.
- **Every user action is a command in BlitterModel.** The UI calls commands and never changes file system state or model state directly. MCP will reuse these commands later.
- **Speed comes first:**
  - Enumerate with `getattrlistbulk`, not `FileManager` or per-file `URL` resource values.
  - Nothing blocking on the main thread. File system access runs in background tasks that can be cancelled.
  - The table views reuse cells. Avoid per-row allocations in hot paths.
  - Cloud and network folders must never stall the other side.
- **Safety:** deletes go to the Trash by default. Long operations go through the job queue with progress and cancel.
- **Scope:** keep to the MVP in `docs/PLAN.md`. Record new ideas as GitHub issues instead of building them.

## Workflow

- Work is coordinated through GitHub issues on `gersonkurz/blitter`.
- Commit and push only when asked.
