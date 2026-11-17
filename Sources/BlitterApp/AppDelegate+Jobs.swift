import AppKit

/// The Window menu (#112): AppKit's own window items and list, and the Jobs window.
extension AppDelegate {
    func makeWindowMenu() -> NSMenu {
        let windowMenu = NSMenu(title: "Window")
        windowMenu.addItem(
            withTitle: "Minimize",
            action: #selector(NSWindow.performMiniaturize(_:)),
            keyEquivalent: "m"
        )
        windowMenu.addItem(withTitle: "Zoom", action: #selector(NSWindow.performZoom(_:)), keyEquivalent: "")
        windowMenu.addItem(.separator())
        addItem(
            to: windowMenu,
            title: "Jobs",
            action: #selector(showJobs(_:)),
            key: "j",
            modifiers: [.command, .option]
        )
        NSApp.windowsMenu = windowMenu
        return windowMenu
    }

    @objc func showJobs(_: Any?) {
        JobsWindowController.shared.showByUser()
    }
}
