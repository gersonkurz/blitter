import AppKit
@testable import Blitter
@testable import BlitterCore
@testable import BlitterModel
import Synchronization
import Testing

/// #112 step 2b: when the Jobs window shows, what it shows, and what its buttons do.
@MainActor
struct JobsWindowPolicyTests {
    private let start = Date(timeIntervalSinceReferenceDate: 0)

    private func job(_ id: Int, _ state: Job.State, added: TimeInterval = 0, errors: [JobError] = []) -> Job {
        var job = Job(id: id, operation: .copy(["/a/x"], into: "/b"), added: start.addingTimeInterval(added))
        job.state = state
        job.errors = errors
        return job
    }

    @Test func fastJobsNeverShowIt() {
        var policy = JobsWindowPolicy()
        #expect(policy.step([job(1, .running)], at: start.addingTimeInterval(4.9)) == JobsWindowPolicy.Step.none)
        #expect(policy.step([job(1, .finished)], at: start.addingTimeInterval(6)) == JobsWindowPolicy.Step.none)
        #expect(!policy.isOpen)
    }

    @Test func aJobOlderThanFiveSecondsShowsItAndItClosesWhenAllIsDoneWell() {
        var policy = JobsWindowPolicy()
        let jobs = [job(1, .running), job(2, .queued, added: 3)]
        #expect(policy.step(jobs, at: start.addingTimeInterval(5)) == .show)
        #expect(policy.step(jobs, at: start.addingTimeInterval(6)) == JobsWindowPolicy.Step.none) // shown
        #expect(policy.step([job(2, .running, added: 3)], at: start.addingTimeInterval(9)) == JobsWindowPolicy.Step
            .none)
        #expect(policy.step([], at: start.addingTimeInterval(10)) == .close)
        #expect(!policy.isOpen)
    }

    @Test func problemsKeepItOpenUntilDismissed() {
        var policy = JobsWindowPolicy()
        #expect(policy.step([job(1, .running)], at: start.addingTimeInterval(5)) == .show)
        let failed = job(1, .finished, errors: [JobError(path: "/a/x", message: "no")])
        #expect(policy.step([failed], at: start.addingTimeInterval(7)) == JobsWindowPolicy.Step.none)
        #expect(policy.step([], at: start.addingTimeInterval(8)) == .close) // dismissed
    }

    @Test func aQuestionBringsItForwardAtOnceEvenWhenClosedByTheUser() {
        var policy = JobsWindowPolicy()
        let asking = job(1, .waiting(Conflict(source: "/a/x", existing: "/b/x")))
        #expect(policy.step([asking], at: start.addingTimeInterval(1)) == .bringForward)
        policy.closed()
        #expect(policy.step([job(1, .running)], at: start.addingTimeInterval(9)) == JobsWindowPolicy.Step.none)
        #expect(policy.step([asking], at: start.addingTimeInterval(10)) == .bringForward)
    }

    @Test func closedByTheUserItStaysClosedForTheseJobs() {
        var policy = JobsWindowPolicy()
        #expect(policy.step([job(1, .running)], at: start.addingTimeInterval(5)) == .show)
        policy.closed()
        #expect(policy.step([job(1, .running), job(2, .queued, added: 1)], at: start.addingTimeInterval(20))
            == JobsWindowPolicy.Step.none)
        #expect(policy.step([], at: start.addingTimeInterval(21)) == JobsWindowPolicy.Step.none) // all done
        #expect(policy.step([job(3, .running, added: 22)], at: start.addingTimeInterval(27)) == .show) // a new one
        policy.closed()
        policy.shownByUser() // Window → Jobs
        #expect(policy.isOpen)
    }
}

@MainActor
struct JobTextTests {
    private let start = Date(timeIntervalSinceReferenceDate: 0)

    @Test func aRunningJobSaysHowFarHowFastHowLongAndWhoStartedIt() {
        var job = Job(id: 1, operation: .copy(["/a/x"], into: "/b"), origin: "From automation (Claude)",
                      added: start)
        job.state = .running
        job.started = start
        job.progress.totalBytes = 10_000_000
        job.record(ProgressSample(time: start, bytes: 0))
        job.progress.doneBytes = 4_000_000
        job.record(ProgressSample(time: start.addingTimeInterval(4), bytes: 4_000_000))
        job.lastProgress = start.addingTimeInterval(4)
        let text = JobText.detail(job, now: start.addingTimeInterval(4))
        #expect(text == "4 MB of 10 MB · 1 MB/s · 0:04 elapsed · about 0:06 left · From automation (Claude)")
        // No progress for half a minute: said first; the speed has fallen meanwhile.
        let quiet = JobText.detail(job, now: start.addingTimeInterval(40))
        #expect(quiet.hasPrefix("No progress for 0:36 · 4 MB of 10 MB · "))
        #expect(quiet.contains("0:40 elapsed") && !quiet.contains("left"))
    }

    @Test func withoutATotalItSaysWhatIsDoneSoFar() {
        var job = Job(id: 1, operation: .copy(["/a/x"], into: "/b"))
        job.state = .running
        job.progress.doneBytes = 2_000_000
        #expect(JobText.detail(job, now: Date()) == "2 MB so far")
        job.state = .queued
        #expect(JobText.detail(job) == "Waiting for its turn.")
    }

    @Test func durations() {
        #expect(JobText.duration(4.4) == "0:04" && JobText.duration(725) == "12:05")
        #expect(JobText.duration(3725) == "1:02:05" && JobText.duration(-3) == "0:00")
    }

    @Test func theStripSaysItInOneLine() {
        var running = Job(id: 1, operation: .copy(["/a/x"], into: "/b"))
        running.state = .running
        running.progress.totalItems = 4
        running.progress.doneItems = 1
        let waiting = Job(id: 2, operation: .delete(["/a/y"]))
        #expect(JobText.summary([running, waiting]) == "Copying “x” to “b”, 25 % · 1 waiting")
        var failed = Job(id: 3, operation: .trash(["/a/z"]))
        failed.state = .finished
        failed.errors = [JobError(path: "/a/z", message: "no")]
        #expect(JobText.summary([failed]) == "1 job had problems")
        var asking = running
        asking.state = .waiting(Conflict(source: "/a/x", existing: "/b/x"))
        #expect(JobText.summary([asking, waiting]) == "Copying “x” to “b”: a question is waiting.")
        #expect(JobText.summary([]) == "")
    }
}

/// The window itself, with real jobs on real files.
@MainActor
@Suite(.serialized)
final class JobsWindowTests {
    final class Clock: Sendable {
        private let time = Mutex(Date())

        var now: Date {
            time.withLock { $0 }
        }

        func advance(_ seconds: TimeInterval) {
            time.withLock { $0 += seconds }
        }
    }

    private let root = NSTemporaryDirectory() + "BlitterJobsWindow-" + UUID().uuidString
    private let gate = DispatchSemaphore(value: 0)
    private let clock = Clock()
    private let workspace: Workspace
    private let jobsWindow = JobsWindowController()

    init() throws {
        for folder in ["left", "right"] {
            try FileManager.default.createDirectory(atPath: root + "/" + folder, withIntermediateDirectories: true)
        }
        let clock = clock
        workspace = Workspace(initialLocation: root + "/left", home: root, directoryCheck: { _ in false },
                              volumes: { [] }, watcher: FakeWatcher.factory,
                              jobs: JobQueue(trash: { _ in nil }, gate: gate, now: { clock.now }))
        jobsWindow.now = { clock.now }
    }

    isolated deinit {
        jobsWindow.close()
        for _ in 0 ..< 10 {
            gate.signal()
        }
        try? FileManager.default.removeItem(atPath: root)
    }

    private func file(_ name: String, _ contents: String = "x") -> String {
        let path = root + "/left/" + name
        FileManager.default.createFile(atPath: path, contents: Data(contents.utf8))
        return path
    }

    private func waitUntil(_ condition: () -> Bool) async throws {
        for _ in 0 ..< 300 where !condition() {
            try await Task.sleep(for: .milliseconds(10))
            jobsWindow.render(workspace)
        }
        try #require(condition())
    }

    private func buttons(_ row: JobRowView) -> [NSButton] {
        allSubviews(of: row).compactMap { $0 as? NSButton }.filter { $0.title != "Apply to all" }
    }

    private func allSubviews(of view: NSView) -> [NSView] {
        view.subviews + view.subviews.flatMap(allSubviews)
    }

    @Test func itShowsAfterFiveSecondsWithRunningAndWaitingJobsAndStartNowRunsOne() async throws {
        let first = workspace.startJob(.copy([file("a.txt")], into: root + "/right"))
        let second = workspace.startJob(.copy([file("b.txt")], into: root + "/right"))
        try await waitUntil { self.workspace.canStartJobNow(second) }
        jobsWindow.render(workspace)
        #expect(!jobsWindow.isShown) // under five seconds
        clock.advance(5)
        jobsWindow.render(workspace)
        #expect(jobsWindow.isShown && jobsWindow.window?.isKeyWindow == false) // shown, not key
        #expect(jobsWindow.shownHeaders == ["Running", "Waiting"])
        let rows = jobsWindow.shownRows
        #expect(rows.map(\.id) == [first, second])
        #expect(buttons(rows[0]).map(\.title) == ["Cancel"])
        #expect(buttons(rows[1]).map(\.title) == ["Start Now", "Cancel"])

        try #require(buttons(rows[1]).first).performClick(nil) // Start Now
        #expect(workspace.jobs.first { $0.id == second }?.state == .running)
        #expect(jobsWindow.shownHeaders == ["Running"])
        gate.signal()
        gate.signal()
        try await waitUntil { self.workspace.jobs.allSatisfy(\.isDone) }
        workspace.app.jobQueue.jobs.map(\.id).forEach { self.workspace.perform(.dismissJob($0)) }
        jobsWindow.render(workspace)
        #expect(!jobsWindow.isShown) // all done well: it closed itself
    }

    @Test func aQuestionBringsItForwardAndIsAnsweredThere() async throws {
        FileManager.default.createFile(atPath: root + "/right/a.txt", contents: Data("old".utf8))
        workspace.startJob(.copy([file("a.txt", "new")], into: root + "/right"))
        gate.signal()
        try await waitUntil {
            if case .waiting = self.workspace.jobs.first?.state {
                true
            } else {
                false
            }
        }
        jobsWindow.render(workspace)
        #expect(jobsWindow.isShown) // at once, not after five seconds
        let row = try #require(jobsWindow.shownRows.first)
        let keepBoth = try #require(buttons(row).first { $0.title == "Keep Both" })
        keepBoth.performClick(nil)
        try await waitUntil { self.workspace.jobs.allSatisfy(\.isDone) }
        #expect(FileManager.default.fileExists(atPath: root + "/right/a 2.txt"))
    }

    @Test func closingItCancelsNothingAndWindowJobsShowsItAgain() async throws {
        let id = workspace.startJob(.copy([file("a.txt")], into: root + "/right"))
        clock.advance(6)
        try await waitUntil { self.jobsWindow.isShown }
        jobsWindow.close()
        jobsWindow.render(workspace)
        #expect(!jobsWindow.isShown && workspace.jobs.first { $0.id == id }?.isDone == false)
        jobsWindow.showByUser()
        #expect(jobsWindow.isShown)
    }

    @Test func theWindowMenuHasJobs() throws {
        let menu = try #require(NSApp.mainMenu?.items.first { $0.submenu?.title == "Window" }?.submenu)
        let item = try #require(menu.items.first { $0.title == "Jobs" })
        #expect(item.keyEquivalent == "j" && item.keyEquivalentModifierMask == [.command, .option])
        #expect(item.target is AppDelegate && NSApp.windowsMenu === menu)
    }

    // MARK: Quitting (#112 review: the whole sequence, executed)

    /// Records the quit sequence: the answers it is given, what it asks, what it replies.
    private final class QuitRun {
        var asked: [String] = []
        var steps: [String] = []
    }

    private func quit(answers: (quit: Bool, anyway: Bool), limit: Duration = .seconds(10))
        -> (NSApplication.TerminateReply, QuitRun)
    {
        let run = QuitRun()
        AppDelegate.askToQuit = { run.asked.append("not done: \($0)"); return answers.quit }
        AppDelegate.askToQuitAnyway = { run.asked.append("not stopped: \($0)"); return answers.anyway }
        AppDelegate.stopLimit = limit
        let reply = AppDelegate.quit(workspace, quitting: { run.steps.append("quitting") },
                                     reply: { run.steps.append("reply \($0)") })
        return (reply, run)
    }

    private func resetQuitQuestions() {
        AppDelegate.askToQuit = { _ in false }
        AppDelegate.askToQuitAnyway = { _ in false }
        AppDelegate.stopLimit = .seconds(10)
    }

    @Test func quittingWithoutJobsQuitsAtOnce() {
        defer { resetQuitQuestions() }
        let (reply, run) = quit(answers: (true, true))
        #expect(reply == .terminateNow && run.asked.isEmpty && run.steps == ["quitting"])
    }

    @Test func dontQuitLeavesTheJobsRunning() async throws {
        defer { resetQuitQuestions() }
        let id = workspace.startJob(.copy([file("a.txt")], into: root + "/right"))
        try await waitUntil { self.workspace.jobs.first?.state == .running }
        let (reply, run) = quit(answers: (false, false))
        #expect(reply == .terminateCancel && run.asked == ["not done: 1"] && run.steps.isEmpty)
        #expect(workspace.jobs.first { $0.id == id }?.state == .running) // not cancelled
        gate.signal()
    }

    /// Quit: the jobs are cancelled, and once they stopped the windows are marked as quitting
    /// and the answer is yes. A cleanly cancelled job leaves the list.
    @Test func quitCancelsTheJobsAndQuitsOnceTheyStopped() async throws {
        defer { resetQuitQuestions() }
        workspace.startJob(.copy([file("a.txt")], into: root + "/right"))
        workspace.startJob(.copy([file("b.txt")], into: root + "/right"))
        try await waitUntil { self.workspace.jobs.first?.state == .running }
        let (reply, run) = quit(answers: (true, false))
        #expect(reply == .terminateLater && run.asked == ["not done: 2"] && run.steps.isEmpty)
        gate.signal() // the running one reaches its first check and stops
        try await waitUntil { run.steps == ["quitting", "reply true"] }
        #expect(run.asked == ["not done: 2"]) // all stopped in time: not asked again
        #expect(workspace.jobs.isEmpty) // cancelled cleanly: gone from the list
        #expect((try? FileManager.default.contentsOfDirectory(atPath: root + "/right")) == [])
    }

    /// A job that does not stop in time (here: held before it can see the cancel) is not left
    /// behind unasked: Don't Quit keeps Blitter open, Quit Anyway quits.
    @Test func aJobThatDoesNotStopInTimeIsAskedAbout() async throws {
        defer { resetQuitQuestions() }
        workspace.startJob(.copy([file("a.txt")], into: root + "/right"))
        try await waitUntil { self.workspace.jobs.first?.state == .running }
        let (stayReply, stay) = quit(answers: (true, false), limit: .milliseconds(300))
        #expect(stayReply == .terminateLater)
        try await waitUntil { stay.steps == ["reply false"] }
        #expect(stay.asked == ["not done: 1", "not stopped: 1"]) // no "quitting": the windows stay

        let (_, leave) = quit(answers: (true, true), limit: .milliseconds(300))
        try await waitUntil { leave.steps == ["quitting", "reply true"] }
        #expect(leave.asked == ["not done: 1", "not stopped: 1"])
        gate.signal()
    }

    // MARK: Windows (#112 review)

    /// The window the Jobs window heard from last closes: its buttons and its ticks go through
    /// another open window, so a waiting job can still be cancelled.
    @Test func itKeepsWorkingWhenTheWindowItHeardFromCloses() async throws {
        let other = Workspace(sharingWith: workspace, location: root + "/left")
        workspace.startJob(.copy([file("a.txt")], into: root + "/right"))
        let waiting = workspace.startJob(.copy([file("b.txt")], into: root + "/right"))
        try await waitUntil { self.workspace.canStartJobNow(waiting) }
        weak var closed: Workspace?
        autoreleasepool {
            var last: Workspace? = Workspace(sharingWith: workspace, location: root + "/left")
            closed = last
            jobsWindow.render(try! #require(last)) // swiftlint:disable:this force_try
            last = nil
        }
        #expect(closed == nil)
        clock.advance(6)
        jobsWindow.tick() // through another window
        #expect(jobsWindow.isShown)
        let row = try #require(jobsWindow.shownRows.first { $0.id == waiting })
        try #require(buttons(row).first { $0.title == "Cancel" }).performClick(nil)
        #expect(workspace.jobs.first { $0.id == waiting } == nil) // cancelled, and gone
        _ = other
        gate.signal()
    }
}
