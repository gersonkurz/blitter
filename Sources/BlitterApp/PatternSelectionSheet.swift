import AppKit
import BlitterModel

/// Select by Pattern…: a sheet asking for name patterns ("*.jpg; *.png"); Select adds the
/// matching items of the active side to its selection, Deselect removes them. The last pattern
/// is offered again.
@MainActor
final class PatternSelectionSheet: NSViewController, NSTextFieldDelegate {
    private let workspace: Workspace
    private let side: Side
    let field = NSTextField()
    /// What was typed last time, for this run of the app.
    static var lastPattern = ""

    init(workspace: Workspace, side: Side) {
        self.workspace = workspace
        self.side = side
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    override func loadView() {
        let label = NSTextField(labelWithString: "Items whose names match (several separated by “;”):")
        field.stringValue = Self.lastPattern
        field.placeholderString = "*.jpg; *.png"
        field.widthAnchor.constraint(equalToConstant: 360).isActive = true
        let cancel = NSButton(title: "Cancel", target: self, action: #selector(cancel(_:)))
        cancel.keyEquivalent = "\u{1b}"
        let deselect = NSButton(title: "Deselect", target: self, action: #selector(deselect(_:)))
        let select = NSButton(title: "Select", target: self, action: #selector(select(_:)))
        select.keyEquivalent = "\r"
        let buttons = NSStackView(views: [cancel, NSView(), deselect, select])
        let stack = NSStackView(views: [label, field, buttons])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 12
        stack.edgeInsets = NSEdgeInsets(top: 20, left: 20, bottom: 20, right: 20)
        buttons.widthAnchor.constraint(equalTo: field.widthAnchor).isActive = true
        view = stack
    }

    @objc func select(_: Any?) {
        finish(.select)
    }

    @objc func deselect(_: Any?) {
        finish(.deselect)
    }

    @objc func cancel(_: Any?) {
        dismiss(nil)
    }

    private func finish(_ mode: PatternSelectionMode) {
        Self.lastPattern = field.stringValue
        workspace.perform(.selectByPattern(side, field.stringValue, mode))
        dismiss(nil)
    }
}
