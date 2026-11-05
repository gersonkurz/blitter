import AppKit
import BlitterModel

/// The fast filter (#39): typing in the list highlights matching names, `*` first filters the
/// list. Keys become commands; the bar at the bottom shows what was typed.
extension FileListViewController {
    /// Returns whether the key went to the fast filter.
    func handleQuickFilterKey(_ event: NSEvent) -> Bool {
        guard event.modifierFlags.isDisjoint(with: [.command, .control, .option]) else {
            return false
        }
        let filter = workspace.state(of: side).quickFilter
        switch event.keyCode {
        case 53: // Escape
            return filter != nil && setQuickFilter(nil)
        case 51: // Backspace: the last character, or the filter once nothing is left
            guard var filter else {
                return false
            }
            return setQuickFilter(filter.text.isEmpty ? nil : { filter.text.removeLast(); return filter }())
        case 125, 126: // ↓ ↑: the next or previous match
            guard filter?.mode == .highlight else {
                return false
            }
            workspace.perform(.selectQuickFilterMatch(side, forward: event.keyCode == 125))
            return true
        default:
            break
        }
        guard let typed = event.characters, Self.isText(typed) else {
            return false
        }
        guard let filter else {
            switch typed {
            case " ": return false // Space without a filter: Quick Look
            case "*": return setQuickFilter(QuickFilter("", mode: .filter))
            default: return setQuickFilter(QuickFilter(typed, mode: .highlight))
            }
        }
        return setQuickFilter(QuickFilter(filter.text + typed, mode: filter.mode))
    }

    private func setQuickFilter(_ filter: QuickFilter?) -> Bool {
        workspace.perform(.setQuickFilter(side, filter))
        return true
    }

    /// Printable characters: no control characters, no function keys (arrows, F1...).
    private static func isText(_ characters: String) -> Bool {
        !characters.isEmpty && characters.unicodeScalars.allSatisfy {
            !CharacterSet.controlCharacters.contains($0) && !(0xF700 ... 0xF8FF).contains($0.value)
        }
    }

    // MARK: Rendering

    /// The matches come from the model (found in the background): nothing is matched here.
    func renderQuickFilter() {
        let state = workspace.state(of: side)
        let filter = state.quickFilter
        quickFilterBar.show(filter, matches: filter?.mode == .filter ? entries.count : state.highlighted.count)
        // Unchanged, the sets share their storage and compare at once.
        guard state.highlighted != highlightedNames else {
            return
        }
        highlightedNames = state.highlighted
        let nameColumn = tableView.column(withIdentifier: Self.nameColumn)
        if !entries.isEmpty, nameColumn >= 0 {
            tableView.reloadData(forRowIndexes: IndexSet(integersIn: 0 ..< entries.count),
                                 columnIndexes: [nameColumn])
        }
    }

    /// Whether the name is a highlighted match (drawn bold).
    func isHighlighted(_ name: String) -> Bool {
        highlightedNames.contains(name)
    }
}

/// The line under the list while the fast filter is on: what was typed, and how many match.
final class QuickFilterBar: NSView {
    let label = NSTextField(labelWithString: "")
    private lazy var height = heightAnchor.constraint(equalToConstant: 0)

    init() {
        super.init(frame: .zero)
        label.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        label.lineBreakMode = .byTruncatingMiddle
        // The text must never decide a width: at the default priorities it competes with the
        // split views' holding priorities, and the splitters stop moving (#38's test caught it).
        label.setContentHuggingPriority(.init(1), for: .horizontal)
        label.setContentCompressionResistancePriority(.init(1), for: .horizontal)
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)
        NSLayoutConstraint.activate([
            height,
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
        isHidden = true
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    func show(_ filter: QuickFilter?, matches: Int) {
        isHidden = filter == nil
        height.constant = filter == nil ? 0 : 22
        guard let filter else {
            return
        }
        let count = switch filter.mode {
        case .highlight: matches == 0 ? "no match" : matches == 1 ? "1 match" : "\(matches) matches"
        case .filter: matches == 1 ? "1 item" : "\(matches) items"
        }
        let text = filter.text.isEmpty ? "type to filter" : "“\(filter.text)”: \(count)"
        label.stringValue = (filter.mode == .filter ? "Filter " : "Find ") + text + "  ·  esc ends"
        label.textColor = filter.mode == .highlight && matches == 0 ? .systemRed : .secondaryLabelColor
    }
}
