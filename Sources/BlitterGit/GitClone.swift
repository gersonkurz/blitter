import BlitterCore
import BlitterModel
import Foundation

/// Git Clone (#70): a repository cloned into a folder, as a job (in the jobs strip, with
/// Cancel), its output followed as it comes. Works in any folder, not only in a working copy.
/// Git runs without a terminal to ask in: credentials come from SSH keys or the keychain.
@MainActor
public final class GitClone {
    public enum State: Equatable, Sendable {
        case editing
        case cloning
        case succeeded
        case failed(String)
        case cancelled
    }

    /// Where the clone goes.
    public let folder: String
    public private(set) var state = State.editing
    /// Called whenever `state` or `output` changes.
    public var onChange: (() -> Void)?
    /// Whether git has been looked for (off the main thread: it looks at the disk).
    public private(set) var isReady = false
    private let workspace: Workspace
    private var git: String?
    private let commands: CommandSequence

    /// `findGit` runs off the main thread; tests give their own.
    public init(workspace: Workspace, folder: String,
                findGit: @escaping @Sendable () -> String? = { Git.executable })
    {
        self.workspace = workspace
        self.folder = folder
        commands = CommandSequence(workspace: workspace, folder: folder)
        commands.onChange = { [weak self] in self?.onChange?() }
        Task { [weak self] in
            let git = await Task.detached(priority: .userInitiated) { findGit() }.value
            self?.git = git
            self?.isReady = true
            self?.onChange?()
        }
    }

    /// What git printed so far.
    public var output: String {
        commands.output
    }

    /// The folder name git would choose: the address's last part without ".git", e.g. "repo"
    /// from "https://host/me/repo.git" or "git@host:me/repo.git".
    public static func name(from address: String) -> String {
        var text = address.trimmingCharacters(in: .whitespacesAndNewlines)
        while text.hasSuffix("/") {
            text.removeLast()
        }
        if text.hasSuffix(".git") {
            text.removeLast(4)
        }
        return text.split { $0 == "/" || $0 == ":" }.last.map(String.init) ?? ""
    }

    /// Why cloning cannot start with these, nil if it can. A name already in the folder is
    /// found in the listing a side shows (no disk access here); git refuses it anyway.
    public func problem(address: String, name: String) -> String? {
        let address = address.trimmingCharacters(in: .whitespacesAndNewlines)
        if address.isEmpty {
            return "Enter the repository's address."
        }
        if address.contains(where: \.isNewline) {
            return "The address has a line break."
        }
        if name.isEmpty {
            return "Enter a name for the new folder."
        }
        if name == "." || name == ".." || name.contains("/") || name.contains("\0") {
            return "“\(name)” is not a folder name."
        }
        let taken = Side.allCases.map { workspace.state(of: $0) }.filter { $0.entriesLocation == folder }
            .contains { $0.visibleEntries.contains { $0.entry.name.lowercased() == name.lowercased() } }
        if taken {
            return "“\(name)” is already in this folder."
        }
        if isReady, git == nil {
            return "No git was found (install the Xcode command line tools, or git from Homebrew)."
        }
        return nil
    }

    /// Starts the clone; false if it cannot start now. Once it succeeded, the sides that show
    /// the folder select the new one.
    @discardableResult
    public func clone(address: String, name: String) -> Bool {
        guard isReady, state != .cloning, problem(address: address, name: name) == nil, let git else {
            return false
        }
        let address = address.trimmingCharacters(in: .whitespacesAndNewlines)
        let (workspace, folder) = (workspace, folder)
        let started = commands.start([[git, "clone", "--progress", "--", address, name]]) { [weak self] ending in
            switch ending {
            case .succeeded:
                workspace.perform(.selectAfterReading(folder: folder, names: [name]))
                self?.state = .succeeded
            case let .failed(_, message):
                self?.state = .failed(message)
            case .cancelled:
                self?.state = .cancelled
            }
            self?.onChange?()
        }
        guard started else {
            return false
        }
        state = .cloning
        onChange?()
        return true
    }

    public func cancel() {
        commands.cancel()
    }
}
