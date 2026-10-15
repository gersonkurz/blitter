import AppKit
import BlitterModel

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let workspace = Workspace()
    private var windowController: MainWindowController?

    func applicationDidFinishLaunching(_: Notification) {
        NSApp.mainMenu = makeMainMenu()
        let controller = MainWindowController(workspace: workspace)
        controller.showWindow(nil)
        windowController = controller
        NSApp.activate()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_: NSApplication) -> Bool {
        true
    }

    @objc private func switchActiveSide(_: Any?) {
        workspace.perform(.switchActiveSide)
    }

    private func makeMainMenu() -> NSMenu {
        let mainMenu = NSMenu()

        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "About Blitter",
                        action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)),
                        keyEquivalent: "")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Quit Blitter", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        mainMenu.addItem(submenu: appMenu)

        let viewMenu = NSMenu(title: "View")
        let switchItem = viewMenu.addItem(withTitle: "Switch Active Side",
                                          action: #selector(switchActiveSide(_:)),
                                          keyEquivalent: "\t")
        switchItem.keyEquivalentModifierMask = []
        switchItem.target = self
        mainMenu.addItem(submenu: viewMenu)

        return mainMenu
    }
}

private extension NSMenu {
    func addItem(submenu: NSMenu) {
        let item = NSMenuItem()
        item.submenu = submenu
        addItem(item)
    }
}
