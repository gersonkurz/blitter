import AppKit
import BlitterModel

/// One side of the window: the folder tree next to the file list, with a splitter whose
/// position is saved per side.
@MainActor
final class SideViewController: NSSplitViewController {
    let side: Side
    private let workspace: Workspace
    private let tree: FolderTreeViewController
    private let fileList: FileListViewController

    init(workspace: Workspace, side: Side) {
        self.workspace = workspace
        self.side = side
        tree = FolderTreeViewController(workspace: workspace, side: side)
        fileList = FileListViewController(workspace: workspace, side: side)
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    override func viewDidLoad() {
        splitView.isVertical = true
        splitView.dividerStyle = .thin
        let treeItem = NSSplitViewItem(viewController: tree)
        treeItem.minimumThickness = 140
        treeItem.maximumThickness = 500
        // The tree keeps its width when the window is resized; the file list takes the rest.
        treeItem.holdingPriority = .defaultLow + 1
        addSplitViewItem(treeItem)
        addSplitViewItem(NSSplitViewItem(viewController: fileList))
        // Set after the items exist, so the saved position applies to them.
        splitView.autosaveName = "Side-\(side)"
        super.viewDidLoad()
    }

    func render() {
        tree.render()
        fileList.render()
        // The active side gets keyboard focus, unless something inside it (tree, path field) has it.
        if workspace.activeSide == side, let window = view.window,
           (window.firstResponder as? NSView)?.isDescendant(of: view) != true
        {
            fileList.focusList()
        }
    }

    func togglePreview() {
        fileList.toggleQuickLook()
    }

    func focusPathField() {
        fileList.focusPathField()
    }
}
