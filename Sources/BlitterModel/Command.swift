import BlitterCore

/// Everything the user can do. The UI (and later the MCP server) changes state only through these.
public enum Command: Sendable {
    /// Go to a path the user typed. `~`, relative paths and `..` are resolved against the side's
    /// folder. Going to the folder the side already shows reads it again.
    case navigate(Side, path: String)
    /// Open the entry with this name: a folder, or a symbolic link to one, is shown in this side.
    /// Files and packages are not opened yet.
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
    /// Replace the side's selection with these entry names.
    case select(Side, Set<String>)
    /// Show or hide hidden files on both sides.
    case toggleHiddenFiles
    /// Copy the active side's selection into the other side's folder.
    case copyToOtherSide
    /// Move the active side's selection into the other side's folder.
    case moveToOtherSide
    /// Copy items from anywhere (e.g. pasted from Finder) into the side's folder.
    case copyItems([String], into: Side)
    /// Move items from anywhere into the side's folder ("Move Item Here").
    case moveItems([String], into: Side)
    /// Move the side's selection to the Trash.
    case trashSelection(Side)
    /// Give an item a new name. The path, not a name in whatever the side shows by then, so a
    /// rename always hits the item it was started for. `side` selects the result.
    case rename(Side, path: String, newName: String)
    /// Ask the view to edit the name of the side's single selected entry.
    case requestRename(Side)
    case cancelRename(Side)
    /// Create a folder with a free name ("New Folder", "New Folder 2", ...), then edit its name.
    case newFolder(Side)
    case answerConflict(job: Int, ConflictAnswer)
    case cancelJob(Int)
    /// Remove a finished job (one that reported problems) from the list.
    case dismissJob(Int)
}
