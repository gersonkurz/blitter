import Foundation

/// A file operation in the job queue, as the UI and the model see it.
public struct Job: Identifiable, Equatable, Sendable {
    public enum State: Equatable, Sendable {
        /// Waiting for its turn (#112): a heavy job behind another, or a job behind an earlier
        /// one that uses its paths.
        case queued
        case running
        /// Stopped until the conflict is answered with `JobQueue.answer`.
        case waiting(Conflict)
        /// Done; `errors` lists what could not be done.
        case finished
        case cancelled
    }

    public let id: Int
    public let operation: FileOperation
    /// Who started it, as the Jobs window says (#112): nil for the user in the only window.
    public let origin: String?
    /// When it was added, started, and last made progress (#112).
    public let added: Date
    public internal(set) var started: Date?
    public internal(set) var lastProgress: Date?
    /// Recent progress (time, bytes done) for the speed (#112): those in the last
    /// `speedWindow`, and the last one before it.
    var samples: [ProgressSample] = []
    public internal(set) var state: State = .queued
    public internal(set) var progress = JobProgress()
    public internal(set) var errors: [JobError] = []
    /// How to undo what the job did (#61), in the order to run: set when it is done. Empty if
    /// nothing it did can be undone (a delete for good, a command line, nothing done).
    public internal(set) var undo: [UndoStep] = []
    /// Items the job moved to another volume are other items there (copies): their old
    /// identities and their new ones, so older undo steps still find them (#61).
    public internal(set) var identityChanges: [ItemIdentity: ItemIdentity] = [:]

    public var isDone: Bool {
        state == .finished || state == .cancelled
    }

    init(id: Int, operation: FileOperation, origin: String? = nil, added: Date = Date()) {
        self.id = id
        self.operation = operation
        self.origin = origin
        self.added = added
    }

    /// How long a running job has made no progress (#112): seconds since it started or last
    /// reported progress; nil unless it runs (a job asking a question waits for the user).
    public func quietTime(at now: Date) -> TimeInterval? {
        guard state == .running, let since = lastProgress ?? started else {
            return nil
        }
        return now.timeIntervalSince(since)
    }

    /// No progress for this long marks a running job in the Jobs window (#112).
    public static let quietThreshold: TimeInterval = 30

    /// The span the speed is averaged over (#112).
    public static let speedWindow: TimeInterval = 5

    /// Bytes per second over the last `speedWindow` seconds before `now` (#112), or since the
    /// first sample if that is later. A sample is recorded only when progress changes, so what was
    /// done when the span began is the last sample before it — a job that stops slows to 0 as time
    /// passes, and one that goes on is measured again. Nil while less than a second can be told.
    public func bytesPerSecond(at now: Date) -> Double? {
        guard let last = samples.last else {
            return nil
        }
        let start = now.addingTimeInterval(-Self.speedWindow)
        let base = samples.last { $0.time <= start } ?? samples[0]
        let span = now.timeIntervalSince(max(base.time, start))
        guard span >= 1 else {
            return nil
        }
        return Double(last.bytes - base.bytes) / span
    }

    /// Adds a sample and keeps what the speed can still need.
    mutating func record(_ sample: ProgressSample) {
        samples.append(sample)
        let start = sample.time.addingTimeInterval(-Self.speedWindow)
        if let before = samples.lastIndex(where: { $0.time <= start }), before > 0 {
            samples.removeFirst(before) // keep the last one before the window as the base
        }
    }
}

/// A job's bytes done at a moment (#112).
struct ProgressSample: Equatable, Sendable {
    let time: Date
    let bytes: Int64
}
