import AppKit
import BlitterModel

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuItemValidation {
    private let workspace = Workspace()
    private var windowController: MainWindowController?

    func applicationDidFinishLaunching(_: Notification) {
        NSApp.mainMenu = makeMainMenu()
        let controller = MainWindowController(workspace: workspace)
        controller.showWindow(nil)
        windowController = controller
        observeVolumes()
        NSApp.activate()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_: NSApplication) -> Bool {
        true
    }

    /// Mounting, unmounting or renaming a volume changes the tree's Volumes section.
    private func observeVolumes() {
        let center = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didMountNotification, NSWorkspace.didUnmountNotification,
                     NSWorkspace.didRenameVolumeNotification]
        {
            center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.workspace.perform(.refreshTreeRoots)
                }
            }
        }
    }

    // MARK: Menu actions (each one is a single workspace command)

    @objc private func goBack(_: Any?) {
        workspace.perform(.goBack(workspace.activeSide))
    }

    @objc private func goForward(_: Any?) {
        workspace.perform(.goForward(workspace.activeSide))
    }

    @objc private func goToParent(_: Any?) {
        workspace.perform(.goToParent(workspace.activeSide))
    }

    /// Only moves keyboard focus; the navigation itself happens when the path is entered.
    @objc private func goToFolder(_: Any?) {
        windowController?.focusPathField(of: workspace.activeSide)
    }

    @objc private func switchActiveSide(_: Any?) {
        workspace.perform(.switchActiveSide)
    }

    @objc private func toggleHiddenFiles(_: Any?) {
        workspace.perform(.toggleHiddenFiles)
    }

    @objc private func refresh(_: Any?) {
        workspace.perform(.refresh(workspace.activeSide))
    }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        let active = workspace.state(of: workspace.activeSide)
        switch menuItem.action {
        case #selector(toggleHiddenFiles(_:)):
            menuItem.state = workspace.showsHiddenFiles ? .on : .off
            return true
        case #selector(goBack(_:)):
            return active.canGoBack
        case #selector(goForward(_:)):
            return active.canGoForward
        case #selector(goToParent(_:)):
            return active.canGoToParent
        default:
            return true
        }
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

        // No target: these go to the first responder, e.g. the path field while it is edited.
        let editMenu = NSMenu(title: "Edit")
        editMenu.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        editMenu.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "Z")
        editMenu.addItem(.separator())
        editMenu.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(withTitle: "Select All", action: #selector(NSResponder.selectAll(_:)), keyEquivalent: "a")
        mainMenu.addItem(submenu: editMenu)

        let viewMenu = NSMenu(title: "View")
        addItem(to: viewMenu, title: "Switch Active Side", action: #selector(switchActiveSide(_:)),
                key: "\t", modifiers: [])
        addItem(to: viewMenu, title: "Show Hidden Files", action: #selector(toggleHiddenFiles(_:)),
                key: ".", modifiers: [.command, .shift])
        addItem(to: viewMenu, title: "Refresh", action: #selector(refresh(_:)), key: "r", modifiers: [.command])
        mainMenu.addItem(submenu: viewMenu)

        let goMenu = NSMenu(title: "Go")
        addItem(to: goMenu, title: "Back", action: #selector(goBack(_:)), key: "[", modifiers: [.command])
        addItem(to: goMenu, title: "Forward", action: #selector(goForward(_:)), key: "]", modifiers: [.command])
        addItem(to: goMenu, title: "Enclosing Folder", action: #selector(goToParent(_:)),
                key: String(Character(UnicodeScalar(NSUpArrowFunctionKey)!)),
                modifiers: [.command]) // swiftlint:disable:this force_unwrapping
        goMenu.addItem(.separator())
        addItem(to: goMenu, title: "Go to Folder…", action: #selector(goToFolder(_:)), key: "g",
                modifiers: [.command, .shift])
        mainMenu.addItem(submenu: goMenu)

        return mainMenu
    }

    private func addItem(to menu: NSMenu, title: String, action: Selector, key: String,
                         modifiers: NSEvent.ModifierFlags)
    {
        let item = menu.addItem(withTitle: title, action: action, keyEquivalent: key)
        item.keyEquivalentModifierMask = modifiers
        item.target = self
    }
}

private extension NSMenu {
    func addItem(submenu: NSMenu) {
        let item = NSMenuItem()
        item.submenu = submenu
        addItem(item)
    }
}
