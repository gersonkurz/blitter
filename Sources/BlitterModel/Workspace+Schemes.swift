import BlitterCore
import Foundation

/// Color schemes the settings name by a tinted-theming name, a file or an address (#34). They
/// are looked for while the settings are read; one not fetched yet is fetched afterwards, and the
/// settings are read again once it is there. Until then the system's colors are used.
extension Workspace {
    /// Fetched schemes are kept in the settings folder's `schemes`.
    nonisolated static func schemesFolder(of settingsFile: String) -> String {
        (settingsFile as NSString).deletingLastPathComponent + "/schemes"
    }

    /// Off the main actor: scheme files are read here.
    nonisolated static func resolveSchemes(_ settings: Settings, folder: String, home: String) async
        -> (resolved: (settings: Settings, problems: [String]), downloads: [SchemeDownload])
    {
        var settings = settings
        let (problems, downloads) = settings.theme.resolve(cacheFolder: folder, home: home)
        return ((settings, problems), downloads)
    }

    /// Fetches each scheme not already being fetched. A failure becomes a notice and is not tried
    /// again until the settings are read again (the file changed, or the next launch).
    func download(_ downloads: [SchemeDownload]) {
        for download in downloads where schemeWork[download.name] == nil {
            let fetch = fetch
            schemeWork[download.name] = Task { [weak self] in
                let failure = await Self.fetchScheme(download, with: fetch)
                guard let self else {
                    return
                }
                schemeWork[download.name] = nil
                if let failure {
                    addNotice("The color scheme “\(download.name)” could not be fetched: \(failure)")
                    notifyChange()
                } else {
                    loadSettings() // finds it now
                }
            }
        }
    }

    /// Tries each address in turn; keeps the first answer that is a scheme. Returns nil when
    /// it is kept, else why not.
    private nonisolated static func fetchScheme(_ download: SchemeDownload,
                                                with fetch: @Sendable (URL) async throws -> Data) async -> String?
    {
        var failure = "nothing to fetch it from."
        for url in download.urls {
            do {
                let data = try await fetch(url)
                guard let text = String(bytes: data, encoding: .utf8), Base24Scheme.fromYAML(text) != nil else {
                    failure = "\(url.absoluteString) is not a Base16 or Base24 scheme."
                    continue
                }
                // Never written over (createIfMissing); a file already there would be read again
                // and again instead of this one: then it is reported.
                guard !Base24Scheme.entryExists(download.cachePath) else {
                    return "\(download.cachePath) is in the way."
                }
                try await TextFiles.createIfMissing(download.cachePath, contents: text)
                // Done only once the kept file reads back as a scheme, so a reload can never find
                // it missing and fetch again, whatever is at the path (#34 review).
                guard Base24Scheme.read(download.cachePath) != nil else {
                    return "it could not be kept in \(download.cachePath)."
                }
                return nil
            } catch {
                failure = "\(url.absoluteString): \(error.localizedDescription)."
            }
        }
        return failure
    }
}
