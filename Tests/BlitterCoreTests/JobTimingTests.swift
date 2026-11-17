@testable import BlitterCore
import Foundation
import Synchronization
import Testing

/// #112 step 2: when a job was added, started and last moved, its speed, and Start Now.
@MainActor
@Suite(.serialized)
struct JobTimingTests {
    /// A clock the test sets.
    final class Clock: Sendable {
        private let time = Mutex(Date(timeIntervalSinceReferenceDate: 0))

        var now: Date {
            time.withLock { $0 }
        }

        func advance(_ seconds: TimeInterval) {
            time.withLock { $0 += seconds }
        }
    }

    @Test func aJobKnowsWhenItWasAddedStartedAndLastMoved() async throws {
        let clock = Clock()
        let gate = DispatchSemaphore(value: 0)
        let queue = JobQueue(trash: { _ in nil }, gate: gate, now: { clock.now })
        let id = queue.start(.command(["/usr/bin/true"], folder: "/"), origin: "From automation (test)")
        let job = try #require(queue.jobs.first)
        #expect(job.origin == "From automation (test)" && job.added == clock.now)
        #expect(job.state == .running && job.started == clock.now) // a command: at once
        #expect(job.quietTime(at: clock.now.addingTimeInterval(31)) == 31)

        clock.advance(10)
        queue.progressed(id, JobProgress(totalItems: 1))
        let moved = clock.now
        #expect(queue.jobs.first?.lastProgress == moved)
        #expect(queue.jobs.first?.quietTime(at: moved.addingTimeInterval(5)) == 5)
        clock.advance(3)
        queue.progressed(id, JobProgress(totalItems: 1)) // the same again, later: no progress
        #expect(queue.jobs.first?.lastProgress == moved)
        gate.signal()
        for _ in 0 ..< 300 where queue.jobs.first?.isDone != true {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(queue.jobs.first?.quietTime(at: clock.now) == nil) // done: not quiet, finished
    }

    /// Bytes per second over about the last five seconds, once a second of it is known; a job
    /// that stops slows to 0 as time passes, with no progress reported (#112 review), and is
    /// measured again when it goes on.
    @Test func theSpeedIsAveragedOverTheLastSecondsAndFallsWhenAJobStops() {
        let clock = Clock()
        let gate = DispatchSemaphore(value: 0)
        let queue = JobQueue(trash: { _ in nil }, gate: gate, now: { clock.now })
        let id = queue.start(.command(["/usr/bin/true"], folder: "/"))
        func progress(_ bytes: Int64) {
            var progress = JobProgress()
            progress.doneBytes = bytes
            queue.progressed(id, progress)
        }
        func speed() -> Double? {
            queue.jobs.first?.bytesPerSecond(at: clock.now)
        }
        progress(1)
        #expect(speed() == nil)
        clock.advance(0.5)
        progress(500_001)
        #expect(speed() == nil) // half a second: too little to tell
        clock.advance(1.5)
        progress(4_000_001)
        #expect(speed() == 2_000_000) // 4 MB in 2 s
        clock.advance(4)
        progress(6_000_001) // at t = 1 s (the window's start) 500_001 were done: 5.5 MB in 5 s
        #expect(speed() == 1_100_000)

        // It stops: no more progress is reported, and the speed falls as time passes.
        clock.advance(3)
        #expect(speed() == 400_000) // 2 MB in the window from t = 4 s
        clock.advance(10)
        #expect(speed() == 0)
        // It goes on: measured again from where it stopped.
        clock.advance(1)
        progress(7_000_001)
        #expect(speed() == 200_000) // 1 MB in the 5 s up to t = 20 s
        clock.advance(4)
        progress(9_000_001)
        #expect(speed() == 600_000) // 3 MB in the 5 s up to t = 24 s
        #expect((queue.jobs.first?.samples.count ?? 0) <= 3) // only what the speed can still need
        gate.signal()
    }

    /// Start Now runs a waiting heavy job beside the running one; never one that waits for an
    /// earlier job's paths.
    @Test func startNowRunsAWaitingHeavyJobBesideTheOthers() async throws {
        let gate = DispatchSemaphore(value: 0)
        let fixture = try OperationFixture(gate: gate)
        let first = fixture.file("source/a.txt")
        let second = fixture.file("source/b.txt")
        let one = fixture.queue.start(.copy([first], into: fixture.destination))
        let two = fixture.queue.start(.copy([second], into: fixture.destination))
        let sameItem = fixture.queue.start(.delete([first])) // waits for the copy of a.txt
        for _ in 0 ..< 300 where !fixture.queue.canStartNow(two) {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(fixture.queue.jobs.first { $0.id == one }?.state == .running)
        #expect(fixture.queue.canStartNow(two) && !fixture.queue.canStartNow(sameItem))
        #expect(!fixture.queue.canStartNow(one)) // already running
        fixture.queue.startNow(sameItem) // refused
        #expect(fixture.queue.jobs.first { $0.id == sameItem }?.state == .queued)
        fixture.queue.startNow(two)
        #expect(fixture.queue.jobs.first { $0.id == two }?.state == .running)
        for _ in 0 ..< 3 {
            gate.signal()
        }
        for _ in 0 ..< 300 where !fixture.queue.jobs.allSatisfy(\.isDone) {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(fixture.names("destination") == ["a.txt", "b.txt"] && !fixture.exists("source/a.txt"))
    }
}
