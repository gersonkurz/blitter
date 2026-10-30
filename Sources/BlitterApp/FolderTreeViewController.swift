import AppKit
import BlitterModel
import UniformTypeIdentifiers

/// One side's folder tree: the sections (Favorites, Volumes, Cloud) with their roots, and the
/// subfolders the workspace has read. It renders the side's tree state and turns expanding,
/// collapsing and selecting into workspace commands.
@MainActor
final class FolderTreeViewController: NSViewController, NSOutlineViewDataSource, NSOutlineViewDelegate {
    private let workspace: Workspace
    let side: Side
    private let outlineView = ActivatingOutlineView()
    private var renderedVersion = -1
    private var renderedRoots: [TreeRoot] = []
    private var isRendering = false
    /// Items by key, so the outline view sees the same object for a node across reloads.
    private var items: [String: TreeItem] = [:]
    /// Children per item, computed once per rebuild: the outline view asks for every child by index.
    private var childCache: [ObjectIdentifier: [TreeItem]] = [:]
    private var topLevelCache: [TreeItem]?

    init(workspace: Workspace, side: Side) {
        self.workspace = workspace
        self.side = side
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    override func loadView() {
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("folder"))
        outlineView.addTableColumn(column)
        outlineView.outlineTableColumn = column
        outlineView.headerView = nil
        outlineView.style = .sourceList
        outlineView.rowSizeStyle = .small
        outlineView.floatsGroupRows = false
        outlineView.autoresizesOutlineColumn = false
        outlineView.dataSource = self
        outlineView.delegate = self
        outlineView.onBecomeFirstResponder = { [weak self] in
            guard let self else {
                return
            }
            workspace.perform(.activate(side))
        }

        let scrollView = NSScrollView()
        scrollView.documentView = outlineView
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = false
        view = scrollView
    }

    // MARK: Rendering

    func render() {
        isRendering = true
        defer { isRendering = false }
        let tree = workspace.state(of: side).tree
        if tree.version != renderedVersion || workspace.treeRoots != renderedRoots {
            renderedVersion = tree.version
            renderedRoots = workspace.treeRoots
            rebuild(expanded: tree.expanded)
        }
        select(tree.selection)
    }

    /// Reloads everything and expands what the model says is expanded, top down, so each child
    /// exists before it is expanded. The tree holds a few hundred rows at most.
    private func rebuild(expanded: Set<TreeNodeID>) {
        childCache.removeAll()
        topLevelCache = nil
        outlineView.reloadData()
        for section in visibleSections() {
            let item = sectionItem(section)
            outlineView.expandItem(item)
            for root in workspace.treeRoots where root.section == section {
                expand(nodeItem(TreeNodeID(root: root.id, path: root.path), title: root.title, root: root),
                       ifIn: expanded)
            }
        }
    }

    private func expand(_ item: TreeItem, ifIn expanded: Set<TreeNodeID>) {
        guard let node = item.node, expanded.contains(node) else {
            return
        }
        outlineView.expandItem(item)
        for child in children(of: item) {
            expand(child, ifIn: expanded)
        }
    }

    private func select(_ node: TreeNodeID?) {
        guard let node, let item = items[Self.key(node)], case let row = outlineView.row(forItem: item), row >= 0
        else {
            outlineView.deselectAll(nil)
            return
        }
        if outlineView.selectedRow != row {
            outlineView.selectRowIndexes([row], byExtendingSelection: false)
            outlineView.scrollRowToVisible(row)
        }
    }

    // MARK: Items

    private func visibleSections() -> [TreeSection] {
        TreeSection.allCases.filter { section in workspace.treeRoots.contains { $0.section == section } }
    }

    private func children(of item: TreeItem?) -> [TreeItem] {
        guard let item else {
            if let cached = topLevelCache {
                return cached
            }
            let sections = visibleSections().map(sectionItem)
            topLevelCache = sections
            return sections
        }
        if let cached = childCache[ObjectIdentifier(item)] {
            return cached
        }
        let children = makeChildren(of: item)
        childCache[ObjectIdentifier(item)] = children
        return children
    }

    private func makeChildren(of item: TreeItem) -> [TreeItem] {
        if let section = item.section {
            return workspace.treeRoots.filter { $0.section == section }.map {
                nodeItem(TreeNodeID(root: $0.id, path: $0.path), title: $0.title, root: $0)
            }
        }
        guard let node = item.node, case let .loaded(folders)? = workspace.treeChildren(of: node.path, on: side) else {
            return []
        }
        return folders.map {
            nodeItem(TreeNodeID(root: node.root, path: (node.path as NSString).appendingPathComponent($0.name)),
                     title: $0.name,
                     isHidden: $0.isHidden)
        }
    }

    private func sectionItem(_ section: TreeSection) -> TreeItem {
        let key = "section:" + section.rawValue
        if let item = items[key] {
            return item
        }
        let item = TreeItem(section: section, node: nil, title: section.title, root: nil, isHidden: false)
        items[key] = item
        return item
    }

    private func nodeItem(_ node: TreeNodeID, title: String, root: TreeRoot? = nil, isHidden: Bool = false)
        -> TreeItem
    {
        let key = Self.key(node)
        if let item = items[key], item.title == title, item.isHidden == isHidden {
            return item
        }
        let item = TreeItem(section: nil, node: node, title: title, root: root, isHidden: isHidden)
        items[key] = item
        return item
    }

    private static func key(_ node: TreeNodeID) -> String {
        node.root + "|" + node.path
    }

    // MARK: NSOutlineViewDataSource / NSOutlineViewDelegate

    func outlineView(_: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
        children(of: item as? TreeItem).count
    }

    func outlineView(_: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
        children(of: item as? TreeItem)[index]
    }

    func outlineView(_: NSOutlineView, isItemExpandable item: Any) -> Bool {
        guard let item = item as? TreeItem else {
            return false
        }
        guard let node = item.node else {
            return true // a section
        }
        // Until a folder has been read, assume it has subfolders.
        if case let .loaded(folders)? = workspace.treeChildren(of: node.path, on: side) {
            return !folders.isEmpty
        }
        return true
    }

    func outlineView(_: NSOutlineView, isGroupItem item: Any) -> Bool {
        (item as? TreeItem)?.section != nil
    }

    func outlineView(_: NSOutlineView, shouldSelectItem item: Any) -> Bool {
        (item as? TreeItem)?.node != nil
    }

    func outlineView(_ outlineView: NSOutlineView, viewFor _: NSTableColumn?, item: Any) -> NSView? {
        guard let item = item as? TreeItem else {
            return nil
        }
        let isSection = item.section != nil
        let identifier = NSUserInterfaceItemIdentifier(isSection ? "section" : "node")
        let cell = outlineView.makeView(withIdentifier: identifier, owner: nil) as? NSTableCellView
            ?? Self.makeCell(identifier: identifier, withImage: !isSection)
        cell.textField?.stringValue = item.title
        cell.textField?.textColor = item.isHidden ? .secondaryLabelColor : nil
        cell.imageView?.image = isSection ? nil : TreeIcons.icon(for: item.root?.kind)
        return cell
    }

    func outlineViewItemDidExpand(_ notification: Notification) {
        guard !isRendering, let node = (notification.userInfo?["NSObject"] as? TreeItem)?.node else {
            return
        }
        workspace.perform(.expandTreeNode(side, node))
    }

    func outlineViewItemDidCollapse(_ notification: Notification) {
        guard !isRendering, let node = (notification.userInfo?["NSObject"] as? TreeItem)?.node else {
            return
        }
        workspace.perform(.collapseTreeNode(side, node))
    }

    func outlineViewSelectionDidChange(_: Notification) {
        guard !isRendering, let node = (outlineView.item(atRow: outlineView.selectedRow) as? TreeItem)?.node else {
            return
        }
        workspace.perform(.selectTreeNode(side, node))
    }

    private static func makeCell(identifier: NSUserInterfaceItemIdentifier, withImage: Bool) -> NSTableCellView {
        let cell = NSTableCellView()
        cell.identifier = identifier
        let text = NSTextField(labelWithString: "")
        text.lineBreakMode = .byTruncatingTail
        text.translatesAutoresizingMaskIntoConstraints = false
        cell.addSubview(text)
        cell.textField = text
        var constraints = [
            text.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
            text.trailingAnchor.constraint(lessThanOrEqualTo: cell.trailingAnchor, constant: -2),
        ]
        if withImage {
            let image = NSImageView()
            image.translatesAutoresizingMaskIntoConstraints = false
            cell.addSubview(image)
            cell.imageView = image
            constraints += [
                image.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 2),
                image.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
                image.widthAnchor.constraint(equalToConstant: 16),
                image.heightAnchor.constraint(equalToConstant: 16),
                text.leadingAnchor.constraint(equalTo: image.trailingAnchor, constant: 4),
            ]
        } else {
            constraints.append(text.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 2))
        }
        NSLayoutConstraint.activate(constraints)
        return cell
    }
}

/// A row of the folder tree: a section header or a folder under a root.
final class TreeItem {
    let section: TreeSection?
    let node: TreeNodeID?
    let title: String
    /// Set for the top folder of a root, which gets the root's icon.
    let root: TreeRoot?
    let isHidden: Bool

    init(section: TreeSection?, node: TreeNodeID?, title: String, root: TreeRoot?, isHidden: Bool) {
        self.section = section
        self.node = node
        self.title = title
        self.root = root
        self.isHidden = isHidden
    }
}

/// Tree icons from SF Symbols and the generic folder type, so drawing the tree never reads the disk.
@MainActor
enum TreeIcons {
    private static var cache: [String: NSImage] = [:]

    static func icon(for kind: TreeRoot.Kind?) -> NSImage {
        let symbol = switch kind {
        case .home?: "house"
        case .desktop?: "menubar.dock.rectangle"
        case .documents?: "doc"
        case .downloads?: "arrow.down.circle"
        case .applications?: "square.grid.3x3"
        case let .volume(isRoot, isLocal)?: isRoot ? "internaldrive" : isLocal ? "externaldrive" : "network"
        case .cloud?: "icloud"
        case nil: "folder"
        }
        if let cached = cache[symbol] {
            return cached
        }
        let image = kind == nil ? NSWorkspace.shared.icon(for: .folder)
            : NSImage(systemSymbolName: symbol, accessibilityDescription: nil) ?? NSWorkspace.shared.icon(for: .folder)
        cache[symbol] = image
        return image
    }
}

/// An outline view that reports when it gains keyboard focus, which makes its side the active side.
final class ActivatingOutlineView: NSOutlineView {
    var onBecomeFirstResponder: (() -> Void)?

    override func becomeFirstResponder() -> Bool {
        let accepted = super.becomeFirstResponder()
        if accepted {
            onBecomeFirstResponder?()
        }
        return accepted
    }
}
