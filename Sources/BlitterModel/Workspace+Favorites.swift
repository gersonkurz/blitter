import Foundation

/// An entry of the tree's menu that changes the favorites.
public struct FavoriteMenuItem: Sendable {
    public let title: String
    public let command: Command
}

// MARK: Favorites

/// The tree's Favorites section: folders the user keeps at hand, in their order (#72). They are
/// `[favorites] folders` in the settings file; while the file has none, those saved with the
/// window state (set up in the tree before) stay, and the first change writes them to the file —
/// only that line, as zooming does with the font size. Changing them rebuilds the tree's roots
/// and the Go menu.
public extension Workspace {
    /// The favorites as absolute paths, in order, each once (the first kept): the file may name
    /// one twice, also as "~" and as its full path, and each is one root in the tree.
    var favorites: [String] {
        var seen: Set<String> = []
        let paths = (pendingFavorites ?? settings.favorites).map { $0.map(expandingHome) } ?? stateFavorites
        return paths.filter { seen.insert($0).inserted }
    }

    /// The favorites as the settings file writes them ("~" for the home folder).
    var favoritesAsWritten: [String] {
        pendingFavorites ?? settings.favorites ?? stateFavorites.map(abbreviatingHome)
    }

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

    /// "~/Projects" → "/Users/me/Projects"; any other path as it is.
    func expandingHome(_ path: String) -> String {
        path == "~" ? home : path.hasPrefix("~/") ? home + path.dropFirst() : path
    }

    /// "/Users/me/Projects" → "~/Projects": the settings file travels to another Mac.
    func abbreviatingHome(_ path: String) -> String {
        path == home ? "~" : path.hasPrefix(home + "/") ? "~" + path.dropFirst(home.count) : path
    }

    internal func addFavorite(_ path: String) -> Bool {
        guard !favorites.contains(path) else {
            return false
        }
        setFavorites(favorites + [path])
        return false // rebuilding notifies
    }

    internal func removeFavorite(_ path: String) -> Bool {
        guard favorites.contains(path) else {
            return false
        }
        setFavorites(favorites.filter { $0 != path })
        return false
    }

    internal func moveFavorite(_ path: String, by offset: Int) -> Bool {
        var list = favorites
        guard let index = list.firstIndex(of: path) else {
            return false
        }
        let (target, overflow) = index.addingReportingOverflow(offset)
        guard !overflow, list.indices.contains(target) else {
            return false // it would leave the list
        }
        list.insert(list.remove(at: index), at: target)
        setFavorites(list)
        return false
    }

    /// A change from the tree or the file list: shown at once, then written to the settings file.
    private func setFavorites(_ paths: [String]) {
        let before = favorites
        let written = paths.map(abbreviatingHome)
        settings.favorites = written
        stateFavorites = paths
        pendingFavorites = written
        favoritesChanged(from: before)
        saveFavorites()
    }

    /// The list changed (here or in the file): folders no longer among them lose their tree
    /// nodes (collapsed, so nothing is watched or read for them, #55 review), and the roots are
    /// built again. The same folders under other roots stay as they are.
    internal func favoritesChanged(from before: [String]) {
        let now = Set(favorites)
        for gone in before where !now.contains(gone) {
            let root = TreeSection.favorites.rawValue + ":" + gone
            for side in Side.allCases {
                for node in sides[side]?.tree.expanded ?? [] where node.root == root {
                    _ = collapseTreeNode(side, node)
                }
            }
        }
        rebuildTreeRoots()
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

    /// Writes the newest list into the settings file, one save after the other. Problems become a
    /// notice; the list stays as shown.
    private func saveFavorites() {
        guard let path = settingsFile, let list = pendingFavorites else {
            pendingFavorites = nil // the defaults only (tests): nothing to save
            return
        }
        // Each save is the newest only by its number: a list can come back to an earlier one
        // (#72 review), and an older save must then neither stand in for nor clear the newest.
        favoritesSaves += 1
        let generation = favoritesSaves
        let previous = favoritesSave
        let window = settingsSave // a Settings window save that started before: this one comes after it
        let beforeReplace = settingsFileBeforeReplace
        favoritesSave = Task { [weak self] in
            await previous?.value
            await window?.value
            guard let self, generation == favoritesSaves else {
                return // a newer change saves
            }
            let (problem, created) = await Self.editSettingsFile(
                path, what: "favorites", beforeReplace: beforeReplace,
                refusal: "the settings file sets them in a way only a text editor can change; change [favorites] there."
            ) { Settings.settingFavorites(list, in: $0) }
            if created {
                updateWatchedFolders(retry: true)
            }
            if generation == favoritesSaves {
                pendingFavorites = nil // the file has it now
                favoritesSave = nil
            }
            if let problem {
                addNotice(problem)
                notifyChange()
            }
        }
    }

    /// Writes a change still to be written; the app waits for this before it quits.
    func finishSavingFavorites() async {
        while let save = favoritesSave {
            await save.value
            if favoritesSave == save {
                break
            }
        }
    }
}
