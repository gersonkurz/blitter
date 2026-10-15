@testable import BlitterCore
import Foundation
import Synchronization
import Testing

/// A lookup that blocks until released, like a read stuck on a slow network volume.
private final class StalledLookup: Sendable {
    private let gate = DispatchSemaphore(value: 0)
    private let calls = Mutex<[String]>([])

    var paths: [String] {
        calls.withLock { $0 }
    }

    func lookup(_ path: String) -> String {
        calls.withLock { $0.append(path) }
        gate.wait()
        return "stalled " + path
    }

    func release(_ count: Int = 1) {
        for _ in 0 ..< count {
            gate.signal()
        }
    }
}

@MainActor
struct PathLoaderTests {
    /// Waits until `onLoaded` has run, or fails after a timeout.
    private func load(_ loader: PathLoader<String>, _ path: String) async -> String? {
        await withCheckedContinuation { continuation in
            var resumed = false
            let resume = {
                if !resumed {
                    resumed = true
                    continuation.resume()
                }
            }
            if loader.value(for: path, onLoaded: resume) != nil {
                resume()
            }
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(5))
                resume()
            }
        }
        return loader.value(for: path) {}
    }

    @Test func loadsInTheBackgroundAndCaches() async {
        let calls = Mutex(0)
        let loader = PathLoader<String>(label: "test") { path in
            calls.withLock { $0 += 1 }
            return "icon " + path
        }
        #expect(await load(loader, "/a") == "icon /a")
        #expect(loader.value(for: "/a") {} == "icon /a")
        #expect(calls.withLock { $0 } == 1)
    }

    @Test func aStalledLoaderDoesNotBlockAnotherOne() async {
        let stalled = StalledLookup()
        let left = PathLoader<String>(label: "left", lookup: stalled.lookup)
        let right = PathLoader<String>(label: "right") { "icon " + $0 }

        #expect(left.value(for: "/network/app") {} == nil)
        #expect(await load(right, "/local/app") == "icon /local/app")
        #expect(left.value(for: "/network/app") {} == nil) // still stuck
        stalled.release()
    }

    @Test func cancelAllDropsQueuedRequestsAndRunningResults() async throws {
        let stalled = StalledLookup()
        let loader = PathLoader<String>(label: "test", lookup: stalled.lookup)
        var callbacks = 0
        _ = loader.value(for: "/running") { callbacks += 1 }
        _ = loader.value(for: "/queued") { callbacks += 1 }
        try await Task.sleep(for: .milliseconds(100)) // "/running" is now inside the lookup

        loader.cancelAll()
        stalled.release(2)
        try await Task.sleep(for: .milliseconds(200))

        #expect(stalled.paths == ["/running"]) // "/queued" never started
        #expect(callbacks == 0)

        // A new request after cancelling loads again.
        stalled.release()
        #expect(await load(loader, "/running") == "stalled /running")
    }
}
