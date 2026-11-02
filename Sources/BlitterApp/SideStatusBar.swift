import AppKit
import BlitterModel

/// The line below a file list (#51): what the list shows or what of it is selected, and the free
/// space on the folder's volume.
@MainActor
final class SideStatusBar: NSView {
    let summaryLabel = NSTextField(labelWithString: "")
    let freeSpaceLabel = NSTextField(labelWithString: "")
    /// What the summary was last drawn from: the selection is counted again only when the
    /// listing or the selection changed, not when only the free space did.
    private var rendered: Key?

    private struct Key: Equatable {
        let version: Int
        let status: LoadStatus
        let selection: Set<String>
    }

    private static let sizeFormatter: ByteCountFormatter = {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return formatter
    }()

    init() {
        super.init(frame: .zero)
        for (label, priority) in [(summaryLabel, 1), (freeSpaceLabel, 2)] {
            label.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
            label.textColor = .secondaryLabelColor
            label.lineBreakMode = .byTruncatingTail
            // The text must never decide a width (see QuickFilterBar); the free space gives way last.
            label.setContentHuggingPriority(.init(Float(priority)), for: .horizontal)
            label.setContentCompressionResistancePriority(.init(Float(priority)), for: .horizontal)
            label.translatesAutoresizingMaskIntoConstraints = false
            addSubview(label)
        }
        freeSpaceLabel.alignment = .right
        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: 20),
            summaryLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            summaryLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
            freeSpaceLabel.leadingAnchor.constraint(greaterThanOrEqualTo: summaryLabel.trailingAnchor, constant: 8),
            freeSpaceLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            freeSpaceLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    func render(_ state: SideState) {
        let free = Self.freeSpace(state)
        if freeSpaceLabel.stringValue != free {
            freeSpaceLabel.stringValue = free
        }
        let key = Key(version: state.entriesVersion, status: state.status, selection: state.selection)
        guard key != rendered else {
            return
        }
        rendered = key
        summaryLabel.stringValue = Self.summary(state)
    }

    /// "3 folders, 12 files, 4,5 MB"; with a selection, "2 of 15 selected: 1 folder, 1 file, 45 KB".
    static func summary(_ state: SideState) -> String {
        if case .failed = state.status {
            return ""
        }
        guard !state.selection.isEmpty else {
            return state.totals.count == 0 ? "No items" : describe(state.totals)
        }
        let selected = state.selectedTotals
        return "\(selected.count.formatted()) of \(state.totals.count.formatted()) selected: " + describe(selected)
    }

    static func freeSpace(_ state: SideState) -> String {
        // A value read for another folder is not shown: the new folder may be on another volume.
        guard let space = state.freeSpace, space.folder == state.entriesLocation else {
            return ""
        }
        return sizeFormatter.string(fromByteCount: space.bytes) + " free"
    }

    private static func describe(_ totals: EntryTotals) -> String {
        var parts: [String] = []
        if totals.folders > 0 {
            parts.append(totals.folders == 1 ? "1 folder" : "\(totals.folders.formatted()) folders")
        }
        if totals.files > 0 {
            parts.append(totals.files == 1 ? "1 file" : "\(totals.files.formatted()) files")
            parts.append(sizeFormatter.string(fromByteCount: totals.bytes))
        }
        return parts.joined(separator: ", ")
    }
}
