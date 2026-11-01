import AppKit

/// Opens items with the app an external tool names (#18).
enum ExternalApps {
    /// Finds the app off the main thread, then hands the items to it; Launch Services starts it
    /// without the window waiting. `failed` gets a message for the jobs strip.
    @MainActor
    static func open(_ paths: [String], with app: String, failed: @escaping @MainActor (String) -> Void) {
        Task {
            let home = NSHomeDirectory()
            // Off the main thread: finding the app checks folders, and a file URL made without
            // `isDirectory` asks the disk — a selected item on a stalled volume must not freeze
            // the window.
            let (found, urls) = await Task.detached(priority: .userInitiated) {
                (resolve(app, home: home), paths.map { URL(fileURLWithPath: $0) })
            }.value
            guard let appURL = found else {
                failed("the app “\(app)” was not found.")
                return
            }
            let configuration = NSWorkspace.OpenConfiguration()
            NSWorkspace.shared.open(urls, withApplicationAt: appURL, configuration: configuration) { _, error in
                guard let error else {
                    return
                }
                let message = error.localizedDescription
                Task { @MainActor in failed(message) }
            }
        }
    }

    /// An app by path ("/Applications/iTerm.app", "~/Applications/X.app"), bundle identifier
    /// ("com.googlecode.iterm2") or name ("iTerm", "Visual Studio Code") in the usual folders.
    nonisolated static func resolve(_ app: String, home: String) -> URL? {
        let fileManager = FileManager.default
        if app.hasPrefix("/") || app.hasPrefix("~/") {
            let path = app.hasPrefix("~/") ? home + app.dropFirst() : app
            return fileManager.fileExists(atPath: path) ? URL(fileURLWithPath: path, isDirectory: true) : nil
        }
        if app.contains("."), !app.hasSuffix(".app"),
           let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: app)
        {
            return url
        }
        let name = app.hasSuffix(".app") ? app : app + ".app"
        let folders = ["/Applications", "/Applications/Utilities", "/System/Applications",
                       "/System/Applications/Utilities", home + "/Applications"]
        return folders.lazy.map { $0 + "/" + name }.first { fileManager.fileExists(atPath: $0) }
            .map { URL(fileURLWithPath: $0, isDirectory: true) }
    }
}
