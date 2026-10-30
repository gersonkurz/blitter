import AppKit
import BlitterCore
import BlitterModel

/// Icons for one side's file list. Every entry first gets its content type's icon, cached for the
/// whole app, which needs no disk access. Packages such as apps have their own icon; it is read in
/// the background, only when a cell asks for it, by a loader that belongs to this side alone.
@MainActor
final class FileIcons {
    private static var byType: [String: NSImage] = [:]
    private let packageIcons: PathLoader<NSImage>

    init(side: Side) {
        packageIcons = PathLoader(label: "Blitter.FileIcons.\(side)") { NSWorkspace.shared.icon(forFile: $0) }
    }

    func icon(for listed: ListedEntry, in folder: String, onLoaded: @escaping () -> Void) -> NSImage {
        if listed.contentType.conforms(to: .package) {
            let path = (folder as NSString).appendingPathComponent(listed.entry.name)
            if let icon = packageIcons.value(for: path, onLoaded: onLoaded) {
                return icon
            }
        }
        let identifier = listed.contentType.identifier
        if let cached = Self.byType[identifier] {
            return cached
        }
        let icon = NSWorkspace.shared.icon(for: listed.contentType)
        Self.byType[identifier] = icon
        return icon
    }

    /// Drops icon requests for a folder the side no longer shows.
    func cancelPending() {
        packageIcons.cancelAll()
    }
}
