import AppKit
import BlitterModel

/// The main window: the two sides next to each other, and below them the strip of running file
/// operations, which takes no space while there are none.
@MainActor
final class MainWindowController: NSWindowController {
    private let workspace: Workspace
    private let sideControllers: [SideViewController]
    private let jobsController: JobsViewController

    init(workspace: Workspace) {
        self.workspace = workspace
        sideControllers = Side.allCases.map { SideViewController(workspace: workspace, side: $0) }
        jobsController = JobsViewController(workspace: workspace)
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
        let content = NSViewController()
        let stack = NSStackView(views: [splitViewController.view, jobsController.view])
        stack.orientation = .vertical
        stack.spacing = 0
        stack.distribution = .fill
        splitViewController.view.setContentHuggingPriority(.defaultLow, for: .vertical)
        // A vertical stack centers its views at their natural width; both span the window.
        for view in [splitViewController.view, jobsController.view] {
            view.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        }
        content.view = stack
        content.addChild(splitViewController)
        content.addChild(jobsController)
        window.contentViewController = content
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

    func focusPathField(of side: Side) {
        sideControllers.first { $0.side == side }?.focusPathField()
    }

    private func render() {
        for controller in sideControllers {
            controller.render()
        }
        jobsController.render()
    }
}
