import Foundation

/// Runs file operations in the background, each on its own thread once it is its turn (#112):
/// heavy jobs (copying, deleting for good, undo, a move to another volume) one after the other,
/// quick ones (rename, new folder, the Trash, a move on one volume, a command line) at once —
/// except that no job starts while an earlier unfinished one uses its paths (as the file system
/// names them: through links, in any case), so renaming an item a waiting copy will read, or one
/// it will make, waits for that copy. A waiting job has no thread yet. The queue lives
/// on the main actor; jobs report progress at most ten times a second.
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
    private let rename: FileOperations.Renamer
    private let copyDetails: FileOperations.DetailsCopier
    private var runners: [Int: JobRunner] = [:]
    private var nextID = 1
    /// Every job not done yet, by id: what it uses and how it takes its turn (#112).
    private var turns: [Int: Turn] = [:]
    /// How long a copy runs before its total size is measured beside it (#112).
    private let estimateDelay: Double
    /// Resolves a job's paths off the main thread (tests stall it).
    private let resolve: @Sendable (PathUse) -> PathUse
    /// How long a job's paths may take to resolve before it counts as stalled (#112), seconds.
    private let stallDelay: Double
    /// The clock (tests set it).
    let now: @Sendable () -> Date

    public init() {
        trash = FileOperations.moveToTrash
        remove = FileOperations.removeForGood
        simulateOtherVolume = false
        gate = nil
        sizingProbe = nil
        rename = FileOperations.renameExclusive
        copyDetails = FileOperations.copyFolderDetails
        estimateDelay = 5
        resolve = { $0.resolved() }
        stallDelay = 2
        now = { Date() }
    }

    /// For tests: a Trash of their own, a remover that can fail, the paths used between volumes on
    /// one volume, a gate every job waits at before it starts, and a probe on every folder a size
    /// scan reads.
    init(
        trash: @escaping FileOperations.Trasher,
        remove: @escaping FileOperations.Remover = FileOperations.removeForGood,
        simulateOtherVolume: Bool = false,
        gate: DispatchSemaphore? = nil,
        sizingProbe: (@Sendable (CancellationFlag) -> Void)? = nil,
        rename: @escaping FileOperations.Renamer = FileOperations.renameExclusive,
        copyDetails: @escaping FileOperations.DetailsCopier = FileOperations.copyFolderDetails,
        estimateDelay: Double = 5,
        resolve: @escaping @Sendable (PathUse) -> PathUse = { $0.resolved() },
        stallDelay: Double = 2,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.now = now
        self.estimateDelay = estimateDelay
        self.resolve = resolve
        self.stallDelay = stallDelay
        self.rename = rename
        self.copyDetails = copyDetails
        self.trash = trash
        self.remove = remove
        self.simulateOtherVolume = simulateOtherVolume
        self.gate = gate
        self.sizingProbe = sizingProbe
    }

    /// Adds the job; it starts as soon as its paths are known (a moment later) if it may — see
    /// the type's description — else it waits. `origin`: who started it, for the Jobs window.
    @discardableResult
    public func start(_ operation: FileOperation, origin: String? = nil) -> Int {
        let id = nextID
        nextID += 1
        jobs.append(Job(id: id, operation: operation, origin: origin, added: now()))
        let turn = Turn(operation)
        turns[id] = turn
        guard !turn.isReady else { // a command line: nothing to resolve
            schedule()
            onChange?()
            return id
        }
        // The paths it uses, as the file system names them, and for a move whether it stays on
        // one volume (heavy unless it does): both take the disk, so they are found off the main
        // thread. Meanwhile others compare with its paths as given.
        DispatchQueue.main.asyncAfter(deadline: .now() + stallDelay) {
            MainActor.assumeIsolated { [weak self] in
                guard let self, turns[id]?.resolved == nil, turns[id] != nil else {
                    return
                }
                turns[id]?.stalled = true // later jobs go by its paths as given now
                schedule()
                onChange?()
            }
        }
        let resolve = resolve
        DispatchQueue.global(qos: .userInitiated).async {
            let uses = resolve(PathUse(operation))
            var heavy: Bool?
            if case let .move(sources, folder) = operation {
                heavy = !FileOperations.isOnVolume(of: folder, sources)
            }
            DispatchQueue.main.async {
                MainActor.assumeIsolated { [weak self] in
                    self?.resolved(id, uses: uses, heavy: heavy)
                }
            }
        }
        onChange?()
        return id
    }

    private func resolved(_ id: Int, uses: PathUse, heavy: Bool?) {
        guard turns[id] != nil else {
            return // cancelled meanwhile
        }
        turns[id]?.resolved = uses
        if let heavy {
            turns[id]?.kind = heavy ? .heavy : .quick
        }
        schedule()
        onChange?()
    }

    /// Starts every waiting job whose turn it is, in the order they were added.
    private func schedule() {
        let ids = turns.keys.sorted()
        for (index, id) in ids.enumerated() {
            guard let turn = turns[id], !turn.started, turn.isReady else {
                continue
            }
            let earlier = ids[..<index].compactMap { turns[$0] }
            if earlier.contains(where: { $0.blocks(turn) }) {
                continue // an earlier job uses its paths
            }
            if turn.kind == .heavy, !turn.startsNow, earlier.contains(where: { $0.kind != .quick })
                || turns.values.contains(where: { $0.started && $0.kind == .heavy })
            {
                continue // heavy jobs one after the other, unless the user said Start Now
            }
            launch(id, turn.operation)
        }
    }

    /// Whether Start Now can run the waiting job beside the others (#112): it waits only because
    /// heavy jobs take turns — never when an earlier job uses its paths, or they are not known.
    public func canStartNow(_ id: Int) -> Bool {
        guard let turn = turns[id], !turn.started, turn.isReady else {
            return false
        }
        return !turns.contains { $0.key < id && $0.value.blocks(turn) }
    }

    /// Start Now: the waiting job runs beside the others, if it can.
    public func startNow(_ id: Int) {
        guard canStartNow(id) else {
            return
        }
        turns[id]?.startsNow = true
        schedule()
        onChange?()
    }

    private func launch(_ id: Int, _ operation: FileOperation) {
        turns[id]?.started = true
        if let index = jobs.firstIndex(where: { $0.id == id }) {
            jobs[index].state = .running
            jobs[index].started = now()
        }
        let runner = JobRunner(id: id, queue: self)
        runners[id] = runner
        let trash = trash
        let remove = remove
        let simulateOtherVolume = simulateOtherVolume
        let gate = gate
        let sizingProbe = sizingProbe
        let rename = rename
        let copyDetails = copyDetails
        let estimateDelay = estimateDelay
        DispatchQueue.global(qos: .userInitiated).async {
            gate?.wait()
            var operations = FileOperations(context: runner, trash: trash, remove: remove,
                                            simulateOtherVolume: simulateOtherVolume, sizingProbe: sizingProbe,
                                            rename: rename, copyDetails: copyDetails, estimateDelay: estimateDelay)
            // On the job's thread: finding what lies inside what looks at the disk (#48).
            let errors = operations.run(operation.withoutNestedItems())
            runner.finish(errors, undo: operations.undoSteps.reversed(), identityChanges: operations.identityChanges)
        }
    }

    /// Stops the job between items, or in the middle of copying a file. What was finished stays;
    /// a partial copy is removed. A job still waiting for its turn ends at once, having done
    /// nothing.
    public func cancel(_ id: Int) {
        guard let turn = turns[id], !turn.started else {
            runners[id]?.cancel()
            return
        }
        update(id) { $0.state = .cancelled }
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

    /// A running job's progress (at most ten times a second): what it has done, when it last
    /// moved, and a sample for its speed — one change, so every window is told once.
    func progressed(_ id: Int, _ progress: JobProgress) {
        let time = now()
        update(id) { job in
            guard !job.isDone, job.progress != progress else {
                return
            }
            job.progress = progress
            job.lastProgress = time
            job.record(ProgressSample(time: time, bytes: progress.doneBytes))
        }
    }

    fileprivate func update(_ id: Int, _ change: (inout Job) -> Void) {
        guard let index = jobs.firstIndex(where: { $0.id == id }) else {
            return
        }
        let wasDone = jobs[index].isDone
        change(&jobs[index])
        if jobs[index].isDone, !wasDone {
            runners[id] = nil
            turns[id] = nil
            onFinish?(jobs[index])
            schedule() // its turn is over
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
    /// Guarded by `lock`.
    private var cancelled = false
    /// The job runs to the end now (`commit`): Cancel no longer applies.
    private var committed = false
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
            queue?.progressed(id, progress)
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
        let wakeUp = lock.withLock { () -> Bool in
            guard !committed else {
                return false // it finishes anyway
            }
            cancellation.set()
            defer { cancelled = true }
            return !cancelled && isWaiting && pendingAnswer == nil
        }
        if wakeUp {
            answered.signal() // the job waits for an answer it will not get
        }
    }

    func commit() -> Bool {
        lock.withLock {
            guard !cancellation.isSet else {
                return false
            }
            committed = true
            return true
        }
    }

    func finish(_ errors: [JobError], undo: [UndoStep], identityChanges: [ItemIdentity: ItemIdentity]) {
        // The flag is what the operation obeyed, so it decides whether the job counts as cancelled.
        let cancelled = cancellation.isSet
        let progress = lock.withLock { self.progress }
        post { job in
            job.progress = progress
            job.errors = errors
            job.undo = undo
            job.identityChanges = identityChanges
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
