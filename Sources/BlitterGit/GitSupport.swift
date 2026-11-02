import BlitterCore
import BlitterModel
import Foundation

/// Why something git was asked for could not be done: a version not shown, a commit not prepared.
struct GitFailure: Error {
    let message: String
}

/// Copies of file versions for the diff tool (#42, #44). Each comparison gets a folder of its
/// own, `<temporary>/Blitter-Git/<unique>/`: two files of the same name, or a later comparison,
/// never write over files a diff tool still shows.
enum CompareCopies {
    static func newFolder() -> String {
        NSTemporaryDirectory() + "Blitter-Git/" + UUID().uuidString
    }

    /// Writes `data` as `<folder>/<label>/<name>` and returns its path.
    static func write(_ data: Data, name: String, label: String, in folder: String) -> Result<String, GitFailure> {
        let subfolder = folder + "/" + label
        do {
            try FileManager.default.createDirectory(atPath: subfolder, withIntermediateDirectories: true)
            try data.write(to: URL(fileURLWithPath: subfolder + "/" + name))
            return .success(subfolder + "/" + name)
        } catch {
            return .failure(GitFailure(message: "A copy to compare could not be written: "
                    + error.localizedDescription))
        }
    }
}

extension Workspace {
    /// Starts a command job (in the jobs strip, with Cancel); its id, nil if none started.
    func startCommand(_ arguments: [String], in folder: String) -> Int? {
        let known = Set(jobs.map(\.id))
        perform(.runCommand(arguments, folder: folder))
        return jobs.last { !known.contains($0.id) && $0.operation == .command(arguments, folder: folder) }?.id
    }
}

/// Work off the main actor, by key: a newer piece of work under a key cancels the older one
/// (and its git, through the flag), and only the newest one's result is applied.
@MainActor
final class BackgroundWork {
    private var tasks: [String: Task<Void, Never>] = [:]

    var isEmpty: Bool {
        tasks.isEmpty
    }

    /// Runs `body` off the main actor under `key`, then `apply` on the main actor.
    func run<Result: Sendable>(_ key: String, _ body: @escaping @Sendable (CancellationFlag) -> Result,
                               then apply: @escaping @MainActor (Result) -> Void)
    {
        tasks[key]?.cancel()
        tasks[key] = Task { [weak self] in
            let cancelled = CancellationFlag()
            let worker = Task.detached(priority: .userInitiated) { body(cancelled) }
            let result = await withTaskCancellationHandler {
                await worker.value
            } onCancel: {
                cancelled.set()
            }
            guard !Task.isCancelled, let self else {
                return
            }
            tasks[key] = nil
            apply(result)
        }
    }

    func cancel(_ key: String) {
        tasks.removeValue(forKey: key)?.cancel()
    }
}
