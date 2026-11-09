import AppKit
@testable import Blitter
@testable import BlitterModel
import Testing

/// The Git Clone window (#70): the folder name follows the address until it is typed, and Clone
/// is offered only for what can be cloned.
@MainActor
struct GitCloneWindowTests {
    private func type(_ text: String, into field: NSTextField, of controller: GitCloneWindowController) {
        field.stringValue = text
        controller.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: field))
    }

    @Test func theNameFollowsTheAddressUntilItIsTyped() async throws {
        let workspace = Workspace(initialLocation: "/", home: "/", lister: { _ in [] }, volumes: { [] },
                                  watcher: FakeWatcher.factory)
        let controller = GitCloneWindowController(workspace: workspace, folder: "/projects",
                                                  findGit: { "/usr/bin/true" })
        defer { controller.close() }
        for _ in 0 ..< 300 where !controller.clone.isReady { // git is looked for off the main thread
            try await Task.sleep(for: .milliseconds(10))
        }
        try #require(controller.clone.isReady)
        #expect(!controller.cloneButton.isEnabled && controller.statusLabel.stringValue.isEmpty)

        type("git@github.com:me/blitter.git", into: controller.addressField, of: controller)
        #expect(controller.nameField.stringValue == "blitter" && controller.cloneButton.isEnabled)

        type("mine", into: controller.nameField, of: controller)
        type("https://github.com/me/other.git", into: controller.addressField, of: controller)
        #expect(controller.nameField.stringValue == "mine") // typed: the address leaves it alone

        type("a/b", into: controller.nameField, of: controller)
        #expect(!controller.cloneButton.isEnabled && controller.statusLabel.stringValue.contains("not a folder name"))
    }
}
