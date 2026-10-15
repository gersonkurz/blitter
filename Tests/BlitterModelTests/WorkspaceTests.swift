import BlitterModel
import Testing

@MainActor
struct WorkspaceTests {
    @Test func oppositeSide() {
        #expect(Side.left.opposite == .right)
        #expect(Side.right.opposite == .left)
    }

    @Test func bothSidesStartAtTheInitialLocationWithLeftActive() {
        let workspace = Workspace(initialLocation: "/tmp")
        #expect(workspace.state(of: .left).location == "/tmp")
        #expect(workspace.state(of: .right).location == "/tmp")
        #expect(workspace.activeSide == .left)
    }

    @Test func switchActiveSideTogglesAndNotifies() {
        let workspace = Workspace(initialLocation: "/tmp")
        var changes = 0
        workspace.onChange = { changes += 1 }

        workspace.perform(.switchActiveSide)
        #expect(workspace.activeSide == .right)
        workspace.perform(.switchActiveSide)
        #expect(workspace.activeSide == .left)
        #expect(changes == 2)
    }
}
