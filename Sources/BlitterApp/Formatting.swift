import AppKit
import BlitterCore

@MainActor
enum Formatting {
    private static let sizeFormatter: ByteCountFormatter = {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return formatter
    }()

    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        formatter.doesRelativeDateFormatting = true
        return formatter
    }()

    static func size(of entry: DirectoryEntry) -> String {
        entry.kind == .directory ? "--" : sizeFormatter.string(fromByteCount: entry.size)
    }

    static func date(_ date: Date) -> String {
        dateFormatter.string(from: date)
    }
}
