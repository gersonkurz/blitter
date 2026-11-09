import BlitterCore
import Foundation

/// What an action works on. Menus offer an action only where its scope fits, and running it
/// checks again, so an action never runs on something it was not made for.
public enum ActionScope: Hashable, Sendable {
    /// The side's folder itself, once it has been read; the selection does not matter.
    case folder
    /// One or more selected items.
    case selection
    /// Exactly one selected item.
    case single
    /// One or more selected items, none of them a folder (files and symbolic links).
    case files
    /// The selected items, or the side's folder when nothing is selected (#37).
    case selectionOrFolder
    /// Two files to compare (#40): two selected on this side, or one here and one on the other.
    case filePair
    /// Both sides' folders (#40), each read and showing the folder it is at: never the folder a
    /// side is leaving while the next one is still being read.
    case bothFolders
    /// The side's folder, or its one selected item, inside a git working copy (#42).
    case workingCopy
    /// The selected folders, or every folder listed when nothing is selected (#52): at least one.
    case folders
    /// Blitter's last file operation that can be undone (#61): there must be one. The side does
    /// not matter.
    case lastChange

    /// Whether the action can work on the side's folder: such actions are offered in the tree's
    /// menu (#20), where they act on the node's folder.
    var worksOnFolder: Bool {
        [.folder, .selectionOrFolder, .bothFolders, .workingCopy, .folders].contains(self)
    }

    /// `inWorkingCopy`: the side's folder is in a git working copy the workspace knows.
    /// `canUndo`: the workspace has a file operation to undo (#61).
    func fits(_ state: SideState, other: SideState, inWorkingCopy: Bool = false, canUndo: Bool = false) -> Bool {
        switch self {
        case .workingCopy: inWorkingCopy && state.status == .loaded && state.selection.count <= 1
        case .filePair: Self.pair(state, other, on: .left) != nil // the order does not matter here
        case .bothFolders: [state, other].allSatisfy { $0.status == .loaded && $0.entriesLocation == $0.location }
        case .folder, .selectionOrFolder: state.status == .loaded
        case .selection: !state.selection.isEmpty
        case .lastChange: canUndo
        case .folders:
            state.status == .loaded && (state.selection.isEmpty ? state.totals.folders > 0
                : !state.selectedEntriesAllSatisfy { $0.entry.kind != .directory })
        case .single: state.selection.count == 1
        case .files:
            !state.selection.isEmpty && state.selectedEntriesAllSatisfy { [.file, .symlink].contains($0.entry.kind) }
        }
    }
}

extension ActionScope {
    /// The two files a `.filePair` action compares: two selected files on `side` (whose state is
    /// `state`), in list order, or its one selected file and the other side's one, the left
    /// side's first.
    static func pair(_ state: SideState, _ other: SideState, on side: Side) -> (String, String)? {
        // Counts first: menus ask this on the main thread, and most of the time no listing needs
        // to be looked at (#40 review).
        let twoHere = state.selection.count == 2
        guard twoHere || (state.selection.count == 1 && other.selection.count == 1) else {
            return nil
        }
        func files(_ state: SideState) -> [String] {
            state.selectedEntries.filter { $0.entry.kind != .directory }
                .map { Paths.appending($0.entry.name, to: state.entriesLocation) }
        }
        let here = files(state)
        guard here.count == state.selection.count else {
            return nil // a folder is among them
        }
        if here.count == 2 {
            return (here[0], here[1])
        }
        let there = files(other)
        guard here.count == 1, there.count == 1, other.selection.count == 1 else {
            return nil
        }
        return side == .left ? (here[0], there[0]) : (there[0], here[0])
    }
}

/// Where an action's result goes, so a caller (the MCP server) knows what to expect from it.
public enum ActionOutput: Equatable, Sendable {
    /// It changes something (files, the view) and returns nothing.
    case none
    /// It puts the selection on the clipboard.
    case clipboard
}

/// What running an action does, for the automation socket (#58): view actions run when asked,
/// those that open something or change files only once the user allows it in Blitter, and some
/// are not offered there at all.
public enum ActionEffect: String, Sendable {
    /// Changes only what Blitter shows or opens one of its own windows.
    case view
    /// Opens an app or a file with one, or shows something in the Finder.
    case opens
    /// Changes files (copies, moves, the Trash, a new folder) or runs a command line.
    case changes
    /// The clipboard, an edit in place, a dialog of its own, or a delete that skips the Trash.
    case notAutomated
}

/// A function the user can run on a side: from a menu, a shortcut, or later the MCP server. The
/// settings file and the menus refer to it by `id`. Built-in actions are thin wrappers around
/// commands, so nothing is implemented twice; running one goes through `Command.runAction`.
public struct Action: Sendable {
    public let id: String
    public let title: String
    public let scope: ActionScope
    public let output: ActionOutput
    /// Whether it is offered on a side that shows search results (#48): not for what names an
    /// entry in the folder itself (rename, new folder).
    let worksInFind: Bool
    /// What running it does; unknown means it may change files.
    public let effect: ActionEffect
    /// The command that carries the action out on a side whose state fits the scope.
    let command: @MainActor @Sendable (Workspace, Side) -> Command
    /// File types (a tool's extensions, #65) as ".bin": then every selected item must be a file
    /// whose name ends in one of them. Empty: any.
    let fileTypes: [String]

    init(_ id: String, _ title: String, scope: ActionScope, output: ActionOutput = .none, worksInFind: Bool = true,
         effect: ActionEffect = .changes, fileTypes: [String] = [],
         command: @escaping @MainActor @Sendable (Workspace, Side) -> Command)
    {
        self.id = id
        self.title = title
        self.scope = scope
        self.output = output
        self.worksInFind = worksInFind
        self.effect = effect
        self.fileTypes = fileTypes.map { "." + $0 }
        self.command = command
    }

    /// Whether it can work on a folder, as the tree's menu offers it (#20): not one for some file
    /// types (#65), which a folder never is.
    var worksOnFolder: Bool {
        fileTypes.isEmpty && scope.worksOnFolder
    }

    /// Whether the side's selection is of the action's file types. Menus ask this for every
    /// item: a suffix compare per selected name, nothing allocated.
    func fitsFileTypes(_ state: SideState) -> Bool {
        guard !fileTypes.isEmpty else {
            return true
        }
        return !state.selection.isEmpty && state.selectedEntriesAllSatisfy { listed in
            let name = listed.entry.name
            return listed.entry.kind != .directory && fileTypes.contains { type in
                name.count > type.count
                    && name.range(of: type, options: [.caseInsensitive, .anchored, .backwards]) != nil
            }
        }
    }
}

/// All actions, by id, in the order menus list them by default.
public struct ActionRegistry: Sendable {
    public let all: [Action]
    private let byID: [String: Action]

    /// The built-in actions followed by the tools from the settings.
    init(tools: [Tool]) {
        self.init(Self.builtIn.all + tools.map(\.action))
    }

    init(_ actions: [Action]) {
        all = actions
        byID = Dictionary(actions.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
    }

    public func action(_ id: String) -> Action? {
        byID[id]
    }

    /// The built-in actions; later tickets add their own here (copy path, tools, git, ...).
    static let builtIn = ActionRegistry([
        Action("open", "Open", scope: .single, effect: .opens) { workspace, side in
            .open(side, name: workspace.state(of: side).selection.first ?? "")
        },
        Action("quick-look", "Quick Look", scope: .selection, effect: .view) { _, side in .togglePreview(side) },
        Action("copy", "Copy", scope: .selection, output: .clipboard, effect: .notAutomated) { _, side in
            .copyToPasteboard(side)
        },
        Action("copy-path", "Copy Path", scope: .selection, output: .clipboard, effect: .notAutomated) { _, side in
            .copyPaths(side)
        },
        Action("copy-name", "Copy Name", scope: .selection, output: .clipboard, effect: .notAutomated) { _, side in
            .copyNames(side)
        },
        Action("rename", "Rename", scope: .single, worksInFind: false, effect: .notAutomated) { _, side in
            .requestRename(side)
        },
        Action("batch-rename", "Batch Rename…", scope: .selection, worksInFind: false,
               effect: .notAutomated)
        { _, side in
            .requestBatchRename(side)
        },
        Action("copy-to-other-side", "Copy to Other Side", scope: .selection) { workspace, side in
            .copyItems(workspace.selectedItems(on: side).map(\.path),
                       toFolder: workspace.state(of: side.opposite).location)
        },
        Action("move-to-other-side", "Move to Other Side", scope: .selection) { workspace, side in
            .moveItems(workspace.selectedItems(on: side).map(\.path),
                       toFolder: workspace.state(of: side.opposite).location)
        },
        Action("reveal-in-finder", "Reveal in Finder", scope: .selection, effect: .opens) { _, side in
            .revealInFinder(side)
        },
        Action("move-to-trash", "Move to Trash", scope: .selection) { _, side in .trashSelection(side) },
        Action("delete-immediately", "Delete Immediately", scope: .selection, effect: .notAutomated) { _, side in
            .deleteSelection(side)
        },
        Action("delete-immediately-without-asking", "Delete Immediately Without Asking",
               scope: .selection, effect: .notAutomated) { _, side in .deleteSelectionWithoutAsking(side) },
        Action("folder-sizes", "Calculate Folder Sizes", scope: .folders, effect: .view) { _, side in
            .measureFolderSizes(side)
        },
        Action("new-folder", "New Folder", scope: .folder, worksInFind: false) { _, side in .newFolder(side) },
        Action("copy-folder-path", "Copy Path", scope: .folder, output: .clipboard, effect: .notAutomated) { _, side in
            .copyFolderPath(side)
        },
        // #40: in the configured diff tool. The pair is the scope's, so menus and running agree.
        Action("compare-files", "Compare Files", scope: .filePair, effect: .opens) { workspace, side in
            let pair = ActionScope.pair(workspace.state(of: side), workspace.state(of: side.opposite), on: side)
            return .compare(left: pair?.0 ?? "", right: pair?.1 ?? "")
        },
        // #70: clone a repository into the side's folder; any folder, not only a working copy.
        Action("git-clone", "Git Clone…", scope: .folder, worksInFind: false, effect: .view) { workspace, side in
            .present(DialogRequest(kind: DialogRequest.gitClone, path: workspace.state(of: side).entriesLocation))
        },
        // #42: the history of the selected item, or of the side's folder.
        Action("git-log", "Git Log…", scope: .workingCopy, effect: .view) { workspace, side in
            .present(DialogRequest(kind: DialogRequest.gitLog, path: workspace.workingCopyTarget(on: side)))
        },
        Action("git-sync", "Git Sync…", scope: .workingCopy, effect: .view) { workspace, side in
            .present(DialogRequest(kind: DialogRequest.gitSync, path: workspace.workingCopyTarget(on: side)))
        },
        Action("git-clean", "Git Clean…", scope: .workingCopy, effect: .view) { workspace, side in
            .present(DialogRequest(kind: DialogRequest.gitClean, path: workspace.workingCopyTarget(on: side)))
        },
        Action("git-commit", "Git Commit…", scope: .workingCopy, effect: .view) { workspace, side in
            .present(DialogRequest(kind: DialogRequest.gitCommit, path: workspace.workingCopyTarget(on: side)))
        },
        Action("undo", "Undo", scope: .lastChange) { workspace, _ in
            .undo(entry: workspace.lastUndo?.id ?? 0)
        },
        Action("compare-folders", "Compare Folders", scope: .bothFolders, effect: .opens) { workspace, _ in
            .compare(
                left: workspace.state(of: .left).entriesLocation,
                right: workspace.state(of: .right).entriesLocation
            )
        },
    ])
}

public extension Workspace {
    /// The actions whose scope fits the side as it is now: what a menu for it offers.
    func actions(for side: Side) -> [Action] {
        let (here, other) = (state(of: side), state(of: side.opposite))
        let inWorkingCopy = workingCopyRoot(containing: workingCopyTarget(on: side)) != nil
        return actionRegistry.all.filter {
            (here.find == nil || $0.worksInFind)
                && $0.scope.fits(here, other: other, inWorkingCopy: inWorkingCopy, canUndo: canUndo)
                && $0.fitsFileTypes(here)
        }
    }

    /// Whether `perform(.runAction(id, side))` would run the action now.
    func canRun(_ id: String, on side: Side) -> Bool {
        guard let action = actionRegistry.action(id), state(of: side).find == nil || action.worksInFind else {
            return false
        }
        let scope = action.scope
        // Menus ask this for every item: only a working-copy action needs to know whether its
        // target is in a working copy (#46).
        let inWorkingCopy = scope == .workingCopy && workingCopyRoot(containing: workingCopyTarget(on: side)) != nil
        return scope.fits(state(of: side), other: state(of: side.opposite), inWorkingCopy: inWorkingCopy,
                          canUndo: canUndo)
            && action.fitsFileTypes(state(of: side))
    }

    internal func runFolderAction(_ id: String, on side: Side, folder: String) -> Bool {
        let state = state(of: side)
        guard actionRegistry.action(id)?.worksOnFolder == true, state.location == folder else {
            return false // only folder actions, and only while the side still shows that folder
        }
        if state.entriesLocation == folder, state.status == .loaded {
            return runOnFolder(id, on: side)
        }
        // Only a folder still being read waits; one that could not be read gets nothing, so a
        // later refresh never runs a choice the user made back then.
        if state.status == .loading {
            sides[side]?.pendingAction = PendingAction(folder: folder, id: id)
        }
        return false
    }

    /// After a listing: runs the folder action chosen while it was read, if it is for this folder.
    internal func runPendingAction(on side: Side) {
        guard let pending = sides[side]?.pendingAction, let state = sides[side] else {
            return
        }
        sides[side]?.pendingAction = nil
        if pending.folder == state.entriesLocation, state.status == .loaded {
            _ = runOnFolder(pending.id, on: side) // the listing's notification reports it
        }
    }

    /// A folder action from the tree's menu is for the folder, not for whatever is selected in
    /// it (selection-or-folder tools, #37): the selection goes first. Returns whether anything
    /// changed, the cleared selection included, so the views hear of it.
    private func runOnFolder(_ id: String, on side: Side) -> Bool {
        let hadSelection = sides[side]?.selection.isEmpty == false
        if hadSelection {
            sides[side]?.selection = []
        }
        let changed = runAction(id, on: side)
        return changed || hadSelection
    }

    internal func runAction(_ id: String, on side: Side) -> Bool {
        guard let action = actionRegistry.action(id), canRun(id, on: side) else {
            return false
        }
        return apply(action.command(self, side))
    }
}
