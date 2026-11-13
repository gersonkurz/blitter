import AppKit
import BlitterModel

/// The main window's toolbar (#88): a button per action of `[toolbar] items`, each running its
/// action on the active side. Built anew when the items or the tools change; on every render
/// each button is enabled exactly when its action fits the active side, and a button for
/// something that is on or off (Show Hidden Files) shows which. A button that does not fit the
/// window goes into the toolbar's overflow menu as a menu item that does the same (#88 review).
@MainActor
final class WindowToolbar: NSObject, NSToolbarDelegate, NSMenuItemValidation {
    private let workspace: Workspace
    private weak var window: NSWindow?
    /// What the toolbar was built from.
    private var builtItems: [ToolbarEntry]?
    private var builtTools: [Tool]?
    /// The toolbar's items in order: gaps (`.space`) and buttons.
    private var identifiers: [NSToolbarItem.Identifier] = []
    /// Each button, by its item's identifier, with the action it runs.
    private(set) var buttons: [NSToolbarItem.Identifier: (id: String, button: NSButton)] = [:]

    /// When a symbol name is none (a typo in the settings file).
    static let unknownSymbol = "questionmark.square.dashed"

    init(workspace: Workspace, window: NSWindow) {
        self.workspace = workspace
        self.window = window
        super.init()
    }

    func render() {
        let items = workspace.settings.toolbar
        let tools = workspace.settings.tools
        if items != builtItems || tools != builtTools {
            build(items)
            builtItems = items
            builtTools = tools
        }
        for (id, button) in buttons.values {
            let state = workspace.toolbarButton(id)
            button.isEnabled = state.isEnabled
            if let isOn = state.isOn {
                button.state = isOn ? .on : .off
            }
        }
    }

    private func build(_ items: [ToolbarEntry]) {
        buttons = [:]
        identifiers = []
        guard let window, !items.isEmpty else {
            window?.toolbar = nil
            return
        }
        for (index, item) in items.enumerated() {
            switch item {
            case .gap:
                identifiers.append(.space)
            case let .action(id, icon):
                guard let action = workspace.actionRegistry.action(id) else {
                    continue
                }
                let identifier = NSToolbarItem.Identifier("\(index).\(id)")
                identifiers.append(identifier)
                buttons[identifier] = (id, makeButton(action, symbol: icon ?? action.symbol))
            }
        }
        // A new toolbar each time: its items are fixed once it asked its delegate for them. The
        // layout is the settings file's, so nothing is saved and nothing can be customized.
        let toolbar = NSToolbar(identifier: "Blitter")
        toolbar.delegate = self
        toolbar.displayMode = .iconOnly
        toolbar.allowsUserCustomization = false
        toolbar.autosavesConfiguration = false
        window.toolbar = toolbar
    }

    private func makeButton(_ action: Action, symbol: String) -> NSButton {
        let image = NSImage(systemSymbolName: symbol, accessibilityDescription: action.title)
            ?? NSImage(systemSymbolName: Self.unknownSymbol, accessibilityDescription: action.title)
            ?? NSImage()
        let button = NSButton(image: image, target: self, action: #selector(runButton(_:)))
        button.bezelStyle = .toolbar
        button.setButtonType(workspace.isOn(action.id) == nil ? .momentaryPushIn : .pushOnPushOff)
        button.toolTip = action.title
        button.setAccessibilityLabel(action.title)
        return button
    }

    @objc private func runButton(_ sender: NSButton) {
        if let id = buttons.values.first(where: { $0.button === sender })?.id {
            run(id)
        }
    }

    /// The overflow menu's item for a button: its action id is the item's `representedObject`.
    @objc func runMenuItem(_ sender: NSMenuItem) {
        if let id = sender.representedObject as? String {
            run(id)
        }
    }

    private func run(_ id: String) {
        workspace.perform(.runAction(id, workspace.activeSide))
        render() // a toggle flips itself on click; the workspace says what it really is
    }

    /// The overflow menu's items, as their buttons are: enabled when the action fits the active
    /// side, checked while what it turns on is on.
    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        guard menuItem.action == #selector(runMenuItem(_:)), let id = menuItem.representedObject as? String else {
            return false
        }
        let state = workspace.toolbarButton(id)
        menuItem.state = state.isOn == true ? .on : .off
        return state.isEnabled
    }

    // MARK: NSToolbarDelegate

    func toolbarDefaultItemIdentifiers(_: NSToolbar) -> [NSToolbarItem.Identifier] {
        identifiers
    }

    func toolbarAllowedItemIdentifiers(_: NSToolbar) -> [NSToolbarItem.Identifier] {
        identifiers
    }

    func toolbar(_: NSToolbar, itemForItemIdentifier identifier: NSToolbarItem.Identifier,
                 willBeInsertedIntoToolbar _: Bool) -> NSToolbarItem?
    {
        guard let (id, button) = buttons[identifier] else {
            return nil // a gap is the toolbar's own
        }
        let item = NSToolbarItem(itemIdentifier: identifier)
        item.view = button
        item.label = workspace.actionRegistry.action(id)?.title ?? id
        item.toolTip = item.label
        let menuItem = NSMenuItem(title: item.label, action: #selector(runMenuItem(_:)), keyEquivalent: "")
        menuItem.target = self
        menuItem.representedObject = id
        menuItem.image = button.image
        item.menuFormRepresentation = menuItem
        return item
    }
}
