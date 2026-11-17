import AppKit
import BlitterCore
import BlitterModel

/// The strip at the bottom of the window: the notices, and one line about the jobs (#112) —
/// how many, how far, a question waiting, problems — with Show Jobs; the jobs themselves are in
/// the Jobs window. Hidden while there are neither.
@MainActor
final class JobsViewController: NSViewController {
    private let workspace: Workspace
    private let stack = NSStackView()
    private let indicator = JobsIndicatorView()
    private var noticeRows: [Int: NoticeRowView] = [:]
    /// Show Jobs: the Jobs window.
    var showJobs: () -> Void = {}
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
        if indicator.superview == nil {
            indicator.show = { [weak self] in self?.showJobs() }
            stack.addArrangedSubview(indicator)
            indicator.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -20).isActive = true
        }
        let tasks = workspace.backgroundTasks
        indicator.text.stringValue = JobText.summary(jobs, tasks: tasks)
        indicator.isHidden = jobs.isEmpty && tasks.isEmpty
        renderNotices()
        if paletteChanged {
            indicator.text.textColor = palette?.isThemed == true ? palette?.color(.dimText) : .secondaryLabelColor
            for row in noticeRows.values {
                row.text.textColor = noticeColor
            }
        }
        view.isHidden = jobs.isEmpty && tasks.isEmpty && workspace.notices.isEmpty
    }

    /// Returns true if the theme changed; the strip's own colors are set here, its rows' by
    /// the caller.
    private func renderPalette() -> Bool {
        guard let new = Palette.changed(from: palette, workspace.shownTheme, for: view) else {
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
}

/// The strip's line about the jobs, and Show Jobs (#112).
@MainActor
final class JobsIndicatorView: NSView {
    let text = NSTextField(labelWithString: "")
    var show: () -> Void = {}

    init() {
        super.init(frame: .zero)
        text.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        text.textColor = .secondaryLabelColor
        text.lineBreakMode = .byTruncatingTail
        let button = CommandButton(title: "Show Jobs") { [weak self] in self?.show() }
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
    /// What the buttons were made for: the state, and whether Start Now could run the job.
    private var renderedButtons: (state: Job.State, canStartNow: Bool)?
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
        // The text takes the width up to the buttons, which line up at the right edge (#112).
        for view in [text, buttons] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        NSLayoutConstraint.activate([
            text.leadingAnchor.constraint(equalTo: leadingAnchor),
            text.topAnchor.constraint(equalTo: topAnchor),
            text.bottomAnchor.constraint(equalTo: bottomAnchor),
            text.trailingAnchor.constraint(equalTo: buttons.leadingAnchor, constant: -8),
            buttons.trailingAnchor.constraint(equalTo: trailingAnchor),
            buttons.centerYAnchor.constraint(equalTo: centerYAnchor),
            buttons.topAnchor.constraint(greaterThanOrEqualTo: topAnchor),
            progress.widthAnchor.constraint(equalTo: text.widthAnchor),
        ])
        // A stack view's own hugging: the buttons' stays as narrow as its buttons, the text's
        // takes what is left.
        // As wide as the row lets it: the buttons keep their own width at the right edge.
        let wide = text.widthAnchor.constraint(equalTo: widthAnchor)
        wide.priority = .defaultLow
        wide.isActive = true
        buttons.setContentCompressionResistancePriority(.required, for: .horizontal)
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    /// A search or a folder measuring (#112 step 3): what it does, how far, for how long, and
    /// Cancel, which stops it as its own Stop does.
    func configure(_ task: BackgroundTask, now: Date) {
        title.stringValue = task.title
        let elapsed = JobText.duration(now.timeIntervalSince(task.started)) + " elapsed"
        detail.stringValue = [task.progress, elapsed, task.origin ?? ""].filter { !$0.isEmpty }.joined(separator: " · ")
        progress.isHidden = true
        guard buttons.arrangedSubviews.isEmpty else {
            return
        }
        addButton("Cancel") { .cancelTask($0.id) }
    }

    /// `now`: for the times a running job shows (#112); `canStartNow`: a waiting job offers
    /// Start Now.
    func configure(_ job: Job, now: Date = Date(), canStartNow: Bool = false) {
        title.stringValue = JobText.title(job.operation)
        detail.stringValue = JobText.detail(job, now: now)
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
        if let rendered = renderedButtons, rendered.state == job.state, rendered.canStartNow == canStartNow {
            return
        }
        renderedButtons = (job.state, canStartNow)
        for view in buttons.arrangedSubviews {
            buttons.removeArrangedSubview(view)
            view.removeFromSuperview()
        }
        switch job.state {
        case .queued:
            if canStartNow {
                addButton("Start Now") { .startJobNow($0.id) } // #112: beside the running ones
            }
            addButton("Cancel") { .cancelJob($0.id) }
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
