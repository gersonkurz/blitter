import AppKit
import BlitterCore
import BlitterModel

/// The strip at the bottom of the window: one row per file operation, with progress and Cancel,
/// the conflict question in place (no modal dialog), and the problems of a job that had some.
/// Hidden while there are no jobs.
@MainActor
final class JobsViewController: NSViewController {
    private let workspace: Workspace
    private let stack = NSStackView()
    private var rows: [Int: JobRowView] = [:]
    private var noticeRows: [Int: NoticeRowView] = [:]
    /// The colors in use (#21); new rows take them, a new theme recolors all.
    private var palette: Palette?

    init(workspace: Workspace) {
        self.workspace = workspace
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    override func loadView() {
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 6
        stack.edgeInsets = NSEdgeInsets(top: 6, left: 10, bottom: 8, right: 10)
        stack.setHuggingPriority(.required, for: .vertical)
        view = stack
    }

    func render() {
        let paletteChanged = renderPalette()
        let jobs = workspace.jobs
        let ids = Set(jobs.map(\.id))
        for (id, row) in rows where !ids.contains(id) {
            stack.removeArrangedSubview(row)
            row.removeFromSuperview()
            rows[id] = nil
        }
        for job in jobs {
            let row = rows[job.id] ?? makeRow(for: job.id)
            row.configure(job)
        }
        renderNotices()
        if paletteChanged {
            for row in rows.values {
                row.apply(palette)
            }
            for row in noticeRows.values {
                row.text.textColor = noticeColor
            }
        }
        view.isHidden = jobs.isEmpty && workspace.notices.isEmpty
    }

    /// Returns true if the theme changed; the strip's own colors are set here, its rows' by
    /// the caller.
    private func renderPalette() -> Bool {
        guard let new = Palette.changed(from: palette, workspace.settings.theme, for: view) else {
            return false
        }
        palette = new
        view.appearance = new.appearance
        stack.wantsLayer = true
        stack.layer?.backgroundColor = new.isThemed ? new.color(.background).cgColor : nil
        return true
    }

    private var noticeColor: NSColor {
        palette.map { $0.isThemed ? $0.color(.error) : .systemOrange } ?? .systemOrange
    }

    /// Notices (e.g. settings problems) sit above the jobs, each with Dismiss.
    private func renderNotices() {
        let notices = workspace.notices
        let ids = Set(notices.map(\.id))
        for (id, row) in noticeRows where !ids.contains(id) {
            stack.removeArrangedSubview(row)
            row.removeFromSuperview()
            noticeRows[id] = nil
        }
        for notice in notices where noticeRows[notice.id] == nil {
            let row = NoticeRowView(notice) { [weak self] in self?.workspace.perform(.dismissNotice(notice.id)) }
            row.text.textColor = noticeColor
            stack.insertArrangedSubview(row, at: 0)
            row.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -20).isActive = true
            noticeRows[notice.id] = row
        }
    }

    private func makeRow(for id: Int) -> JobRowView {
        let row = JobRowView(id: id)
        row.apply(palette)
        row.onCommand = { [weak self] command in self?.workspace.perform(command) }
        stack.addArrangedSubview(row)
        row.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -20).isActive = true
        rows[id] = row
        return row
    }
}

/// One job: what it does, how far it is, and the buttons that fit its state.
@MainActor
final class JobRowView: NSView {
    let id: Int
    var onCommand: ((Command) -> Void)?
    private let title = NSTextField(labelWithString: "")
    private let detail = NSTextField(labelWithString: "")
    private let progress = NSProgressIndicator()
    private let buttons = NSStackView()
    private let applyToAll = NSButton(checkboxWithTitle: "Apply to all", target: nil, action: nil)
    private var renderedState: Job.State?
    private var palette: Palette?
    /// The detail lists the problems of a job that is done.
    private var showsProblems = false

    /// The theme's colors for the text, or the system's.
    func apply(_ palette: Palette?) {
        self.palette = palette
        let themed = palette?.isThemed == true ? palette : nil
        title.textColor = themed?.color(.text) ?? .labelColor
        detail.textColor = showsProblems ? themed?.color(.error) ?? .secondaryLabelColor
            : themed?.color(.dimText) ?? .secondaryLabelColor
    }

    init(id: Int) {
        self.id = id
        super.init(frame: .zero)
        title.font = .systemFont(ofSize: NSFont.smallSystemFontSize, weight: .medium)
        title.lineBreakMode = .byTruncatingMiddle
        detail.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        detail.textColor = .secondaryLabelColor
        detail.lineBreakMode = .byTruncatingMiddle
        progress.isIndeterminate = false
        progress.minValue = 0
        progress.maxValue = 1
        progress.controlSize = .small
        buttons.orientation = .horizontal
        buttons.spacing = 6
        let text = NSStackView(views: [title, detail, progress])
        text.orientation = .vertical
        text.alignment = .leading
        text.spacing = 2
        let line = NSStackView(views: [text, buttons])
        line.orientation = .horizontal
        line.alignment = .centerY
        line.translatesAutoresizingMaskIntoConstraints = false
        addSubview(line)
        NSLayoutConstraint.activate([
            line.leadingAnchor.constraint(equalTo: leadingAnchor),
            line.trailingAnchor.constraint(equalTo: trailingAnchor),
            line.topAnchor.constraint(equalTo: topAnchor),
            line.bottomAnchor.constraint(equalTo: bottomAnchor),
            progress.widthAnchor.constraint(equalTo: text.widthAnchor),
        ])
        text.setContentHuggingPriority(.defaultLow, for: .horizontal)
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    func configure(_ job: Job) {
        title.stringValue = JobText.title(job.operation)
        detail.stringValue = JobText.detail(job)
        let problems = job.isDone && !job.errors.isEmpty
        if problems != showsProblems {
            showsProblems = problems
            apply(palette)
        }
        if let fraction = JobText.fraction(job.progress), job.state == .running {
            progress.isHidden = false
            progress.doubleValue = fraction
        } else {
            progress.isHidden = true
        }
        // Rebuilding the buttons only when the state changes keeps a click from landing on a
        // button that was just replaced.
        guard job.state != renderedState else {
            return
        }
        renderedState = job.state
        for view in buttons.arrangedSubviews {
            buttons.removeArrangedSubview(view)
            view.removeFromSuperview()
        }
        switch job.state {
        case .running:
            addButton("Cancel") { .cancelJob($0.id) }
        case .waiting:
            applyToAll.state = .off
            buttons.addArrangedSubview(applyToAll)
            addButton("Replace") { .answerConflict(job: $0.id, ConflictAnswer(.replace, applyToAll: $0.appliesToAll)) }
            addButton("Skip") { .answerConflict(job: $0.id, ConflictAnswer(.skip, applyToAll: $0.appliesToAll)) }
            addButton("Keep Both") {
                .answerConflict(job: $0.id, ConflictAnswer(.keepBoth, applyToAll: $0.appliesToAll))
            }
            addButton("Cancel") { .cancelJob($0.id) }
        case .finished, .cancelled:
            addButton("Dismiss") { .dismissJob($0.id) }
        }
    }

    private var appliesToAll: Bool {
        applyToAll.state == .on
    }

    private func addButton(_ title: String, _ command: @escaping (JobRowView) -> Command) {
        let button = CommandButton(title: title) { [weak self] in
            guard let self else {
                return
            }
            onCommand?(command(self))
        }
        button.controlSize = .small
        button.bezelStyle = .push
        buttons.addArrangedSubview(button)
    }
}

/// A notice: its text, wrapped, and Dismiss.
@MainActor
final class NoticeRowView: NSView {
    let text: NSTextField

    init(_ notice: Notice, dismiss: @escaping () -> Void) {
        text = NSTextField(wrappingLabelWithString: notice.text)
        super.init(frame: .zero)
        text.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        text.textColor = .systemOrange
        let button = CommandButton(title: "Dismiss", handler: dismiss)
        button.controlSize = .small
        button.bezelStyle = .push
        let line = NSStackView(views: [text, button])
        line.orientation = .horizontal
        line.alignment = .centerY
        line.translatesAutoresizingMaskIntoConstraints = false
        addSubview(line)
        NSLayoutConstraint.activate([
            line.leadingAnchor.constraint(equalTo: leadingAnchor),
            line.trailingAnchor.constraint(equalTo: trailingAnchor),
            line.topAnchor.constraint(equalTo: topAnchor),
            line.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
        text.setContentHuggingPriority(.defaultLow, for: .horizontal)
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError("init(coder:) is not supported")
    }
}

/// A button that runs a closure, so each row's buttons need no selector plumbing.
final class CommandButton: NSButton {
    private var handler: () -> Void = {}

    convenience init(title: String, handler: @escaping () -> Void) {
        self.init(title: title, target: nil, action: nil)
        self.handler = handler
        target = self
        action = #selector(run(_:))
    }

    @objc private func run(_: Any?) {
        handler()
    }
}

/// The words a job row shows.
enum JobText {
    static func title(_ operation: FileOperation) -> String {
        switch operation {
        case let .copy(paths, folder):
            "Copying \(items(paths)) to “\(name(folder))”"
        case let .move(paths, folder):
            "Moving \(items(paths)) to “\(name(folder))”"
        case let .trash(paths):
            "Moving \(items(paths)) to the Trash"
        case let .delete(paths):
            "Deleting \(items(paths))"
        case let .command(arguments, _):
            "Running “\(([name(arguments.first ?? "")] + arguments.dropFirst()).joined(separator: " "))”"
        case let .rename(path, newName):
            "Renaming “\(name(path))” to “\(newName)”"
        case let .renameAll(renames):
            "Renaming \(items(renames.map(\.path)))"
        case let .newFolder(_, folderName):
            "Creating “\(folderName)”"
        case let .removeExactly(plan, forGood):
            forGood ? "Deleting \(plan.files.count) items" : "Moving \(plan.files.count) items to the Trash"
        case let .undo(steps):
            steps.count == 1 ? "Undoing 1 change" : "Undoing \(steps.count) changes"
        }
    }

    static func detail(_ job: Job) -> String {
        switch job.state {
        case let .waiting(conflict):
            "“\(name(conflict.existing))” already exists in “\(name(parent(conflict.existing)))”."
        case .cancelled:
            job.errors.isEmpty ? "Cancelled." : "Cancelled. " + problems(job.errors)
        case .finished:
            job.errors.isEmpty ? "Done." : problems(job.errors)
        case .running:
            progressText(job.progress)
        }
    }

    static func fraction(_ progress: JobProgress) -> Double? {
        if let total = progress.totalBytes, total > 0 {
            return min(1, Double(progress.doneBytes) / Double(total))
        }
        guard progress.totalItems > 0 else {
            return nil
        }
        return Double(progress.doneItems) / Double(progress.totalItems)
    }

    private static func progressText(_ progress: JobProgress) -> String {
        var parts: [String] = []
        if progress.totalItems > 1 {
            parts.append("\(progress.doneItems) of \(progress.totalItems) items")
        }
        if let total = progress.totalBytes, total > 0 {
            let formatter = ByteCountFormatter()
            formatter.countStyle = .file
            let done = formatter.string(fromByteCount: progress.doneBytes)
            parts.append("\(done) of \(formatter.string(fromByteCount: total))")
        }
        if let current = progress.currentItem {
            parts.append(current)
        }
        return parts.joined(separator: " · ")
    }

    private static func problems(_ errors: [JobError]) -> String {
        let first = "\(name(errors[0].path)): \(errors[0].message)"
        return errors.count == 1 ? first : "\(first) (and \(errors.count - 1) more)"
    }

    private static func items(_ paths: [String]) -> String {
        paths.count == 1 ? "“\(name(paths[0]))”" : "\(paths.count) items"
    }

    private static func parent(_ path: String) -> String {
        (path as NSString).deletingLastPathComponent
    }

    private static func name(_ path: String) -> String {
        (path as NSString).lastPathComponent
    }
}
