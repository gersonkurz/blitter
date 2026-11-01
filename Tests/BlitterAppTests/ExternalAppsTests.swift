import AppKit
@testable import Blitter
@testable import BlitterModel
import Testing

/// Finding the app of an external tool (#18), and the Tools menu.
@MainActor
struct ExternalAppsTests {
    @Test func appsAreFoundByNameBundleIdentifierOrPath() throws {
        let home = NSHomeDirectory()
        let byName = try #require(ExternalApps.resolve("TextEdit", home: home))
        #expect(byName.path == "/System/Applications/TextEdit.app")
        #expect(ExternalApps.resolve("TextEdit.app", home: home) == byName)
        let byIdentifier = try #require(ExternalApps.resolve("com.apple.TextEdit", home: home))
        #expect(byIdentifier.lastPathComponent == "TextEdit.app")
        #expect(ExternalApps.resolve("/System/Applications/TextEdit.app", home: home)?.path == byName.path)
        #expect(ExternalApps.resolve("Terminal", home: home)?.path == "/System/Applications/Utilities/Terminal.app")
    }

    @Test func aMissingAppIsNotFound() {
        let home = NSTemporaryDirectory() + "no-home-" + UUID().uuidString
        #expect(ExternalApps.resolve("No Such App 7f3c", home: home) == nil)
        #expect(ExternalApps.resolve("com.example.no-such-app-7f3c", home: home) == nil)
        #expect(ExternalApps.resolve("~/Applications/Nothing.app", home: home) == nil)
        #expect(ExternalApps.resolve("/nowhere/Nothing.app", home: home) == nil)
    }

    /// The real launch path with an app that does not exist: nothing opens, the failure
    /// arrives on the main actor.
    @Test func aMissingAppIsReportedOnTheMainActor() async throws {
        var messages: [String] = []
        var onMain: [Bool] = []
        ExternalApps.open([NSTemporaryDirectory()], with: "No Such App 7f3c") { message in
            onMain.append(Thread.isMainThread)
            messages.append(message)
        }
        for _ in 0 ..< 300 where messages.isEmpty {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(messages == ["the app “No Such App 7f3c” was not found."])
        #expect(onMain == [true])
    }

    @Test func theToolsMenuListsTheSettingsTools() throws {
        let tools = try #require(NSApp.mainMenu?.items.compactMap(\.submenu).first { $0.title == "Tools" })
        let delegate = try #require(NSApp.delegate as? AppDelegate)
        delegate.menuNeedsUpdate(tools)
        #expect(tools.items.map(\.title) == ["Open in Terminal", "Open in Code", "Open in Text Editor"])
        #expect(tools.items.compactMap { $0.representedObject as? String }
            == ["open-in-terminal", "open-in-code", "open-in-text-editor"])
        delegate.menuNeedsUpdate(tools) // opened again: rebuilt, not doubled
        #expect(tools.items.count == 3)
    }
}
