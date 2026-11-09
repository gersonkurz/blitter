import AppKit
import BlitterModel

/// The recent folders strip below a file list (#74): one button per folder, pinned ones first
/// (with a pin), then the others by frecency; what does not fit is left out, the least frecent
/// first. A click goes there; a right-click pins, unpins or forgets the folder.
@MainActor
final class RecentFoldersBar: NSView {
    /// Called with the command a button or its menu stands for.
    var onCommand: ((Command) -> Void)?
    private let side: Side
    private let stack = NSStackView()
    private var rendered: (folders: [String], pinned: [String])?
    /// No height while there is nothing to show.
    private lazy var height = heightAnchor.constraint(equalToConstant: 0)

    init(side: Side) {
        self.side = side
        super.init(frame: .zero)
        stack.orientation = .horizontal
        stack.spacing = 2
        stack.detachesHiddenViews = true
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            height,
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 6),
            // The whole width: buttons that dropped out come back once there is room again.
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -6),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
        // The strip must never decide a width (see QuickFilterBar): buttons that do not fit go.
        stack.setHuggingPriority(.init(1), for: .horizontal)
        stack.setClippingResistancePriority(.init(1), for: .horizontal)
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    /// The buttons, in the order shown (tests read them).
    var buttons: [NSButton] {
        stack.arrangedSubviews.compactMap { $0 as? NSButton }
    }

    func render(_ folders: [String], pinned: [String]) {
        guard rendered?.folders != folders || rendered?.pinned != pinned else {
            return
        }
        rendered = (folders, pinned)
        for view in stack.arrangedSubviews {
            stack.removeArrangedSubview(view)
            view.removeFromSuperview()
        }
        for (index, folder) in folders.enumerated() {
            let button = button(for: folder, isPinned: pinned.contains(folder))
            stack.addArrangedSubview(button)
            // Earlier ones stay longest when the strip is narrow.
            stack.setVisibilityPriority(NSStackView.VisibilityPriority(rawValue: Float(1000 - index)), for: button)
        }
        isHidden = folders.isEmpty
        height.constant = folders.isEmpty ? 0 : 24
    }

    private func button(for folder: String, isPinned: Bool) -> NSButton {
        let title = folder == "/" ? "/" : (folder as NSString).lastPathComponent
        let button = NSButton(title: title, target: self, action: #selector(go(_:)))
        button.bezelStyle = .accessoryBarAction
        button.controlSize = .small
        button.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        button.toolTip = folder
        button.identifier = NSUserInterfaceItemIdentifier(folder)
        if isPinned {
            button.image = NSImage(systemSymbolName: "pin.fill", accessibilityDescription: "Pinned")
            button.imagePosition = .imageLeading
        }
        let menu = NSMenu()
        add(isPinned ? "Unpin" : "Pin to Recent Folders", isPinned ? .unpin : .pin, folder, to: menu)
        add("Remove from Recent Folders", .remove, folder, to: menu)
        button.menu = menu
        return button
    }

    private func add(_ title: String, _ change: RecentFolderChange, _ folder: String, to menu: NSMenu) {
        let item = menu.addItem(withTitle: title, action: #selector(change(_:)), keyEquivalent: "")
        item.target = self
        item.representedObject = Change(folder: folder, change: change)
    }

    @objc private func go(_ sender: NSButton) {
        guard let folder = sender.identifier?.rawValue else {
            return
        }
        onCommand?(.activate(side))
        onCommand?(.navigate(side, path: folder))
    }

    @objc private func change(_ sender: NSMenuItem) {
        if let change = sender.representedObject as? Change {
            onCommand?(.recentFolder(side, change.folder, change.change))
        }
    }

    private final class Change {
        let folder: String
        let change: RecentFolderChange

        init(folder: String, change: RecentFolderChange) {
            self.folder = folder
            self.change = change
        }
    }
}

extension FileListViewController {
    /// The strip spans the side below the list, above the fast filter's bar.
    func recentFoldersBarConstraints(in root: NSView) -> [NSLayoutConstraint] {
        [
            recentFoldersBar.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            recentFoldersBar.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            recentFoldersBar.bottomAnchor.constraint(equalTo: quickFilterBar.topAnchor),
        ]
    }
}
