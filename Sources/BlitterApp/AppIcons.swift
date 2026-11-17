import AppKit
import BlitterCore

/// The icons of the apps tools open (#110), by the app as the settings name it. Finding an app
/// and reading its icon touch the disk, so both run off the main thread; each app is looked up
/// once, found or not, and shared by every window and the Settings window.
@MainActor
final class AppIcons {
    static let shared = AppIcons()

    /// Looked up: the app's icon, or nil when there is no such app.
    private var icons: [String: NSImage?] = [:]
    /// Lookups under way, so an app is looked up once however often it is asked for.
    private var lookups: [String: Task<SendableImage?, Never>] = [:]

    /// The icon if it has been looked up and the app was found.
    func cached(_ app: String) -> NSImage? {
        icons[app] ?? nil
    }

    /// Whether the app has been looked up, found or not.
    func isKnown(_ app: String) -> Bool {
        icons[app] != nil
    }

    /// The app's icon, looking it up first if need be; nil when the app is not found.
    func icon(for app: String) async -> NSImage? {
        if let known = icons[app] {
            return known
        }
        let lookup = lookups[app] ?? Task.detached(priority: .userInitiated) { Self.lookUp(app) }
        lookups[app] = lookup
        let icon = await lookup.value?.image
        icons[app] = .some(icon)
        lookups[app] = nil
        return icon
    }

    /// Off the main thread: the app, then its icon. The image is not touched again here, so
    /// handing it to the main actor is safe.
    private nonisolated static func lookUp(_ app: String) -> SendableImage? {
        guard let url = ExternalApps.resolve(app, home: UserPaths.home) else {
            return nil
        }
        return SendableImage(image: NSWorkspace.shared.icon(forFile: url.path))
    }

    private struct SendableImage: @unchecked Sendable {
        let image: NSImage
    }

    /// An app's icon at a toolbar symbol's size: a copy, so the cached one keeps its size.
    static func sized(_ icon: NSImage, _ side: CGFloat = 18) -> NSImage {
        let copy = icon.copy() as? NSImage ?? icon
        copy.size = NSSize(width: side, height: side)
        return copy
    }
}
