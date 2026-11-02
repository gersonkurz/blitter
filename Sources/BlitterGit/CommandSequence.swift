import BlitterCore
import BlitterModel
import Foundation

/// Command lines run one after another in a folder, each as a job (in the jobs strip, with
/// Cancel); the next starts only when the one before succeeded (#43, #44). Their output, all
/// steps together, is followed while they run.
@MainActor
final class CommandSequence {
    enum Ending: Equatable {
        case succeeded
        /// The step (an index into the command lines) that failed, and why.
        case failed(step: Int, message: String)
        case cancelled(step: Int)
    }

    /// The step running now, and its job.
    private(set) var running: (step: Int, job: Int)?
    private(set) var output = ""
    /// Called whenever `output` or `running` changes while it runs; the end goes to `start`'s handler.
    var onChange: (() -> Void)?

    private let workspace: Workspace
    private let folder: String
    private var steps: [[String]] = []
    private var finished: ((Ending) -> Void)?
    /// The output of the steps that ended.
    private var earlierOutput = ""
    private var watching: Task<Void, Never>?

    init(workspace: Workspace, folder: String) {
        self.workspace = workspace
        self.folder = folder
    }

    /// Starts the first command line; false (and nothing started) if one is running already or
    /// its job did not start.
    func start(_ steps: [[String]], then finished: @escaping (Ending) -> Void) -> Bool {
        guard running == nil, !steps.isEmpty else {
            return false
        }
        self.steps = steps
        earlierOutput = ""
        output = ""
        guard startStep(0) else {
            return false
        }
        self.finished = finished
        return true
    }

    func cancel() {
        running.map { workspace.perform(.cancelJob($0.job)) }
    }

    private func startStep(_ step: Int) -> Bool {
        guard let job = workspace.startCommand(steps[step], in: folder) else {
            running = nil
            return false
        }
        running = (step, job)
        // A job that succeeded leaves the list at once: its end, last output included, comes
        // from the workspace. Held strongly: the steps go on, and `finished` is called, even
        // when whoever started them is gone (#44 review).
        workspace.whenJobDone(job) { job in
            self.ended(job, step: step)
        }
        watch(job)
        return true
    }

    private func ended(_ job: Job, step: Int) {
        guard running?.job == job.id else {
            return
        }
        output = earlierOutput + job.progress.output
        earlierOutput = output
        let ending: Ending? = switch job.state {
        case .cancelled: .cancelled(step: step)
        default: job.errors.first.map { .failed(step: step, message: $0.message) }
        }
        guard ending == nil, step + 1 < steps.count else {
            finish(ending ?? .succeeded)
            return
        }
        if startStep(step + 1) {
            onChange?()
        } else {
            finish(.failed(step: step + 1, message: "It could not be started."))
        }
    }

    private func finish(_ ending: Ending) {
        running = nil
        watching?.cancel()
        watching = nil
        let finished = finished
        self.finished = nil
        finished?(ending)
    }

    /// Follows the job's output while it runs (the jobs strip shows its progress too).
    private func watch(_ id: Int) {
        watching?.cancel()
        watching = Task { [weak self] in
            while !Task.isCancelled {
                guard let self, running?.job == id else {
                    return
                }
                if let job = workspace.jobs.first(where: { $0.id == id }),
                   earlierOutput + job.progress.output != output
                {
                    output = earlierOutput + job.progress.output
                    onChange?()
                }
                try? await Task.sleep(for: .milliseconds(200))
            }
        }
    }
}
