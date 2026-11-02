/// Commands that change what a side shows, not where it is.
extension Workspace {
    func activate(_ side: Side) -> Bool {
        guard activeSide != side else {
            return false
        }
        activeSide = side
        return true
    }

    func refresh(_ side: Side) -> Bool {
        load(side)
        return true
    }

    func sort(_ side: Side, _ order: ListSort) -> Bool {
        guard sides[side]?.sort != order else {
            return false
        }
        sides[side]?.sort = order
        relist(side)
        return true
    }

    func select(_ side: Side, _ names: Set<String>) -> Bool {
        sides[side]?.selectsFirstMatch = false // a choice made: the fast filter leaves it (#39)
        guard sides[side]?.selection != names else {
            return false
        }
        sides[side]?.selection = names
        return true
    }

    func toggleHiddenFiles() -> Bool {
        showsHiddenFiles.toggle()
        for side in Side.allCases {
            if sides[side]?.find != nil {
                load(side) // hidden folders are searched, or not (#48)
            } else {
                relist(side)
            }
            sides[side]?.tree.version += 1
        }
        return true
    }
}
