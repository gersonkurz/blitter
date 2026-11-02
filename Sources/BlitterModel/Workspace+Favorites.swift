/// An entry of the tree's menu that changes the favorites.
public struct FavoriteMenuItem: Sendable {
    public let title: String
    public let command: Command
}

// MARK: Favorites

/// The tree's Favorites section: folders the user keeps at hand, in their order. Changing them
/// rebuilds the tree's roots; the list is saved with the workspace state.
public extension Workspace {
    /// What the tree's menu offers for `folder`: to add it, or, for a favorite, to move it up or
    /// down (where it can go) and to remove it.
    func favoriteMenu(for folder: String) -> [FavoriteMenuItem] {
        guard let index = favorites.firstIndex(of: folder) else {
            return [FavoriteMenuItem(title: "Add to Favorites", command: .addFavorite(folder))]
        }
        var items: [FavoriteMenuItem] = []
        if index > 0 {
            items.append(FavoriteMenuItem(title: "Move Up in Favorites", command: .moveFavorite(folder, offset: -1)))
        }
        if index < favorites.count - 1 {
            items.append(FavoriteMenuItem(title: "Move Down in Favorites", command: .moveFavorite(folder, offset: 1)))
        }
        items.append(FavoriteMenuItem(title: "Remove from Favorites", command: .removeFavorite(folder)))
        return items
    }

    internal func addFavorite(_ path: String) -> Bool {
        guard !favorites.contains(path) else {
            return false
        }
        favorites.append(path)
        rebuildTreeRoots()
        return false // rebuilding notifies
    }

    internal func removeFavorite(_ path: String) -> Bool {
        guard let index = favorites.firstIndex(of: path) else {
            return false
        }
        favorites.remove(at: index)
        // Its nodes go with it: collapsed, so nothing is watched or read for them any more
        // (#55 review). The same folders under other roots stay as they are.
        let root = TreeSection.favorites.rawValue + ":" + path
        for side in Side.allCases {
            for node in sides[side]?.tree.expanded ?? [] where node.root == root {
                _ = collapseTreeNode(side, node)
            }
        }
        rebuildTreeRoots()
        return false
    }

    internal func moveFavorite(_ path: String, by offset: Int) -> Bool {
        guard let index = favorites.firstIndex(of: path) else {
            return false
        }
        let (target, overflow) = index.addingReportingOverflow(offset)
        guard !overflow, favorites.indices.contains(target) else {
            return false // it would leave the list
        }
        favorites.insert(favorites.remove(at: index), at: target)
        rebuildTreeRoots()
        return false
    }

    /// The favorites, then the volumes and cloud drives read so far. Each side's tree selects its
    /// folder again, under a root that still contains it.
    internal func rebuildTreeRoots() {
        treeRoots = TreeRoots.favorites(favorites, home: home) + TreeRoots.Part.allCases.flatMap { rootParts[$0] ?? [] }
        for side in Side.allCases {
            revealInTree(side, preferredRoot: nil)
        }
        notifyChange()
    }
}
