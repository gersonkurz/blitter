import AppKit
@testable import Blitter
import BlitterCore
@testable import BlitterModel
import Testing

/// #96: several main windows, each with a workspace of its own sharing one AppModel: which one is
/// in front, what is saved, a new one placed off the front one, a closed one let go.
@MainActor
@Suite(.serialized)
final class MainWindowsTests {
    private let windows = MainWindows()
    private let first: Workspace

    init() {
        first = Workspace(initialLocation: "/", home: "/home", lister: { _ in [] }, directoryCheck: { _ in false },
                          volumes: { [] }, watcher: FakeWatcher.factory)
    }

    isolated deinit {
        windows.isQuitting = true // closing them here is not the user closing them
        for controller in windows.controllers {
            controller.close()
        }
    }

    @Test func aNewWindowSharesTheAppAndOpensOffTheFrontOne() throws {
        var configured = 0
        windows.configure = { _ in configured += 1 }
        let one = windows.open(first)
        let window = try #require(one.window)
        window.setFrame(NSRect(x: 120, y: 140, width: 900, height: 600), display: false)
        let place = window.frameDescriptor
        #expect(windows.front === one)

        one.openWindow?("/tmp") // File → New Window, through the window's system services
        let two = try #require(windows.controllers.last)
        #expect(windows.controllers.count == 2 && configured == 2)
        #expect(two.workspace !== first && two.workspace.app === first.app)
        #expect(two.workspace.state(of: .left).location == "/tmp" && two.workspace.state(of: .right).location == "/tmp")
        let (frontFrame, newFrame) = try (#require(one.window).frame, #require(two.window).frame)
        #expect(newFrame.size == frontFrame.size && newFrame.minX > frontFrame.minX && newFrame.maxY < frontFrame
            .maxY) // its size, below and right of it
        let again = windows.open(Workspace(sharingWith: first, location: "/"), frame: place) // as saved
        #expect(try #require(again.window).frame == NSRect(x: 120, y: 140, width: 900, height: 600))
        #expect(windows.saved.map(\.state.left.location) == ["/", "/tmp", "/"])
        #expect(windows.saved.allSatisfy { $0.frame != nil })
    }

    @Test func theFrontWindowIsTheOneMainLast() {
        let one = windows.open(first)
        let two = windows.open(Workspace(sharingWith: first, location: "/tmp"))
        NotificationCenter.default.post(name: NSWindow.didBecomeMainNotification, object: two.window)
        #expect(windows.front === two)
        NotificationCenter.default.post(name: NSWindow.didBecomeMainNotification, object: one.window)
        #expect(windows.front === one)
    }

    @Test func aClosedWindowGoesWithItsWorkspaceButNotTheLastOne() async throws {
        let one = windows.open(first)
        weak var closedWorkspace: Workspace?
        try autoreleasepool {
            let two = windows.open(Workspace(sharingWith: first, location: "/tmp"))
            closedWorkspace = two.workspace
            NotificationCenter.default.post(name: NSWindow.didBecomeMainNotification, object: two.window)
            try #require(two.window).close()
        }
        #expect(windows.controllers.count == 1 && windows.front === one) // the other one acts again
        for _ in 0 ..< 100 where closedWorkspace != nil {
            try await Task.sleep(for: .milliseconds(10)) // AppKit lets a closed window go a moment later
        }
        #expect(closedWorkspace == nil && first.app.workspaces.count == 1) // let go
        try #require(one.window).close() // the last one: stays saved, Blitter quits
        #expect(windows.controllers.count == 1)
    }

    @Test func windowsClosingWhileQuittingStaySaved() throws {
        windows.open(first)
        let two = windows.open(Workspace(sharingWith: first, location: "/tmp"))
        windows.isQuitting = true
        try #require(two.window).close()
        #expect(windows.saved.count == 2)
    }
}

/// #96 review: a whole session through the windows and a real store in a defaults domain of its
/// own — restored, changed, closed, saved, and launched again; also from the single window of
/// before #96. The session being restored is never written over half-way.
@MainActor
@Suite(.serialized)
final class MainWindowsSessionTests {
    private let suite = "Blitter.tests." + UUID().uuidString
    private let defaults: UserDefaults
    private var sessions: [MainWindows] = []

    init() throws {
        defaults = try #require(UserDefaults(suiteName: suite))
    }

    isolated deinit {
        for windows in sessions {
            windows.isQuitting = true
            for controller in windows.controllers {
                controller.close()
            }
        }
        defaults.removePersistentDomain(forName: suite)
    }

    /// A launch: the store's windows, the first one's workspace making the app (as AppDelegate).
    private func launch() -> MainWindows {
        let windows = MainWindows()
        windows.store = StateStore(defaults: defaults)
        let saved = windows.store?.load() ?? []
        let first = Workspace(initialLocation: "/", home: "/home", lister: { _ in [] },
                              directoryCheck: { _ in false }, volumes: { [] }, watcher: FakeWatcher.factory,
                              restoring: saved.first?.state)
        windows.restore(saved, first: first)
        sessions.append(windows)
        return windows
    }

    private func state(_ left: String, _ right: String) -> WorkspaceState {
        WorkspaceState(left: .init(location: left, sort: ListSort()), right: .init(location: right, sort: ListSort()),
                       showsHiddenFiles: false)
    }

    private func frame(_ left: Int) -> String {
        // A main window's size (narrower than its sides need, AppKit would widen it), clear of the
        // Dock (a window shown there is moved up out of it).
        NSWindow(
            contentRect: NSRect(x: left, y: 300, width: 1200, height: 700),
            styleMask: [.titled],
            backing: .buffered,
            defer: true
        ).frameDescriptor
    }

    private func written() throws -> [SavedWindow] {
        try JSONDecoder().decode([SavedWindow].self, from: #require(defaults.data(forKey: "Windows")))
    }

    @Test func aSessionIsRestoredChangedAndRestoredAgain() throws {
        let session = [SavedWindow(state: state("/a", "/b"), frame: frame(100)),
                       SavedWindow(state: state("/c", "/d"), frame: frame(300))]
        try defaults.set(JSONEncoder().encode(session), forKey: "Windows")

        let first = launch()
        #expect(first.controllers.map { $0.workspace.state(of: .left).location } == ["/a", "/c"])
        #expect(first.controllers.map { $0.workspace.state(of: .right).location } == ["/b", "/d"])
        #expect(first.controllers.map { $0.window?.frameDescriptor } == session.map(\.frame))
        #expect(first.controllers[1].workspace.app === first.controllers[0].workspace.app)
        #expect(try written().map(\.state) == session.map(\.state)) // never just the first window

        // A new window, the first (startup) window closed, the other moved.
        first.controllers[0].openWindow?("/e")
        try #require(first.controllers[0].window).close()
        try #require(first.controllers[0].window).setFrame(NSRect(x: 500, y: 300, width: 1200, height: 700),
                                                           display: false)
        first.save() // as after its render or move
        let expected = first.saved
        #expect(expected.map(\.state.left.location) == ["/c", "/e"])
        #expect(try written() == expected)

        let second = launch() // the next launch
        #expect(second.saved == expected)
    }

    @Test func theSingleWindowOfBeforeIsRestoredAndSavedAsAWindow() throws {
        try defaults.set(JSONEncoder().encode(state("/old", "/older")), forKey: "WorkspaceState")
        let windows = launch()
        #expect(windows.controllers.count == 1)
        #expect(windows.controllers[0].workspace.state(of: .left).location == "/old")
        #expect(try written().map(\.state) == [state("/old", "/older")])
    }

    /// Closing either of the windows a launch restored lets its workspace go: nothing else
    /// holds them (#96 review).
    @Test func closedStartupWindowsLetTheirWorkspacesGo() async throws {
        try defaults.set(JSONEncoder().encode([SavedWindow(state: state("/a", "/b"), frame: nil),
                                               SavedWindow(state: state("/c", "/d"), frame: nil)]),
                         forKey: "Windows")
        let windows = launch()
        let app = try #require(windows.controllers.first?.workspace.app)
        weak var firstWorkspace: Workspace?
        weak var secondWorkspace: Workspace?
        try autoreleasepool {
            firstWorkspace = windows.controllers[0].workspace
            secondWorkspace = windows.controllers[1].workspace
            windows.controllers[1].openWindow?("/e") // a third, so both startup windows can close
            try #require(windows.controllers[0].window).close()
            try #require(windows.controllers[0].window).close()
        }
        for _ in 0 ..< 100 where firstWorkspace != nil || secondWorkspace != nil {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(firstWorkspace == nil && secondWorkspace == nil)
        #expect(app.workspaces.count == 1 && windows.controllers.count == 1)
    }
}
