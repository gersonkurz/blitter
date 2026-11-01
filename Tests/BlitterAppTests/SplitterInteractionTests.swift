import AppKit
@testable import Blitter
@testable import BlitterModel
import Testing

/// The three splitters of the window (#38): 1 between the left tree and list, 2 between the
/// sides, 3 between the right tree and list. Each is dragged through AppKit's own mouse tracking.
@MainActor
@Suite(.serialized)
struct SplitterInteractionTests {
    @Test func eachSplitterMovesOnlyItsOwnPanes() throws {
        let workspace = Workspace(initialLocation: "/", home: NSHomeDirectory(), lister: { _ in [] },
                                  directoryCheck: { _ in false }, volumes: { [] }, watcher: FakeWatcher.factory)
        let controller = MainWindowController(workspace: workspace)
        let window = try #require(controller.window)
        controller.showWindow(nil)
        defer { window.close() }
        window.setContentSize(NSSize(width: 1400, height: 800))
        window.layoutIfNeeded()
        let outer = try #require(window.contentView?.firstSplitView)
        let left = try #require(outer.arrangedSubviews[0].firstSplitView)
        let right = try #require(outer.arrangedSubviews[1].firstSplitView)
        func widths(_ split: NSSplitView) -> [Int] {
            window.layoutIfNeeded()
            return split.arrangedSubviews.map { Int($0.frame.width.rounded()) }
        }
        let sides = widths(outer)
        let tree = widths(right)[0]

        try drag(right, by: 100, in: window) // splitter 3: the right tree, which could not be widened
        #expect(widths(right)[0] == tree + 100)
        #expect(widths(outer) == sides)

        try drag(left, by: 100, in: window) // splitter 1
        #expect(widths(left)[0] == tree + 100)
        #expect(widths(outer) == sides)

        try drag(outer, by: -100, in: window) // splitter 2: the lists take it, the trees keep theirs
        #expect(widths(outer)[0] == sides[0] - 100)
        #expect(widths(left)[0] == tree + 100 && widths(right)[0] == tree + 100)
    }

    /// Queues the drag and the release, then presses on the first divider: the split view's
    /// tracking loop takes the queued events, as it would take the user's.
    private func drag(_ split: NSSplitView, by delta: CGFloat, in window: NSWindow) throws {
        let first = split.arrangedSubviews[0].frame
        let start = split.convert(NSPoint(x: first.maxX + split.dividerThickness / 2, y: first.midY), to: nil)
        func event(_ type: NSEvent.EventType, at position: CGFloat) throws -> NSEvent {
            try #require(NSEvent.mouseEvent(
                with: type, location: NSPoint(x: position, y: start.y), modifierFlags: [],
                timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                context: nil, eventNumber: 0, clickCount: 1, pressure: 1
            ))
        }
        for step in 1 ... 5 {
            try NSApp.postEvent(event(.leftMouseDragged, at: start.x + delta * CGFloat(step) / 5), atStart: false)
        }
        try NSApp.postEvent(event(.leftMouseUp, at: start.x + delta), atStart: false)
        try split.mouseDown(with: event(.leftMouseDown, at: start.x))
    }
}

private extension NSView {
    /// This view if it is a split view, else the first split view inside it.
    var firstSplitView: NSSplitView? {
        (self as? NSSplitView) ?? subviews.lazy.compactMap(\.firstSplitView).first
    }
}
