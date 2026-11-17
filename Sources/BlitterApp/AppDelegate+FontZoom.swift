import AppKit
import BlitterModel

/// The lists' font size (#63): the View menu's zoom items; and quitting: jobs not done (#112),
/// and saving a zoomed size.
extension AppDelegate {
    @objc func zoomIn(_: Any?) {
        workspace.perform(.zoomFont(.larger))
    }

    @objc func zoomOut(_: Any?) {
        workspace.perform(.zoomFont(.smaller))
    }

    @objc func actualSize(_: Any?) {
        workspace.perform(.zoomFont(.actualSize))
    }

    /// Jobs not done (#112) are not left behind silently: Blitter asks, and on Quit cancels them
    /// and waits for them to stop (a partial copy is removed) — nothing resumes at the next launch.
    /// A zoomed font size still waiting to be saved (#63), or the Settings window's save (#64),
    /// is written first. The main thread stays free meanwhile; a save that hangs (a stalled
    /// network home) is given up after a few seconds.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        Self.quit(workspace, quitting: { [windows] in windows.isQuitting = true },
                  reply: { sender.reply(toApplicationShouldTerminate: $0) })
    }

    /// The questions on quit (#112); tests answer them.
    static var askToQuit: @MainActor (_ notDone: Int) -> Bool = quitAnyway
    static var askToQuitAnyway: @MainActor (_ notStopped: Int) -> Bool = quitThoughNotStopped
    /// How long jobs may take to stop before Blitter asks again.
    static var stopLimit: Duration = .seconds(10)

    /// Quitting, step by step: with jobs not done, ask; on Quit, cancel them and wait for them to
    /// stop — and if some have not stopped by `stopLimit` (a batch rename finishing, a copy on a
    /// volume that hangs), ask again rather than leave half-done files behind unasked. Then the
    /// settings' saves. `quitting` marks the windows as quitting once it is decided.
    static func quit(_ workspace: Workspace, quitting: @escaping @MainActor () -> Void,
                     reply: @escaping @MainActor (Bool) -> Void) -> NSApplication.TerminateReply
    {
        let notDone = workspace.jobs.filter { !$0.isDone }.count
        if notDone > 0, !askToQuit(notDone) {
            return .terminateCancel
        }
        guard notDone > 0 || workspace.isSavingSettings else {
            quitting()
            return .terminateNow
        }
        cancelJobs(workspace) { stopped in
            let notStopped = workspace.jobs.filter { !$0.isDone }.count
            guard stopped || askToQuitAnyway(notStopped) else {
                reply(false) // stays open; the jobs go on stopping
                return
            }
            quitting() // every window open now opens again at the next launch (#96)
            finishSaving(workspace) {
                reply(true)
            }
        }
        return .terminateLater
    }

    /// "3 jobs are not done": Quit and Cancel Them, or Don't Quit.
    private static func quitAnyway(_ count: Int) -> Bool {
        let alert = NSAlert()
        alert.messageText = count == 1 ? "1 job is not done." : "\(count) jobs are not done."
        alert.informativeText = "Quitting cancels them. What they have finished stays; a file being copied is removed."
        alert.addButton(withTitle: "Quit and Cancel Them")
        alert.addButton(withTitle: "Don't Quit")
        return alert.runModal() == .alertFirstButtonReturn
    }

    /// Jobs that did not stop in time: Quit Anyway, or Don't Quit.
    private static func quitThoughNotStopped(_ count: Int) -> Bool {
        let alert = NSAlert()
        alert.messageText = count == 1 ? "1 job has not stopped yet." : "\(count) jobs have not stopped yet."
        alert.informativeText = "It may be finishing a step that cannot be broken off, or waiting for a volume "
            + "that does not answer. Quitting now can leave files half done."
        alert.addButton(withTitle: "Don't Quit")
        alert.addButton(withTitle: "Quit Anyway")
        return alert.runModal() == .alertSecondButtonReturn
    }

    /// Cancels every job not done and calls `done` once they have stopped (true), or after
    /// `stopLimit` (false).
    static func cancelJobs(_ workspace: Workspace, done: @escaping @MainActor (Bool) -> Void) {
        for job in workspace.jobs where !job.isDone {
            workspace.perform(.cancelJob(job.id))
        }
        let limit = stopLimit
        Task {
            let clock = ContinuousClock()
            let end = clock.now + limit
            while workspace.jobs.contains(where: { !$0.isDone }), clock.now < end {
                try? await Task.sleep(for: .milliseconds(100))
            }
            done(!workspace.jobs.contains { !$0.isDone })
        }
    }

    /// Waits for the workspace's pending saves, at most `limit`, then calls `done` once. The
    /// save and the limit race as two separate tasks: a save stuck on a stalled disk is left
    /// behind, not waited for.
    static func finishSaving(_ workspace: Workspace, limit: Duration = .seconds(3), done: @escaping () -> Void) {
        var isDone = false
        let finish = {
            if !isDone {
                isDone = true
                done()
            }
        }
        Task {
            await workspace.finishSaving()
            finish()
        }
        Task {
            try? await Task.sleep(for: limit)
            finish()
        }
    }
}
