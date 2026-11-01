import AppKit
import BlitterModel

/// The menu bar's action items (#24): the File menu, and the Edit menu after its own items, are
/// built from the settings and rebuilt when they change.
extension AppDelegate {
    /// Marks the Edit menu's items that come from the settings, so a rebuild replaces only them.
    private static let fromSettings = 24

    /// Rebuilds when the menus or the tools change: an item's title can come from a tool.
    func updateMenuBar() {
        let menus = workspace.settings.menuBar
        let tools = workspace.settings.tools
        guard menus != renderedMenuBar || tools != renderedTools, let fileMenu = fileMenuItems,
              let editMenu = editMenuItems
        else {
            return
        }
        renderedMenuBar = menus
        renderedTools = tools
        fileMenu.removeAllItems()
        add(menus.file, to: fileMenu)
        for item in editMenu.items where item.tag == Self.fromSettings {
            editMenu.removeItem(item)
        }
        if !menus.edit.isEmpty {
            editMenu.addItem(.separator())
            editMenu.items.last?.tag = Self.fromSettings
            add(menus.edit, to: editMenu)
        }
    }

    private func add(_ items: [MenuBarItem], to menu: NSMenu) {
        for item in items {
            switch item {
            case .separator:
                menu.addItem(.separator())
            case let .action(id, shortcut, alternate):
                let key = shortcut.map(Self.keyEquivalent) ?? ""
                addActionItem(to: menu, id, key: key, modifiers: shortcut.map(Self.modifiers) ?? [])
                menu.items.last?.isAlternate = alternate
            }
            menu.items.last?.tag = Self.fromSettings
        }
    }

    static func keyEquivalent(_ shortcut: Shortcut) -> String {
        func function(_ key: Int) -> String {
            UnicodeScalar(UInt32(key)).map { String(Character($0)) } ?? ""
        }
        return switch shortcut.key {
        case let .character(character): String(character)
        case let .function(number): function(NSF1FunctionKey + number - 1)
        case .backspace: "\u{8}"
        case .forwardDelete: function(NSDeleteFunctionKey)
        case .returnKey: "\r"
        case .tab: "\t"
        case .space: " "
        case .escape: "\u{1b}"
        case .upArrow: function(NSUpArrowFunctionKey)
        case .downArrow: function(NSDownArrowFunctionKey)
        case .leftArrow: function(NSLeftArrowFunctionKey)
        case .rightArrow: function(NSRightArrowFunctionKey)
        case .home: function(NSHomeFunctionKey)
        case .end: function(NSEndFunctionKey)
        case .pageUp: function(NSPageUpFunctionKey)
        case .pageDown: function(NSPageDownFunctionKey)
        }
    }

    static func modifiers(_ shortcut: Shortcut) -> NSEvent.ModifierFlags {
        var flags: NSEvent.ModifierFlags = []
        for modifier in shortcut.modifiers {
            switch modifier {
            case .command: flags.insert(.command)
            case .shift: flags.insert(.shift)
            case .option: flags.insert(.option)
            case .control: flags.insert(.control)
            }
        }
        return flags
    }
}
