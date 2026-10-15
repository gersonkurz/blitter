import AppKit
import BlitterModel

/// The main window: the two sides next to each other.
@MainActor
final class MainWindowController: NSWindowController {
    private let workspace: Workspace
    private let sideControllers: [FileListViewController]

    init(workspace: Workspace) {
        self.workspace = workspace
        sideControllers = Side.allCases.map { FileListViewController(workspace: workspace, side: $0) }
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1400, height: 800),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable],
                              backing: .buffered,
                              defer: false)
        window.title = "Blitter"
        super.init(window: window)

        let splitViewController = NSSplitViewController()
        splitViewController.splitView.isVertical = true
        splitViewController.splitView.dividerStyle = .thin
        splitViewController.splitView.autosaveName = "MainSplit"
        for controller in sideControllers {
            splitViewController.addSplitViewItem(NSSplitViewItem(viewController: controller))
        }
        window.contentViewController = splitViewController
        window.setContentSize(NSSize(width: 1400, height: 800))
        if !window.setFrameUsingName("MainWindow") {
            window.center()
        }
        window.setFrameAutosaveName("MainWindow")

        workspace.onChange = { [weak self] in self?.render() }
        render()
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    private func render() {
        for controller in sideControllers {
            controller.render()
        }
    }
}
