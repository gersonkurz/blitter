import AppKit
import BlitterCore
import BlitterModel

/// The AppKit side of the Model's system services.
extension SystemServices {
    /// The settings file opens in whatever edits `.toml` files, or TextEdit if nothing does.
    private static func editText(_ path: String) {
        let url = URL(fileURLWithPath: path, isDirectory: false)
        NSWorkspace.shared.open(url, configuration: NSWorkspace.OpenConfiguration()) { _, error in
            guard error != nil else {
                return
            }
            DispatchQueue.main.async {
                let textEdit = URL(fileURLWithPath: "/System/Applications/TextEdit.app", isDirectory: true)
                NSWorkspace.shared.open(
                    [url],
                    withApplicationAt: textEdit,
                    configuration: NSWorkspace.OpenConfiguration()
                )
            }
        }
    }

    /// Every service, for the main window.
    static func appKit(window: MainWindowController) -> SystemServices {
        var services = SystemServices()
        services.open = openWithDefaultApp
        services.editText = editText
        services.reveal = { items in
            NSWorkspace.shared.activateFileViewerSelecting(items.map { $0.url as URL })
        }
        services.togglePreview = { [weak window] side in window?.togglePreview(on: side) }
        services.copyToPasteboard = { items in
            NSPasteboard.general.clearContents()
            NSPasteboard.general.writeObjects(items.map(\.url))
        }
        services.openWithApp = { app, paths, failed in ExternalApps.open(paths, with: app, failed: failed) }
        services.present = DialogHost.present
        services.eject = { path, failed in
            Task {
                do {
                    try await ejectVolume(at: path)
                } catch {
                    failed(error.localizedDescription) // the Task is the main actor's; the eject itself is not
                }
            }
        }
        services.showMenu = { [weak window] menu, side, seconds in window?.showMenu(menu, side: side, for: seconds) }
        services.copyText = { text in
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
        }
        return services
    }

    /// Asynchronous, so a slow app launch or volume never holds up the window.
    private static func openWithDefaultApp(_ path: String) {
        NSWorkspace.shared.open(
            URL(fileURLWithPath: path, isDirectory: false),
            configuration: NSWorkspace.OpenConfiguration()
        ) { _, error in
            if error != nil {
                DispatchQueue.main.async { NSSound.beep() }
            }
        }
    }
}
