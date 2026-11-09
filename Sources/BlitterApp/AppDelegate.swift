import AppKit
import BlitterCore
import BlitterModel

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuItemValidation, NSMenuDelegate {
    private let stateStore = StateStore()
    /// Starts where the last session ended.
    lazy var workspace = AppEnvironment.isHostedTest ? Workspace()
        : Workspace(restoring: stateStore.load(), settingsFile: UserPaths.settingsFile)
    private(set) var windowController: MainWindowController?
    /// The automation socket (#58), while the app runs.
    private var automationServer: LineSocketServer?
    /// The menus whose action items come from the settings (#24), and what they were built from.
    var fileMenuItems: NSMenu?
    var editMenuItems: NSMenu?
    var renderedMenuBar: MenuBarSettings?
    var renderedTools: [Tool]?

    func applicationDidFinishLaunching(_: Notification) {
        NSApp.mainMenu = makeMainMenu()
        // Hosting the app tests: the menu is all they need. No window, nothing saved, so a test
        // run never touches the user's workspace or layout.
        guard !AppEnvironment.isHostedTest else {
            return
        }
        let controller = MainWindowController(workspace: workspace)
        workspace.system = .appKit(window: controller)
        DialogHost.register(DialogRequest.gitLog) { [workspace] request in
            GitLogWindowController(workspace: workspace, path: request.path)
        }
        DialogHost.register(DialogRequest.gitSync) { [workspace] request in
            GitSyncWindowController(workspace: workspace, path: request.path)
        }
        DialogHost.register(DialogRequest.gitCommit) { [workspace] request in
            GitCommitWindowController(workspace: workspace, path: request.path)
        }
        DialogHost.register(DialogRequest.gitClone) { [workspace] request in
            GitCloneWindowController(workspace: workspace, folder: request.path)
        }
        controller.afterRender = { [weak self] in
            guard let self else {
                return
            }
            stateStore.save(workspace.savedState)
            updateMenuBar() // the settings file may have changed the menus
            SettingsWindowController.current?.model.workspaceChanged()
        }
        controller.showWindow(nil)
        windowController = controller
        observeVolumes()
        startAutomation()
        NSApp.activate()
    }

    /// Serves the automation socket; requests go to the workspace on the main actor. A second
    /// Blitter leaves the socket to the first one and says so.
    private func startAutomation() {
        let workspace = workspace
        let server = LineSocketServer(path: UserPaths.automationSocket) { line, client in
            await workspace.handleAutomation(line, client: "\(client.name) (pid \(client.pid))")
        }
        automationServer = server // stopped at quit, started or not
        Task.detached { // starting touches the disk: off the main thread (#58 review)
            do {
                try server.start()
            } catch {
                let text = "Automation is off: \(Self.describe(error))"
                await MainActor.run { workspace.perform(.showNotice(text)) }
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

    @objc private func openSettings(_: Any?) {
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
