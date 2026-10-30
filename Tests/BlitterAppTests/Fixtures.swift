import BlitterCore
import Foundation

func folder(_ name: String) -> DirectoryEntry {
    DirectoryEntry(name: name, kind: .directory, size: 0, modificationDate: .distantPast, isHidden: false,
                   isDataless: false, error: 0)
}

func file(_ name: String) -> DirectoryEntry {
    DirectoryEntry(name: name, kind: .file, size: 1, modificationDate: .distantPast, isHidden: false,
                   isDataless: false, error: 0)
}
