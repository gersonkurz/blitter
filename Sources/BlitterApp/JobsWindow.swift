import AppKit
import BlitterCore
import BlitterModel

/// When the Jobs window (#112) shows, comes forward or closes by itself. Fast jobs never show it:
/// it appears once a job not done is older than `delay`, at once for a question (a conflict to
/// answer), and closes itself when every job is done and none had problems. Closed by the user, it
/// stays closed for the jobs there are — until a question comes, or every job is done.
struct JobsWindowPolicy: Equatable {
    enum Step: Equatable {
        case none, show, bringForward, close
    }

    static let delay: TimeInterval = 5

    var isOpen = false
    var closedByUser = false

    mutating func step(_ jobs: [Job], at now: Date) -> Step {
        let open = jobs.filter { !$0.isDone }
        let asks = open.contains {
            if case .waiting = $0.state {
                true
            } else {
                false
            }
        }
        let problems = jobs.contains { $0.isDone && !$0.errors.isEmpty }
        if open.isEmpty {
            closedByUser = false // the next long job shows the window again
        }
        if asks {
            closedByUser = false
            isOpen = true
            return .bringForward
        }
        if isOpen {
            guard open.isEmpty, !problems else {
                return .none
            }
            isOpen = false
            return .close
        }
        guard !closedByUser, open.contains(where: { now.timeIntervalSince($0.added) >= Self.delay }) else {
            return .none
        }
        isOpen = true
        return .show
    }

    /// The user closed it.
    mutating func closed() {
        isOpen = false
        closedByUser = true
    }

    /// The user asked for it (Window → Jobs, Show Jobs).
    mutating func shownByUser() {
        isOpen = true
        closedByUser = false
    }
}

/// The Jobs window (#112): one for every main window, as the jobs are every window's. The jobs
/// running (and any question to answer) first, then those waiting for their turn — each with
/// Cancel, and Start Now where it can run beside the others — then those done with problems,
/// until dismissed. It never takes the keyboard from a file list: it is ordered in front, not made
/// key; closing it cancels nothing.
@MainActor
final class JobsWindowController: NSWindowController, NSWindowDelegate {
    static let shared = JobsWindowController()

    /// The window that last told it about the jobs: its workspace runs the buttons' commands
    /// (the queue is the same for all). Once that window has closed, any other open window's does
    /// (#112 review): the app model lives as long as Blitter.
    private weak var lastWorkspace: Workspace?
    private weak var app: AppModel?

    private var workspace: Workspace? {
        lastWorkspace ?? app?.anyWorkspace
    }

    private(set) var policy = JobsWindowPolicy()
    private let stack = NSStackView()
    private var rows: [Int: JobRowView] = [:]
    private let headers = (
        running: header("Running"),
        waiting: header("Waiting"),
        problems: header("Done, with problems")
    )
    private var ticker: Timer?
    /// The clock (tests set it).
    var now: () -> Date = { Date() }
    /// Set while the window is closed by the policy, not by the user.
    private var closingItself = false
    /// The colors in use (#21): the windows' theme, as the strip had it.
    private var palette: Palette?

    init() {
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 560, height: 320),
                            styleMask: [.titled, .closable, .resizable, .utilityWindow],
                            backing: .buffered, defer: true)
        panel.title = "Jobs"
        panel.becomesKeyOnlyIfNeeded = true
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.setFrameAutosaveName("Jobs")
        super.init(window: panel)
        panel.delegate = self
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        stack.edgeInsets = NSEdgeInsets(top: 10, left: 12, bottom: 12, right: 12)
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        let document = FlippedView()
        document.translatesAutoresizingMaskIntoConstraints = false
        stack.translatesAutoresizingMaskIntoConstraints = false
        document.addSubview(stack)
        scroll.documentView = document
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: document.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: document.trailingAnchor),
            stack.topAnchor.constraint(equalTo: document.topAnchor),
            stack.bottomAnchor.constraint(equalTo: document.bottomAnchor),
            document.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor),
        ])
        panel.contentView = scroll
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    private static func header(_ title: String) -> NSTextField {
        let label = NSTextField(labelWithString: title)
        label.font = .systemFont(ofSize: NSFont.smallSystemFontSize, weight: .semibold)
        label.textColor = .secondaryLabelColor
        return label
    }

    /// The jobs changed, or a second passed: the rows, and whether the window shows.
    func render(_ workspace: Workspace) {
        lastWorkspace = workspace
        app = workspace.app
        let jobs = workspace.jobs
        let time = now()
        switch policy.step(jobs, at: time) {
        case .none: break
        case .show, .bringForward: showWithoutFocus()
        case .close: closeItself()
        }
        renderPalette(workspace.shownTheme)
        renderRows(jobs, canStartNow: workspace.canStartJobNow, at: time)
        tickWhile(jobs.contains { !$0.isDone })
    }

    func renderPalette(_ theme: ThemeSettings) {
        guard let content = window?.contentView,
              let new = Palette.changed(from: palette, theme, for: content)
        else {
            return
        }
        palette = new
        window?.appearance = new.appearance
        window?.backgroundColor = new.isThemed ? new.color(.background) : .windowBackgroundColor
        for row in rows.values {
            row.apply(new)
        }
    }

    /// Window → Jobs, or Show Jobs in a window's strip.
    func showByUser() {
        policy.shownByUser()
        if let workspace {
            renderRows(workspace.jobs, canStartNow: workspace.canStartJobNow, at: now())
        }
        showWithoutFocus()
    }

    var isShown: Bool {
        window?.isVisible == true
    }

    private func showWithoutFocus() {
        if window?.isVisible != true {
            window?.center()
        }
        window?.orderFront(nil) // in front, but the keyboard stays where it is
    }

    private func closeItself() {
        closingItself = true
        close()
        closingItself = false
    }

    func windowWillClose(_: Notification) {
        if !closingItself {
            policy.closed() // the user closed it: nothing is cancelled
        }
    }

    // MARK: Rows

    /// The rows for these jobs (the manual's picture shows made-up ones).
    func renderRows(_ jobs: [Job], canStartNow: (Int) -> Bool, at time: Date) {
        let ids = Set(jobs.map(\.id))
        for (id, row) in rows where !ids.contains(id) {
            row.removeFromSuperview()
            rows[id] = nil
        }
        let running = jobs.filter {
            if case .queued = $0.state {
                false
            } else {
                !$0.isDone
            }
        }
        let waiting = jobs.filter { $0.state == .queued }
        let problems = jobs.filter { $0.isDone && !$0.errors.isEmpty }
        var order: [NSView] = []
        for (header, group) in [(headers.running, running), (headers.waiting, waiting),
                                (headers.problems, problems)] where !group.isEmpty
        {
            order.append(header)
            for job in group {
                let row = rows[job.id] ?? makeRow(job.id)
                row.configure(job, now: time, canStartNow: canStartNow(job.id))
                order.append(row)
            }
        }
        if stack.arrangedSubviews != order {
            for view in stack.arrangedSubviews {
                stack.removeArrangedSubview(view)
                view.removeFromSuperview()
            }
            for view in order {
                stack.addArrangedSubview(view)
                if view is JobRowView {
                    view.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -24).isActive = true
                }
            }
        }
    }

    private func makeRow(_ id: Int) -> JobRowView {
        let row = JobRowView(id: id)
        row.apply(palette)
        row.onCommand = { [weak self] command in
            guard let workspace = self?.workspace else {
                return
            }
            workspace.perform(command)
            self?.render(workspace)
        }
        rows[id] = row
        return row
    }

    /// Once a second while jobs run: their times, the 5-second rule, the quiet mark.
    private func tickWhile(_ running: Bool) {
        guard running else {
            ticker?.invalidate()
            ticker = nil
            return
        }
        guard ticker == nil else {
            return
        }
        ticker = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.tick()
            }
        }
    }

    /// A second passed: render again, through whichever window is still open.
    func tick() {
        if let workspace {
            render(workspace)
        }
    }

    /// The rows as shown, for tests.
    var shownRows: [JobRowView] {
        stack.arrangedSubviews.compactMap { $0 as? JobRowView }
    }

    var shownHeaders: [String] {
        stack.arrangedSubviews.compactMap { ($0 as? NSTextField)?.stringValue }
    }
}

/// A document view that grows downwards, so the list starts at the top.
private final class FlippedView: NSView {
    override var isFlipped: Bool {
        true
    }
}
