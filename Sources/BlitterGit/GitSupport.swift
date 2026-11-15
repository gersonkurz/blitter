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
        write(data, at: name, in: folder + "/" + label)
    }

    /// Writes `data` at `path` (relative, as git names a file in the working copy) below
    /// `folder`, making the folders on the way (#89). A path that would lead out of `folder`
    /// (`..`, absolute) is refused.
    static func write(_ data: Data, at path: String, in folder: String) -> Result<String, GitFailure> {
        let parts = path.split(separator: "/", omittingEmptySubsequences: false)
        guard !path.hasPrefix("/"), !parts.isEmpty, !parts.contains(where: { $0.isEmpty || $0 == "." || $0 == ".." })
        else {
            return .failure(GitFailure(message: "“\(path)” is not a path inside the working copy."))
        }
        let target = folder + "/" + path
        if case let .failure(failure) = makeFolder((target as NSString).deletingLastPathComponent) {
            return .failure(failure)
        }
        do {
            // Never over another copy: two names that are one on disk fail, not lose a file (#89 review).
            try data.write(to: URL(fileURLWithPath: target), options: .withoutOverwriting)
            return .success(target)
        } catch {
            return .failure(GitFailure(message: "A copy to compare could not be written: "
                    + error.localizedDescription))
        }
    }

    static func makeFolder(_ path: String) -> Result<Void, GitFailure> {
        do {
            try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
            return .success(())
        } catch {
            return .failure(GitFailure(message: "A folder to compare could not be made: "
                    + error.localizedDescription))
        }
    }
}

extension Workspace {
    /// Performs a command that starts one job (Trash, delete, …); that job's id, nil if none started.
    func startJob(by command: Command) -> Int? {
        let known = Set(jobs.map(\.id))
        perform(command)
        return jobs.last { !known.contains($0.id) }?.id
    }

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
