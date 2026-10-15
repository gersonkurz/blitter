import AppKit
import BlitterModel

/// The main window: two sides next to each other. For now each side is a placeholder that shows
/// its location and whether it is the active side.
@MainActor
final class MainWindowController: NSWindowController {
    private let workspace: Workspace
    private let leftLabel = NSTextField(labelWithString: "")
    private let rightLabel = NSTextField(labelWithString: "")

    init(workspace: Workspace) {
        self.workspace = workspace
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1400, height: 800),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable],
                              backing: .buffered,
                              defer: false)
        window.title = "Blitter"
        window.setFrameAutosaveName("MainWindow")
        super.init(window: window)

        let splitView = NSSplitView()
        splitView.isVertical = true
        splitView.dividerStyle = .thin
        splitView.addArrangedSubview(Self.container(for: leftLabel))
        splitView.addArrangedSubview(Self.container(for: rightLabel))
        window.contentView = splitView
        if window.frame.origin == .zero {
            window.center()
        }

        workspace.onChange = { [weak self] in self?.render() }
        render()
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    private func render() {
        for side in Side.allCases {
            let label = side == .left ? leftLabel : rightLabel
            let isActive = workspace.activeSide == side
            label.stringValue = (isActive ? "▶ " : "") + workspace.state(of: side).location
            label.textColor = isActive ? .labelColor : .secondaryLabelColor
        }
    }

    private static func container(for label: NSTextField) -> NSView {
        let container = NSView()
        label.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(label)
        NSLayoutConstraint.activate([
            label.centerXAnchor.constraint(equalTo: container.centerXAnchor),
            label.centerYAnchor.constraint(equalTo: container.centerYAnchor),
            container.widthAnchor.constraint(greaterThanOrEqualToConstant: 300),
        ])
        return container
    }
}
