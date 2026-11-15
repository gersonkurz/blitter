import AppKit
import BlitterCore
import BlitterModel

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuItemValidation, NSMenuDelegate {
    /// The main windows (#96): the only owner of their workspaces.
    let windows = MainWindows()
    /// The test host opens no window: its menus act on a workspace of their own.
    private lazy var hostWorkspace = Workspace()
    /// What the menus, shortcuts and automation act on: the front main window's workspace.
    var workspace: Workspace {
        windows.front?.workspace ?? hostWorkspace
    }

    /// The front main window; nil in the test host, which opens none.
    var windowController: MainWindowController? {
        windows.front
    }

    /// What is at `/usr/local/bin/blitter` (#97), as last read off the main thread.
    var commandLineToolStatus = CommandLineTool.Status.notInstalled
    /// The automation socket (#58), while the app runs.
    private var automationServer: LineSocketServer?
    /// The menus whose action items come from the settings (#24), and what they were built from.
    var fileMenuItems: NSMenu?
    var editMenuItems: NSMenu?
    var renderedMenuBar: MenuBarSettings?
    var renderedTools: [Tool]?
    /// Go → Favorites (#72), and the favorites it was built from.
    let favoritesMenu = NSMenu(title: "Favorites")
    var renderedFavorites: [TreeRoot]?

    func applicationDidFinishLaunching(_: Notification) {
        refreshCommandLineTool()
        // Hosting the app tests: the menu is all they need. No window, nothing saved, so a test
        // run never touches the user's workspace or layout.
        guard !AppEnvironment.isHostedTest else {
            NSApp.mainMenu = makeMainMenu()
            return
        }
        registerDialogs()
        windows.configure = { [weak self] controller in
            controller.afterRender = { [weak self] in
                guard let self else {
                    return
                }
                windows.save()
                updateMenuBar() // the settings file may have changed the menus
                SettingsWindowController.current?.model.workspaceChanged()
            }
        }
        // The last session's windows (not while isolated: BLITTER_PROFILE keeps nothing); the
        // first one's workspace makes what all share and reads the settings.
        windows.store = AppEnvironment.isProfile ? nil : StateStore()
        let saved = windows.store?.load() ?? []
        windows.restore(saved, first: Workspace(restoring: saved.first?.state, settingsFile: UserPaths.settingsFile))
        NSApp.mainMenu = makeMainMenu() // after the windows: the menus are the front one's
        observeVolumes()
        startAutomation()
        NSApp.activate()
    }

    /// Serves the automation socket; requests go to the front window's workspace on the main
    /// actor (#96). A second Blitter leaves the socket to the first one and says so.
    private func startAutomation() {
        // Nothing kept: each request takes the window in front then (#96 review).
        let server = LineSocketServer(path: UserPaths.automationSocket) { [weak self] line, client in
            guard let target = await self?.workspace else {
                return nil
            }
            return await target.handleAutomation(line, client: "\(client.name) (pid \(client.pid))")
        }
        automationServer = server // stopped at quit, started or not
        Task.detached { // starting touches the disk: off the main thread (#58 review)
            do {
                try server.start()
            } catch {
                let text = "Automation is off: \(Self.describe(error))"
                await MainActor.run { [weak self] in self?.workspace.perform(.showNotice(text)) }
            }
        }
    }

    private nonisolated static func describe(_ error: Error) -> String {
        switch error as? LineSocketServer.Failure {
        case .inUse?: "another Blitter already serves the automation socket."
        case .notASocket?: "something that is not a socket is in its place (\(UserPaths.automationSocket))."
        case .unsafeFolder?: "its folder is not a private folder of yours."
        case let .system(call, code)?: "\(call) failed (\(String(cString: strerror(code))))."
        case nil: error.localizedDescription
        }
    }

    /// A terminal may have changed the command-line tool's link meanwhile (#97).
    func applicationDidBecomeActive(_: Notification) {
        refreshCommandLineTool()
    }

    func applicationWillTerminate(_: Notification) {
        automationServer?.stop()
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
                    for controller in self?.windows.controllers ?? [] { // every window's tree (#96)
                        controller.workspace.perform(.refreshTreeRoots)
                    }
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

    /// Opens the active side's recent folders (#90); picking one is the navigation.
    @objc private func showRecentFolders(_: Any?) {
        windowController?.fileList(of: workspace.activeSide)?.showRecentFolders()
    }

    @objc func openSettings(_: Any?) {
        SettingsWindowController.show(workspace)
    }

    /// A menu item whose `representedObject` is an action id runs that action on the active side.
    @objc func runAction(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String else {
            return
        }
        workspace.perform(.runAction(id, workspace.activeSide))
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
            menuItem.state = workspace.isOn(id) == true ? .on : .off // #88: e.g. Show Hidden Files
            return !isEditingText && workspace.canRun(id, on: workspace.activeSide)
        case #selector(toggleHiddenFiles(_:)):
            menuItem.state = workspace.showsHiddenFiles ? .on : .off
            return true
        case #selector(goBack(_:)):
            return active.canGoBack
        case #selector(goForward(_:)):
            return active.canGoForward
        case #selector(goToParent(_:)):
            return active.canGoToParent
        case #selector(toggleCommandLineTool(_:)):
            menuItem.title = Self.commandLineToolTitle(commandLineToolStatus)
            return true
        default:
            return true
        }
    }

    private func makeMainMenu() -> NSMenu {
        let mainMenu = NSMenu()

        mainMenu.addItem(submenu: makeAppMenu())

        let editMenu = makeEditMenu()
        mainMenu.addItem(submenu: editMenu)

        let fileMenu = NSMenu(title: "File")
        let fileItem = NSMenuItem()
        fileItem.submenu = fileMenu
        mainMenu.insertItem(fileItem, at: 1) // after the app menu, before Edit

        let viewMenu = NSMenu(title: "View")
        addItem(to: viewMenu, title: "Switch Active Side", action: #selector(switchActiveSide(_:)),
                key: "\t", modifiers: [])
        addItem(to: viewMenu, title: "Show Hidden Files", action: #selector(toggleHiddenFiles(_:)),
                key: ".", modifiers: [.command, .shift])
        addItem(to: viewMenu, title: "Refresh", action: #selector(refresh(_:)), key: "r", modifiers: [.command])
        viewMenu.addItem(.separator())
        // The lists' font (#63); Ctrl+mouse wheel over a list or tree does the same.
        addItem(to: viewMenu, title: "Zoom In", action: #selector(zoomIn(_:)), key: "+", modifiers: [.command])
        addItem(to: viewMenu, title: "Zoom Out", action: #selector(zoomOut(_:)), key: "-", modifiers: [.command])
        addItem(to: viewMenu, title: "Actual Size", action: #selector(actualSize(_:)), key: "0", modifiers: [.command])
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
        addItem(to: goMenu, title: "Recent Folders", action: #selector(showRecentFolders(_:)), key: "y",
                modifiers: [.command])
        goMenu.addItem(.separator())
        goMenu.addItem(withTitle: "Favorites", action: nil, keyEquivalent: "").submenu = favoritesMenu
        mainMenu.addItem(submenu: goMenu)

        // Filled from the settings' tools each time it opens, so a changed file shows at once.
        let toolsMenu = NSMenu(title: "Tools")
        toolsMenu.delegate = self
        mainMenu.addItem(submenu: toolsMenu)

        fileMenuItems = fileMenu
        editMenuItems = editMenu
        updateMenuBar()
        return mainMenu
    }

    /// The Edit menu's own items; the settings' action items follow them (`updateMenuBar`).
    /// No target: these go to the first responder, e.g. the path field while it is edited.
    private func makeEditMenu() -> NSMenu {
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
        editMenu.addItem(withTitle: "Select All", action: #selector(NSResponder.selectAll(_:)), keyEquivalent: "a")
        let byPattern = editMenu.addItem(withTitle: "Select by Pattern…",
                                         action: #selector(MainWindowController.showSelectByPattern(_:)),
                                         keyEquivalent: "a")
        byPattern.keyEquivalentModifierMask = [.command, .option]
        editMenu.addItem(.separator())
        // The main window's controller answers it (#48): it is in the window's responder chain.
        editMenu.addItem(withTitle: "Find…", action: #selector(MainWindowController.showFind(_:)), keyEquivalent: "f")
        return editMenu
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
    func addActionItem(to menu: NSMenu, _ id: String, key: String, modifiers: NSEvent.ModifierFlags) {
        guard let action = workspace.actionRegistry.action(id) else {
            return
        }
        addItem(to: menu, title: action.title, action: #selector(runAction(_:)), key: key, modifiers: modifiers)
        menu.items.last?.representedObject = id
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
