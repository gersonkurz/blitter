import BlitterCore

// MARK: Free space (#51)

extension Workspace {
    /// Reads the free space on the volume of the side's folder in the background, after every
    /// listing. At most one read per side runs at a time, so a stalled volume holds one thread,
    /// never more: a listing that arrives meanwhile has the space read again once it returns.
    func updateFreeSpace(_ side: Side) {
        guard freeSpaceWork[side] == nil else {
            freeSpaceWanted.insert(side)
            return
        }
        guard let state = sides[side], state.status == .loaded else {
            return
        }
        let folder = state.entriesLocation
        let read = readFreeSpace
        freeSpaceWork[side] = Task { [weak self] in
            let bytes = await read(folder)
            self?.freeSpaceRead(side, folder: folder, bytes: bytes)
        }
    }

    private func freeSpaceRead(_ side: Side, folder: String, bytes: Int64?) {
        freeSpaceWork[side] = nil
        let space = bytes.map { FreeSpace(folder: folder, bytes: $0) }
        if sides[side]?.freeSpace != space {
            sides[side]?.freeSpace = space
            notifyChange()
        }
        if freeSpaceWanted.remove(side) != nil {
            updateFreeSpace(side)
        }
    }
}
