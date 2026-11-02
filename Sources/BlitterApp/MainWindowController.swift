import AppKit
import BlitterModel

/// The main window: the two sides next to each other, below them the Find panel (#48) while it
/// is shown, and the strip of running file operations, which takes no space while there are none.
@MainActor
final class MainWindowController: NSWindowController {
    private let workspace: Workspace
    private let sideControllers: [SideViewController]
    private let jobsController: JobsViewController
    let findController: FindPanelController
    /// The delete request the window has already asked about.
    private var askedDeleteToken: Int?
    /// Light and dark mode take different theme schemes (#21).
    private var appearanceObservation: NSKeyValueObservation?
    /// Runs after every render, e.g. to save the state for the next launch.
    var afterRender: (() -> Void)?

    init(workspace: Workspace) {
        self.workspace = workspace
        sideControllers = Side.allCases.map { SideViewController(workspace: workspace, side: $0) }
        jobsController = JobsViewController(workspace: workspace)
        findController = FindPanelController(workspace: workspace)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1400, height: 800),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable],
                              backing: .buffered,
                              defer: false)
        window.title = "Blitter"
        super.init(window: window)

        let splitViewController = NSSplitViewController()
        splitViewController.splitView.isVertical = true
        splitViewController.splitView.dividerStyle = .thin
        for controller in sideControllers {
            let item = NSSplitViewItem(viewController: controller)
            // Above everything inside a side (tree and list hold at about .defaultLow): a side keeps
            // its width while the splitter between its tree and list moves, so that splitter only
            // trades width between the two. At the same priority, the right side's tree could not
            // be widened, and moving it pushed the splitter between the sides (owner's report,
            // 2026-11-01).
            item.holdingPriority = .defaultLow + 10
            splitViewController.addSplitViewItem(item)
        }
        // Set after the items exist, so the saved divider position applies to them.
        splitViewController.splitView.autosaveName = AppEnvironment.autosaveName("MainSplit")
        let content = makeContent(splitViewController)
        window.contentViewController = content
        window.setContentSize(NSSize(width: 1400, height: 800))
        if let name = AppEnvironment.autosaveName("MainWindow") {
            if !window.setFrameUsingName(name) {
                window.center()
            }
            window.setFrameAutosaveName(name)
        }

        workspace.onChange = { [weak self] in self?.render() }
        appearanceObservation = window.observe(\.effectiveAppearance) { [weak self] _, _ in
            MainActor.assumeIsolated { self?.render() }
        }
        render()
    }

    /// The sides, then the Find panel, then the jobs strip, each spanning the window.
    private func makeContent(_ splitViewController: NSSplitViewController) -> NSViewController {
        let content = NSViewController()
        let stack = NSStackView(views: [splitViewController.view, findController.view, jobsController.view])
        stack.orientation = .vertical
        stack.spacing = 0
        stack.distribution = .fill
        splitViewController.view.setContentHuggingPriority(.defaultLow, for: .vertical)
        // A vertical stack centers its views at their natural width; both span the window.
        for view in [splitViewController.view, findController.view, jobsController.view] {
            view.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        }
        content.view = stack
        content.addChild(splitViewController)
        content.addChild(findController)
        content.addChild(jobsController)
        findController.onVisibilityChange = { [weak self] in
            guard let self, findController.view.isHidden else {
                return
            }
            sideControllers.first { $0.side == workspace.activeSide }?.focusList() // the keys go back
        }
        return content
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    func togglePreview(on side: Side) {
        sideControllers.first { $0.side == side }?.togglePreview()
    }

    /// Find… (⌘F, #48): the Find panel, for the active side.
    @objc func showFind(_: Any?) {
        findController.show()
    }

    func focusPathField(of side: Side) {
        sideControllers.first { $0.side == side }?.focusPathField()
    }

    private func render() {
        for controller in sideControllers {
            controller.render()
        }
        jobsController.render()
        findController.render()
        askToDeleteIfNeeded()
        afterRender?()
    }

    /// Delete Immediately asks in a sheet; the answer goes back as a command.
    private func askToDeleteIfNeeded() {
        guard let request = workspace.deleteRequest, request.token != askedDeleteToken, let window else {
            return
        }
        askedDeleteToken = request.token
        let alert = DeleteConfirmation.alert(for: request)
        alert.beginSheetModal(for: window) { [weak self] response in
            self?.workspace.perform(.answerDelete(token: request.token, delete: response == DeleteConfirmation.delete))
        }
    }
}

/// The question before deleting for good. Cancel is the default button (Return and Escape);
/// deleting takes a click on Delete, or ⇧⌥⌘⌫ to skip the question.
enum DeleteConfirmation {
    static let delete = NSApplication.ModalResponse.alertSecondButtonReturn

    static func alert(for request: DeleteRequest) -> NSAlert {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = message(for: request.paths)
        alert.informativeText = request.paths.count == 1
            ? "It is deleted right away, not moved to the Trash. This cannot be undone."
            : "They are deleted right away, not moved to the Trash. This cannot be undone."
        alert.addButton(withTitle: "Cancel")
        alert.addButton(withTitle: "Delete").hasDestructiveAction = true
        return alert
    }

    static func message(for paths: [String]) -> String {
        if paths.count == 1, let path = paths.first {
            return "Delete “\((path as NSString).lastPathComponent)” immediately?"
        }
        return "Delete \(paths.count) items immediately?"
    }
}
