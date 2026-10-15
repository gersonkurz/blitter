import Dispatch
import Synchronization

/// Loads one value per path in the background, e.g. an icon that needs a disk read, and caches it.
///
/// Each instance has its own serial queue, so a lookup stuck on a slow volume delays only the
/// lookups of that instance (one per side), never the other side. `cancelAll()` drops every
/// request that has not started yet; a lookup already running cannot be interrupted, but its
/// result is discarded.
@MainActor
public final class PathLoader<Value: Sendable> {
    public typealias Lookup = @Sendable (String) -> Value

    private let lookup: Lookup
    private let queue: DispatchQueue
    private let maxCached: Int
    private let generation = Generation()
    private var cache: [String: Value] = [:]
    /// Paths requested in the current generation, with the callbacks to run when they are loaded.
    private var pending: [String: [() -> Void]] = [:]

    public init(label: String, maxCached: Int = 10000, lookup: @escaping Lookup) {
        self.lookup = lookup
        self.maxCached = maxCached
        queue = DispatchQueue(label: label, qos: .utility)
    }

    /// The cached value for `path`. If there is none yet, starts loading it and returns nil;
    /// `onLoaded` then runs on the main actor once the value is in the cache.
    public func value(for path: String, onLoaded: @escaping () -> Void) -> Value? {
        if let value = cache[path] {
            return value
        }
        if pending[path] != nil {
            pending[path]?.append(onLoaded)
            return nil
        }
        pending[path] = [onLoaded]
        let requested = generation.current
        queue.async { [lookup, generation] in
            guard generation.current == requested else {
                return
            }
            let value = lookup(path)
            Task { @MainActor [weak self] in
                self?.finish(path, value, requested)
            }
        }
        return nil
    }

    /// Drops all requests that have not been loaded yet. Their callbacks never run.
    public func cancelAll() {
        generation.advance()
        pending.removeAll()
    }

    private func finish(_ path: String, _ value: Value, _ requested: Int) {
        guard requested == generation.current else {
            return
        }
        if cache.count >= maxCached {
            cache.removeAll()
        }
        cache[path] = value
        for callback in pending.removeValue(forKey: path) ?? [] {
            callback()
        }
    }
}

/// Counter the background queue reads to skip requests cancelled after they were queued.
private final class Generation: Sendable {
    private let value = Atomic(0)

    var current: Int {
        value.load(ordering: .acquiring)
    }

    func advance() {
        value.add(1, ordering: .releasing)
    }
}
