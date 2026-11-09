import BlitterCore
@testable import BlitterModel
import Foundation
import Testing

/// #69: the automation's `showMenu`, for the manual's pictures of open menus: it asks the app to
/// open the menu and answers at once; bad parameters are refused.
@MainActor
struct ShowMenuTests {
    private func request(_ workspace: Workspace, _ params: String) async -> String {
        await workspace.handleAutomation(#"{"jsonrpc": "2.0", "id": 1, "method": "showMenu", "params": \#(params)}"#,
                                         client: "test") ?? ""
    }

    @Test func itAsksTheAppToOpenTheMenu() async {
        let workspace = Workspace(initialLocation: "/", home: "/", lister: { _ in [] }, volumes: { [] },
                                  watcher: FakeWatcher.factory)
        var shown: [String] = []
        workspace.system.showMenu = { shown.append("\($0) \($1) \($2)") }
        let reply = await request(workspace, #"{"menu": "File", "side": "right", "seconds": 3}"#)
        #expect(reply.contains(#""menu":"File""#) && reply.contains(#""seconds":3"#))
        #expect(shown == ["file right 3.0"])
        _ = await request(workspace, #"{"menu": "context"}"#) // the active side, 5 seconds
        #expect(shown.last == "context \(workspace.activeSide) 5.0")

        for bad in [
            #"{"menu": "Help"}"#,
            #"{}"#,
            #"{"menu": "File", "seconds": 0}"#,
            #"{"menu": "File", "seconds": 31}"#,
        ] {
            #expect(await request(workspace, bad).contains("-32602"), "\(bad)")
        }
        #expect(shown.count == 2) // nothing opened for those
    }
}
