import BlitterCore
import Foundation

/// The words a job row shows.
enum JobText {
    static func title(_ operation: FileOperation) -> String {
        switch operation {
        case let .copy(paths, folder):
            "Copying \(items(paths)) to “\(name(folder))”"
        case let .move(paths, folder):
            "Moving \(items(paths)) to “\(name(folder))”"
        case let .trash(paths):
            "Moving \(items(paths)) to the Trash"
        case let .delete(paths):
            "Deleting \(items(paths))"
        case let .command(arguments, _):
            "Running “\(([name(arguments.first ?? "")] + arguments.dropFirst()).joined(separator: " "))”"
        case let .rename(path, newName):
            "Renaming “\(name(path))” to “\(newName)”"
        case let .renameAll(renames):
            "Renaming \(items(renames.map(\.path)))"
        case let .newFolder(_, folderName):
            "Creating “\(folderName)”"
        case let .removeExactly(plan, forGood):
            forGood ? "Deleting \(plan.files.count) items" : "Moving \(plan.files.count) items to the Trash"
        case let .undo(steps):
            steps.count == 1 ? "Undoing 1 change" : "Undoing \(steps.count) changes"
        }
    }

    /// The strip's line (#112): a question first, then how many run and wait, how far the first
    /// running one is, and how many had problems.
    static func summary(_ jobs: [Job]) -> String {
        let open = jobs.filter { !$0.isDone }
        if let asking = open.first(where: {
            if case .waiting = $0.state {
                true
            } else {
                false
            }
        }) {
            return title(asking.operation) + ": a question is waiting."
        }
        var parts: [String] = []
        let running = open.filter { $0.state == .running }
        let waiting = open.count - running.count
        if let first = running.first {
            var line = running.count == 1 ? title(first.operation) : "\(running.count) jobs running"
            if let fraction = fraction(first.progress) {
                line += ", \(Int((fraction * 100).rounded())) %"
            }
            parts.append(line)
        }
        if waiting > 0 {
            parts.append(waiting == 1 ? "1 waiting" : "\(waiting) waiting")
        }
        let problems = jobs.filter { $0.isDone && !$0.errors.isEmpty }.count
        if problems > 0 {
            parts.append(problems == 1 ? "1 job had problems" : "\(problems) jobs had problems")
        }
        return parts.joined(separator: " · ")
    }

    static func detail(_ job: Job, now: Date = Date()) -> String {
        let text = stateText(job, now: now)
        return job.origin.map { text.isEmpty ? $0 : text + " · " + $0 } ?? text
    }

    private static func stateText(_ job: Job, now: Date) -> String {
        switch job.state {
        case let .waiting(conflict):
            "“\(name(conflict.existing))” already exists in “\(name(parent(conflict.existing)))”."
        case .cancelled:
            job.errors.isEmpty ? "Cancelled." : "Cancelled. " + problems(job.errors)
        case .finished:
            job.errors.isEmpty ? "Done." : problems(job.errors)
        case .running:
            runningText(job, now: now)
        case .queued:
            "Waiting for its turn." // #112: behind another job
        }
    }

    static func fraction(_ progress: JobProgress) -> Double? {
        if let total = progress.totalBytes, total > 0 {
            return min(1, Double(progress.doneBytes) / Double(total))
        }
        guard progress.totalItems > 0 else {
            return nil
        }
        return Double(progress.doneItems) / Double(progress.totalItems)
    }

    /// A running job (#112): how far, how fast, for how long, how long still — and if it has made
    /// no progress for a while, that first (a big folder deleted for good can be quiet that long
    /// without being stuck, so it says what it knows).
    static func runningText(_ job: Job, now: Date) -> String {
        var parts: [String] = []
        if let quiet = job.quietTime(at: now), quiet >= Job.quietThreshold {
            parts.append("No progress for \(duration(quiet))")
        }
        let progress = progressText(job.progress)
        if !progress.isEmpty {
            parts.append(progress)
        }
        let speed = job.bytesPerSecond(at: now)
        if let speed, speed > 0 {
            parts.append(bytes(Int64(speed)) + "/s")
        }
        if let started = job.started {
            parts.append(duration(now.timeIntervalSince(started)) + " elapsed")
        }
        if let total = job.progress.totalBytes, let speed, speed > 0, total > job.progress.doneBytes {
            parts.append("about " + duration(Double(total - job.progress.doneBytes) / speed) + " left")
        }
        return parts.joined(separator: " · ")
    }

    /// "0:42", "12:05", "1:02:05".
    static func duration(_ seconds: TimeInterval) -> String {
        let total = max(0, Int(seconds.rounded()))
        let (hours, minutes, rest) = (total / 3600, total / 60 % 60, total % 60)
        return hours > 0 ? String(format: "%d:%02d:%02d", hours, minutes, rest)
            : String(format: "%d:%02d", minutes, rest)
    }

    static func bytes(_ count: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return formatter.string(fromByteCount: count)
    }

    private static func progressText(_ progress: JobProgress) -> String {
        var parts: [String] = []
        if progress.totalItems > 1 {
            parts.append("\(progress.doneItems) of \(progress.totalItems) items")
        }
        if let total = progress.totalBytes, total > 0 {
            parts.append("\(bytes(progress.doneBytes)) of \(bytes(total))")
        } else if progress.doneBytes > 0 {
            parts.append("\(bytes(progress.doneBytes)) so far") // the total is not measured (yet)
        }
        if let current = progress.currentItem {
            parts.append(current)
        }
        return parts.joined(separator: " · ")
    }

    private static func problems(_ errors: [JobError]) -> String {
        let first = "\(name(errors[0].path)): \(errors[0].message)"
        return errors.count == 1 ? first : "\(first) (and \(errors.count - 1) more)"
    }

    private static func items(_ paths: [String]) -> String {
        paths.count == 1 ? "“\(name(paths[0]))”" : "\(paths.count) items"
    }

    private static func parent(_ path: String) -> String {
        (path as NSString).deletingLastPathComponent
    }

    private static func name(_ path: String) -> String {
        (path as NSString).lastPathComponent
    }
}
