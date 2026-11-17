import AppKit
@testable import Blitter
import Testing

@MainActor
struct SelectDifferencesMenuTests {
    /// #108: Edit → Select Differences (⇧⌥⌘A) runs the action.
    @Test func theEditMenuHasSelectDifferences() throws {
        let menu = try #require(NSApp.mainMenu?.items.first { $0.submenu?.title == "Edit" }?.submenu)
        let item = try #require(menu.items.first { $0.title == "Select Differences" })
        #expect(item.keyEquivalent == "a" && item.keyEquivalentModifierMask == [.command, .option, .shift])
        #expect(item.representedObject as? String == "select-differences" && item.target is AppDelegate)
    }
}
