import AppKit
import BlitterCore
import BlitterModel

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuItemValidation, NSMenuDelegate {
    private let stateStore = StateStore()
    /// Starts where the last session ended.
    private lazy var workspace = AppEnvironment.isHostedTest ? Workspace()
        : Workspace(restoring: stateStore.load(), settingsFile: UserPaths.settingsFile)
    private var windowController: MainWindowController?

    func applicationDidFinishLaunching(_: Notification) {
        NSApp.mainMenu = makeMainMenu()
        // Hosting the app tests: the menu is all they need. No window, nothing saved, so a test
        // run never touches the user's workspace or layout.
        guard !AppEnvironment.isHostedTest else {
            return
        }
        let controller = MainWindowController(workspace: workspace)
        workspace.system = .appKit(window: controller)
        controller.afterRender = { [weak self] in
            guard let self else {
                return
            }
            stateStore.save(workspace.savedState)
        }
        controller.showWindow(nil)
        windowController = controller
        observeVolumes()
        NSApp.activate()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_: NSApplication) -> Bool {
        // The test host has no main window; closing a test's window must not end the run.
        !AppEnvironment.isHostedTest
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

    @objc private func newFolder(_: Any?) {
        workspace.perform(.newFolder(workspace.activeSide))
    }

    @objc private func rename(_: Any?) {
        workspace.perform(.requestRename(workspace.activeSide))
    }

    @objc private func copyToOtherSide(_: Any?) {
        workspace.perform(.copyToOtherSide)
    }

    @objc private func moveToOtherSide(_: Any?) {
        workspace.perform(.moveToOtherSide)
    }

    @objc private func openSettings(_: Any?) {
        workspace.perform(.openSettingsFile)
    }

    @objc private func revealInFinder(_: Any?) {
        workspace.perform(.revealInFinder(workspace.activeSide))
    }

    /// A menu item whose `representedObject` is an action id runs that action on the active side.
    @objc private func runAction(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String else {
            return
        }
        workspace.perform(.runAction(id, workspace.activeSide))
    }

    @objc private func moveToTrash(_: Any?) {
        workspace.perform(.trashSelection(workspace.activeSide))
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
        // While text is edited (path field, a name), keys such as ⌘⌫ belong to the text.
        let isEditingText = NSApp.keyWindow?.firstResponder is NSText
        switch menuItem.action {
        case #selector(runAction(_:)):
            guard let id = menuItem.representedObject as? String else {
                return false
            }
            return !isEditingText && workspace.canRun(id, on: workspace.activeSide)
        case #selector(copyToOtherSide(_:)), #selector(moveToOtherSide(_:)), #selector(moveToTrash(_:)):
            return !isEditingText && !active.selection.isEmpty
        case #selector(revealInFinder(_:)):
            return !active.selection.isEmpty
        case #selector(rename(_:)):
            return !isEditingText && active.selection.count == 1
        case #selector(newFolder(_:)):
            return !isEditingText && active.status == .loaded
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
        let settings = appMenu.addItem(withTitle: "Settings…", action: #selector(openSettings(_:)), keyEquivalent: ",")
        settings.target = self
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
        let moveHere = editMenu.addItem(withTitle: "Move Item Here", action: Selector(("moveItemsHere:")),
                                        keyEquivalent: "v")
        moveHere.keyEquivalentModifierMask = [.command, .option]
        addActionItem(to: editMenu, "copy-path", key: "c", modifiers: [.command, .option])
        addActionItem(to: editMenu, "copy-name", key: "c", modifiers: [.command, .option, .shift])
        editMenu.addItem(withTitle: "Select All", action: #selector(NSResponder.selectAll(_:)), keyEquivalent: "a")
        mainMenu.addItem(submenu: editMenu)

        let fileMenu = makeFileMenu()
        let fileItem = NSMenuItem()
        fileItem.submenu = fileMenu
        mainMenu.insertItem(fileItem, at: 1) // after the app menu, before Edit

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

        // Filled from the settings' tools each time it opens, so a changed file shows at once.
        let toolsMenu = NSMenu(title: "Tools")
        toolsMenu.delegate = self
        mainMenu.addItem(submenu: toolsMenu)

        return mainMenu
    }

    private func makeFileMenu() -> NSMenu {
        let fileMenu = NSMenu(title: "File")
        addItem(to: fileMenu, title: "New Folder", action: #selector(newFolder(_:)), key: "n",
                modifiers: [.command, .shift])
        addItem(to: fileMenu, title: "Rename", action: #selector(rename(_:)), key: Self.functionKey(NSF2FunctionKey),
                modifiers: [])
        fileMenu.addItem(.separator())
        addItem(to: fileMenu, title: "Copy to Other Side", action: #selector(copyToOtherSide(_:)),
                key: Self.functionKey(NSF5FunctionKey), modifiers: [])
        addItem(to: fileMenu, title: "Move to Other Side", action: #selector(moveToOtherSide(_:)),
                key: Self.functionKey(NSF6FunctionKey), modifiers: [])
        addItem(to: fileMenu, title: "Reveal in Finder", action: #selector(revealInFinder(_:)), key: "r",
                modifiers: [.command, .option])
        fileMenu.addItem(.separator())
        addItem(to: fileMenu, title: "Move to Trash", action: #selector(moveToTrash(_:)), key: "\u{8}",
                modifiers: [.command])
        addActionItem(to: fileMenu, "delete-immediately", key: "\u{8}", modifiers: [.command, .option])
        // Shown in its place while ⇧ is held.
        addActionItem(to: fileMenu, "delete-immediately-without-asking", key: "\u{8}",
                      modifiers: [.command, .option, .shift])
        fileMenu.items.last?.isAlternate = true
        return fileMenu
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        guard menu.title == "Tools" else {
            return
        }
        menu.removeAllItems()
        for tool in workspace.settings.tools {
            addActionItem(to: menu, tool.id, key: "", modifiers: [])
        }
        if menu.items.isEmpty {
            menu.addItem(withTitle: "No Tools in the Settings", action: nil, keyEquivalent: "")
        }
    }

    /// An item that runs an action from the registry, with the action's title.
    private func addActionItem(to menu: NSMenu, _ id: String, key: String, modifiers: NSEvent.ModifierFlags) {
        guard let action = workspace.actionRegistry.action(id) else {
            return
        }
        addItem(to: menu, title: action.title, action: #selector(runAction(_:)), key: key, modifiers: modifiers)
        menu.items.last?.representedObject = id
    }

    private static func functionKey(_ key: Int) -> String {
        String(Character(UnicodeScalar(UInt16(key))!)) // swiftlint:disable:this force_unwrapping
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
