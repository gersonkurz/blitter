import Foundation

/// A file operation in the job queue, as the UI and the model see it.
public struct Job: Identifiable, Equatable, Sendable {
    public enum State: Equatable, Sendable {
        case running
        /// Stopped until the conflict is answered with `JobQueue.answer`.
        case waiting(Conflict)
        /// Done; `errors` lists what could not be done.
        case finished
        case cancelled
    }

    public let id: Int
    public let operation: FileOperation
    public internal(set) var state: State = .running
    public internal(set) var progress = JobProgress()
    public internal(set) var errors: [JobError] = []

    public var isDone: Bool {
        state == .finished || state == .cancelled
    }
}

/// Runs file operations in the background, each on its own thread, so a slow volume holds up
/// only its own job. The queue lives on the main actor; jobs report progress at most ten times a
/// second.
@MainActor
public final class JobQueue {
    public private(set) var jobs: [Job] = []
    /// Called after every change of `jobs`.
    public var onChange: (() -> Void)?
    /// Called when a job is done, e.g. to read the affected folders again.
    public var onFinish: ((Job) -> Void)?

    private let trash: FileOperations.Trasher
    private let remove: FileOperations.Remover
    private let simulateOtherVolume: Bool
    /// Tests hold jobs here before they touch the disk, e.g. to cancel them first.
    private let gate: DispatchSemaphore?
    private let sizingProbe: (@Sendable (CancellationFlag) -> Void)?
    private var runners: [Int: JobRunner] = [:]
    private var nextID = 1

    public init() {
        trash = FileOperations.moveToTrash
        remove = FileOperations.removeForGood
        simulateOtherVolume = false
        gate = nil
        sizingProbe = nil
    }

    /// For tests: a Trash of their own, a remover that can fail, the paths used between volumes on
    /// one volume, a gate every job waits at before it starts, and a probe on every folder a size
    /// scan reads.
    init(
        trash: @escaping FileOperations.Trasher,
        remove: @escaping FileOperations.Remover = FileOperations.removeForGood,
        simulateOtherVolume: Bool = false,
        gate: DispatchSemaphore? = nil,
        sizingProbe: (@Sendable (CancellationFlag) -> Void)? = nil
    ) {
        self.trash = trash
        self.remove = remove
        self.simulateOtherVolume = simulateOtherVolume
        self.gate = gate
        self.sizingProbe = sizingProbe
    }

    @discardableResult
    public func start(_ operation: FileOperation) -> Int {
        let id = nextID
        nextID += 1
        jobs.append(Job(id: id, operation: operation))
        let runner = JobRunner(id: id, queue: self)
        runners[id] = runner
        let trash = trash
        let remove = remove
        let simulateOtherVolume = simulateOtherVolume
        let gate = gate
        let sizingProbe = sizingProbe
        DispatchQueue.global(qos: .userInitiated).async {
            gate?.wait()
            var operations = FileOperations(context: runner, trash: trash, remove: remove,
                                            simulateOtherVolume: simulateOtherVolume, sizingProbe: sizingProbe)
            let errors = operations.run(operation)
            runner.finish(errors)
        }
        onChange?()
        return id
    }

    /// Stops the job between items, or in the middle of copying a file. What was finished stays;
    /// a partial copy is removed.
    public func cancel(_ id: Int) {
        runners[id]?.cancel()
    }

    public func answer(_ id: Int, _ answer: ConflictAnswer) {
        runners[id]?.answer(answer)
    }

    /// Removes a job that is done from the list.
    public func dismiss(_ id: Int) {
        guard let index = jobs.firstIndex(where: { $0.id == id }), jobs[index].isDone else {
            return
        }
        jobs.remove(at: index)
        onChange?()
    }

    // MARK: From the runners

    fileprivate func update(_ id: Int, _ change: (inout Job) -> Void) {
        guard let index = jobs.firstIndex(where: { $0.id == id }) else {
            return
        }
        let wasDone = jobs[index].isDone
        change(&jobs[index])
        if jobs[index].isDone, !wasDone {
            runners[id] = nil
            onFinish?(jobs[index])
        }
        onChange?()
    }
}

/// The bridge between a job's thread and the queue: thread-safe progress, cancellation and the
/// conflict hand-off.
private final class JobRunner: OperationContext, @unchecked Sendable {
    let id: Int
    private weak var queue: JobQueue?
    private let lock = NSLock()
    let cancellation = CancellationFlag()
    // Guarded by `lock`.
    private var cancelled = false
    private var progress = JobProgress()
    private var publishScheduled = false
    private var isWaiting = false
    private var pendingAnswer: ConflictAnswer?
    private let answered = DispatchSemaphore(value: 0)

    init(id: Int, queue: JobQueue) {
        self.id = id
        self.queue = queue
    }

    func update(_ change: (inout JobProgress) -> Void) {
        let schedule = lock.withLock { () -> Bool in
            change(&progress)
            defer { publishScheduled = true }
            return !publishScheduled
        }
        if schedule {
            // At most ten progress updates a second reach the main actor.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [self] in publishProgress() }
        }
    }

    private func publishProgress() {
        let progress = lock.withLock {
            publishScheduled = false
            return self.progress
        }
        MainActor.assumeIsolated {
            queue?.update(id) { job in
                if !job.isDone {
                    job.progress = progress
                }
            }
        }
    }

    func ask(_ conflict: Conflict) -> ConflictAnswer? {
        let mayWait = lock.withLock { () -> Bool in
            guard !cancelled else {
                return false
            }
            isWaiting = true
            return true
        }
        guard mayWait else {
            return nil
        }
        post { $0.state = .waiting(conflict) }
        answered.wait()
        return lock.withLock {
            defer {
                pendingAnswer = nil
                isWaiting = false
            }
            return cancelled ? nil : pendingAnswer
        }
    }

    func answer(_ answer: ConflictAnswer) {
        let wasWaiting = lock.withLock { () -> Bool in
            // Only the question being asked can be answered; anything else is ignored.
            guard isWaiting, pendingAnswer == nil, !cancelled else {
                return false
            }
            pendingAnswer = answer
            return true
        }
        if wasWaiting {
            post { $0.state = .running }
            answered.signal()
        }
    }

    func cancel() {
        cancellation.set()
        let wakeUp = lock.withLock { () -> Bool in
            defer { cancelled = true }
            return !cancelled && isWaiting && pendingAnswer == nil
        }
        if wakeUp {
            answered.signal() // the job waits for an answer it will not get
        }
    }

    func finish(_ errors: [JobError]) {
        // The flag is what the operation obeyed, so it decides whether the job counts as cancelled.
        let cancelled = cancellation.isSet
        let progress = lock.withLock { self.progress }
        post { job in
            job.progress = progress
            job.errors = errors
            job.state = cancelled ? .cancelled : .finished
        }
    }

    private func post(_ change: @escaping @Sendable (inout Job) -> Void) {
        DispatchQueue.main.async { [self] in
            MainActor.assumeIsolated {
                queue?.update(id, change)
            }
        }
    }
}
