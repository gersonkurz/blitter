import BlitterCore

/// Everything the user can do. The UI (and later the MCP server) changes state only through these.
public enum Command: Sendable {
    /// Go to a path the user typed. `~`, relative paths and `..` are resolved against the side's
    /// folder. Going to the folder the side already shows reads it again.
    case navigate(Side, path: String)
    /// Open the entry with this name: a folder, or a symbolic link to one, is shown in this side;
    /// files and packages (apps) open with their default app.
    case open(Side, name: String)
    case goBack(Side)
    case goForward(Side)
    /// Go to the enclosing folder and select the folder we came from.
    case goToParent(Side)
    /// Expand a folder in the side's tree; its subfolders are read in the background.
    case expandTreeNode(Side, TreeNodeID)
    case collapseTreeNode(Side, TreeNodeID)
    /// Show the tree node's folder in the side, keeping the tree selection under that node's root.
    case selectTreeNode(Side, TreeNodeID)
    /// Read the mounted volumes and cloud drives again, e.g. after a volume was mounted.
    case refreshTreeRoots
    /// Make the other side the active (source) side.
    case switchActiveSide
    /// Make this side the active (source) side, e.g. when the user clicks into it.
    case activate(Side)
    /// Read the side's folder again.
    case refresh(Side)
    case sort(Side, ListSort)
    /// Show or hide a column of the side's file list (#25); Name is always shown.
    case showColumn(Side, ListColumn, Bool)
    /// The side's file list shows the settings file's columns again.
    case resetColumns(Side)
    /// Highlight or filter the side's items by name (#39); nil ends it.
    case setQuickFilter(Side, QuickFilter?)
    /// Select the next or previous highlighted item.
    case selectQuickFilterMatch(Side, forward: Bool)
    /// Select these names on every side that shows `folder`, once it has been read again (e.g.
    /// the folder a clone made, #70).
    case selectAfterReading(folder: String, names: Set<String>)
    /// Replace the side's selection with these entry names.
    case select(Side, Set<String>)
    /// Add the items whose names match a pattern ("*.jpg; *.png") to the side's selection, or
    /// remove them from it.
    /// `includesFolders` false: only files (and links) are matched (#56).
    case selectByPattern(Side, String, PatternSelectionMode, includesFolders: Bool = true)
    /// Show or hide hidden files on both sides.
    case toggleHiddenFiles
    /// The lists' and trees' font one point larger or smaller, or back to the default size
    /// (#63). Saved as `[font] size` in the settings file.
    case zoomFont(FontZoom)
    /// The Settings window's changes (#64), from the settings it showed to those it shows now,
    /// written into the settings file as it is now.
    case saveSettings(original: Settings, edited: Settings)
    /// Search below the side's folder for names matching the pattern (#48), and files containing
    /// a text (#49); neither: stop showing the results.
    case find(Side, pattern: String, containing: String = "")
    /// Stop the side's search; its results so far stay.
    case stopFind(Side)
    /// Measure the side's selected folders, or all its folders when nothing is selected (#52).
    case measureFolderSizes(Side)
    /// Undo the last file operation (#61), if it is still the journal entry with this id.
    case undo(entry: Int)
    /// Copy the active side's selection into the other side's folder.
    case copyToOtherSide
    /// Move the active side's selection into the other side's folder.
    case moveToOtherSide
    /// Copy items from anywhere (pasted, or dropped from Finder or the other side) into a folder.
    case copyItems([String], toFolder: String)
    /// Move items from anywhere into a folder ("Move Item Here", a drop with ⌘).
    case moveItems([String], toFolder: String)
    /// Open the settings file for editing, creating it with commented defaults if there is none.
    case openSettingsFile
    /// Show a notice in the window until it is dismissed (e.g. that automation is off).
    case showNotice(String)
    /// Remove a notice (e.g. a settings problem) from the window.
    case dismissNotice(Int)
    /// Show the side's selection in Finder.
    case revealInFinder(Side)
    /// Open items with an app (an external tool, #18); a failure becomes a notice naming `title`.
    case openWithApp(String, paths: [String], title: String)
    /// Eject the volume mounted at the path, one of the tree's volumes but not the startup disk
    /// (#84); a failure becomes a notice.
    case eject(String)
    /// Open a dialog or window for a path (#42: the Git Log): the app shows it.
    case present(DialogRequest)
    /// Show two files or two folders side by side in the diff tool (#40).
    case compare(left: String, right: String)
    /// Run a command line in a folder as a job (a tool, #30): the program, then its arguments.
    case runCommand([String], folder: String)
    /// Show or hide Quick Look for the side's selection.
    case togglePreview(Side)
    /// Put the side's selection on the clipboard, as Finder does with Copy.
    case copyToPasteboard(Side)
    /// Put the full paths of the side's selection on the clipboard as text, one per line.
    case copyPaths(Side)
    /// Put the names of the side's selection on the clipboard as text, one per line.
    case copyNames(Side)
    /// Put the side's folder path on the clipboard as text (#33, e.g. from the tree's menu).
    case copyFolderPath(Side)
    /// Remove exactly what Git Clean's preview read (#71): to the Trash, as one undoable job, or
    /// (`forGood`) for good. Whoever asks to delete for good has asked the user.
    case removeExactly(RemovalPlan, forGood: Bool)
    /// Move the side's selection to the Trash.
    case trashSelection(Side)
    /// Delete the side's selection for good, bypassing the Trash. Asks first (`deleteRequest`)
    /// unless the settings turn that off.
    case deleteSelection(Side)
    /// Delete the side's selection for good without asking.
    case deleteSelectionWithoutAsking(Side)
    /// The answer to `deleteRequest`: delete exactly the items it named, or keep them.
    case answerDelete(token: Int, delete: Bool)
    /// Give an item a new name. The path, not a name in whatever the side shows by then, so a
    /// rename always hits the item it was started for. `side` selects the result.
    case rename(Side, path: String, newName: String)
    /// The user's answer to `Workspace.automationConfirmation` (#58): run the change or not.
    case answerAutomation(token: Int, allow: Bool)
    /// Pin a folder to the side's recent folders strip, unpin it, or forget it (#74).
    case recentFolder(Side, String, RecentFolderChange)
    /// Add a folder to the end of the tree's Favorites; one already there stays where it is.
    case addFavorite(String)
    case removeFavorite(String)
    /// Move a favorite up (negative) or down (positive) by that many places; the others close
    /// up behind it. Nothing happens if it would leave the list.
    case moveFavorite(String, offset: Int)
    /// Ask the window to show Batch Rename for the side's selection (`batchRenameRequest`).
    case requestBatchRename(Side)
    /// Carry out the renames a Batch Rename preview shows (`Workspace.batchRenamePreview`), all
    /// or none, if they are all still possible; ends the request.
    case batchRename(Side, BatchRenamePreview)
    /// Batch Rename was closed without renaming.
    case cancelBatchRename
    /// Ask the view to edit the name of the side's single selected entry.
    case requestRename(Side)
    case cancelRename(Side)
    /// Create a folder with a free name ("New Folder", "New Folder 2", ...), then edit its name.
    case newFolder(Side)
    case answerConflict(job: Int, ConflictAnswer)
    case cancelJob(Int)
    /// Remove a finished job (one that reported problems) from the list.
    case dismissJob(Int)
    /// Run an action from the registry on a side, if its scope fits the side as it is now.
    /// Menus, shortcuts and the MCP server all run actions this way.
    case runAction(String, Side)
    /// Run a folder action (#20, the tree's menu) on the side's folder once the side shows
    /// `folder`: now if its listing is there, else when it arrives.
    case runFolderAction(String, Side, folder: String)
}
