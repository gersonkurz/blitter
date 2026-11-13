import BlitterCore

/// The built-in actions, in the order menus list them by default; tools follow them.
extension ActionRegistry {
    /// The built-in actions; later tickets add their own here (copy path, tools, git, ...).
    static let builtIn = ActionRegistry([
        Action("open", "Open", scope: .single, effect: .opens, symbol: "arrow.up.forward.app") { workspace, side in
            .open(side, name: workspace.state(of: side).selection.first ?? "")
        },
        Action("quick-look", "Quick Look", scope: .selection, effect: .view, symbol: "eye") { _, side in
            .togglePreview(side)
        },
        Action("copy", "Copy", scope: .selection, output: .clipboard, effect: .notAutomated,
               symbol: "doc.on.doc")
        { _, side in
            .copyToPasteboard(side)
        },
        Action("copy-path", "Copy Path", scope: .selection, output: .clipboard, effect: .notAutomated,
               symbol: "link")
        { _, side in
            .copyPaths(side)
        },
        Action(
            "copy-name",
            "Copy Name",
            scope: .selection,
            output: .clipboard,
            effect: .notAutomated,
            symbol: "character.cursor.ibeam"
        ) { _, side in
            .copyNames(side)
        },
        Action("rename", "Rename", scope: .single, worksInFind: false, effect: .notAutomated,
               symbol: "pencil")
        { _, side in
            .requestRename(side)
        },
        Action("batch-rename", "Batch Rename…", scope: .selection, worksInFind: false,
               effect: .notAutomated, symbol: "pencil.and.list.clipboard")
        { _, side in
            .requestBatchRename(side)
        },
        Action("copy-to-other-side", "Copy to Other Side", scope: .selection,
               symbol: "plus.square.on.square")
        { workspace, side in
            .copyItems(workspace.selectedItems(on: side).map(\.path),
                       toFolder: workspace.state(of: side.opposite).location)
        },
        Action("move-to-other-side", "Move to Other Side", scope: .selection,
               symbol: "arrow.right.square")
        { workspace, side in
            .moveItems(workspace.selectedItems(on: side).map(\.path),
                       toFolder: workspace.state(of: side.opposite).location)
        },
        Action("reveal-in-finder", "Reveal in Finder", scope: .selection, effect: .opens,
               symbol: "macwindow")
        { _, side in
            .revealInFinder(side)
        },
        Action("move-to-trash", "Move to Trash", scope: .selection, symbol: "trash") { _, side in
            .trashSelection(side)
        },
        Action(
            "delete-immediately",
            "Delete Immediately",
            scope: .selection,
            effect: .notAutomated,
            symbol: "xmark.bin"
        ) { _, side in
            .deleteSelection(side)
        },
        Action("delete-immediately-without-asking", "Delete Immediately Without Asking",
               scope: .selection, effect: .notAutomated,
               symbol: "xmark.bin.fill") { _, side in .deleteSelectionWithoutAsking(side) },
        Action("folder-sizes", "Calculate Folder Sizes", scope: .folders, effect: .view,
               symbol: "scalemass")
        { _, side in
            .measureFolderSizes(side)
        },
        Action("new-folder", "New Folder", scope: .folder, worksInFind: false, symbol: "folder.badge.plus") { _, side in
            .newFolder(side)
        },
        Action(
            "copy-folder-path",
            "Copy Path",
            scope: .folder,
            output: .clipboard,
            effect: .notAutomated,
            symbol: "link"
        ) { _, side in
            .copyFolderPath(side)
        },
        // #40: in the configured diff tool. The pair is the scope's, so menus and running agree.
        Action("compare-files", "Compare Files", scope: .filePair, effect: .opens,
               symbol: "rectangle.split.2x1")
        { workspace, side in
            let pair = ActionScope.pair(workspace.state(of: side), workspace.state(of: side.opposite), on: side)
            return .compare(left: pair?.0 ?? "", right: pair?.1 ?? "")
        },
        // #70: clone a repository into the side's folder; any folder, not only a working copy.
        Action(
            "git-clone",
            "Git Clone…",
            scope: .folder,
            worksInFind: false,
            effect: .view,
            symbol: "square.and.arrow.down"
        ) { workspace, side in
            .present(DialogRequest(kind: DialogRequest.gitClone, path: workspace.state(of: side).entriesLocation))
        },
        // #42: the history of the selected item, or of the side's folder.
        Action("git-log", "Git Log…", scope: .workingCopy, effect: .view,
               symbol: "clock.arrow.circlepath")
        { workspace, side in
            .present(DialogRequest(kind: DialogRequest.gitLog, path: workspace.workingCopyTarget(on: side)))
        },
        Action("git-sync", "Git Sync…", scope: .workingCopy, effect: .view,
               symbol: "arrow.triangle.2.circlepath")
        { workspace, side in
            .present(DialogRequest(kind: DialogRequest.gitSync, path: workspace.workingCopyTarget(on: side)))
        },
        Action("git-clean", "Git Clean…", scope: .workingCopy, effect: .view, symbol: "sparkles") { workspace, side in
            .present(DialogRequest(kind: DialogRequest.gitClean, path: workspace.workingCopyTarget(on: side)))
        },
        Action("git-commit", "Git Commit…", scope: .workingCopy, effect: .view,
               symbol: "checkmark.circle")
        { workspace, side in
            .present(DialogRequest(kind: DialogRequest.gitCommit, path: workspace.workingCopyTarget(on: side)))
        },
        // #72: the selected folder, or the side's folder, joins the tree's Favorites.
        Action("add-to-favorites", "Add to Favorites", scope: .oneFolder, worksInFind: false,
               effect: .notAutomated, symbol: "star")
        { workspace, side in
            let state = workspace.state(of: side)
            let name = state.selection.first.map { Paths.appending($0, to: state.entriesLocation) }
            return .addFavorite(name ?? state.entriesLocation)
        },
        // #84: the volume the side's folder is on, as Finder's Eject.
        Action("eject", "Eject", scope: .volume, worksInFind: false, symbol: "eject") { workspace, side in
            .eject(workspace.ejectableVolume(containing: workspace.state(of: side).location)?.path ?? "")
        },
        Action("undo", "Undo", scope: .lastChange, symbol: "arrow.uturn.backward") { workspace, _ in
            .undo(entry: workspace.lastUndo?.id ?? 0)
        },
        // #88: the View menu's own, as actions so the toolbar (and menus, and automation) can name them.
        Action("toggle-hidden-files", "Show Hidden Files", scope: .always, effect: .view, symbol: "eye.slash",
               isOn: { $0.showsHiddenFiles }, command: { _, _ in .toggleHiddenFiles }),
        Action("refresh", "Refresh", scope: .always, effect: .view, symbol: "arrow.clockwise") { _, side in
            .refresh(side)
        },
        Action(
            "compare-folders",
            "Compare Folders",
            scope: .bothFolders,
            effect: .opens,
            symbol: "rectangle.split.2x1.fill"
        ) { workspace, _ in
            .compare(
                left: workspace.state(of: .left).entriesLocation,
                right: workspace.state(of: .right).entriesLocation
            )
        },
    ])
}
