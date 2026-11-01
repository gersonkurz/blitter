import AppKit
import BlitterModel

/// Back, Up and Forward for one side, left of its path field, as in Directory Opus. Each button
/// sends the same command as the Go menu and is enabled under the same rules.
@MainActor
final class NavigationButtons: NSStackView {
    let back = NSButton()
    let upward = NSButton()
    let forward = NSButton()
    /// Called with the command a button stands for.
    var onCommand: ((Command) -> Void)?
    private let side: Side

    init(side: Side) {
        self.side = side
        super.init(frame: .zero)
        orientation = .horizontal
        spacing = 2
        configure(back, symbol: "chevron.left", tip: "Back", action: #selector(goBack(_:)))
        configure(upward, symbol: "arrow.up", tip: "Enclosing Folder", action: #selector(goUp(_:)))
        configure(forward, symbol: "chevron.right", tip: "Forward", action: #selector(goForward(_:)))
        for button in [back, upward, forward] {
            addArrangedSubview(button)
        }
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    func render(_ state: SideState) {
        back.isEnabled = state.canGoBack
        upward.isEnabled = state.canGoToParent
        forward.isEnabled = state.canGoForward
    }

    private func configure(_ button: NSButton, symbol: String, tip: String, action: Selector) {
        button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: tip)
        button.toolTip = tip
        button.bezelStyle = .accessoryBarAction
        button.isBordered = true
        button.controlSize = .small
        button.target = self
        button.action = action
    }

    @objc private func goBack(_: Any?) {
        send(.goBack(side))
    }

    @objc private func goUp(_: Any?) {
        send(.goToParent(side))
    }

    @objc private func goForward(_: Any?) {
        send(.goForward(side))
    }

    /// A click also makes this side the active one, as clicking anywhere else in it does.
    private func send(_ command: Command) {
        onCommand?(.activate(side))
        onCommand?(command)
    }
}
