@testable import BlitterCore
@testable import BlitterGit
@testable import BlitterModel
import Foundation
import Testing

/// #71 review: failures on the way to the Trash leave no folder open. A tree of 40 listed folders,
/// each with a file: a handle left open per folder would show as 40 more open descriptors.
@MainActor
@Suite(.serialized)
struct GitCleanHandleTests {
    private static let folders = 40

    /// The process's open file descriptors.
    private static func openDescriptors() -> Int {
        (0 ..< Int32(getdtablesize())).count { fcntl($0, F_GETFD) != -1 }
    }

    private func mess(_ remote: GitTestRemote) throws -> String {
        let clone = remote.path("a")
        for index in 0 ..< Self.folders {
            let folder = clone + "/many/f\(index)"
            try FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
            try "x".write(toFile: folder + "/x.txt", atomically: true, encoding: .utf8)
        }
        return clone
    }

    private func run(_ remote: GitTestRemote, clone: String, refusing: Bool = false,
                     copyDetails: @escaping FileOperations.DetailsCopier = FileOperations.copyFolderDetails,
                     whileTrashing: @escaping @Sendable () -> Void = {}) async throws -> Job
    {
        let trash = remote.root + "/trash"
        try? FileManager.default.createDirectory(atPath: trash, withIntermediateDirectories: false)
        let jobs = JobQueue(trash: { path in
            whileTrashing()
            if refusing {
                throw POSIXError(.EPERM)
            }
            let target = trash + "/" + UUID().uuidString
            try FileManager.default.moveItem(atPath: path, toPath: target)
            return target
        }, copyDetails: copyDetails)
        let workspace = Workspace(initialLocation: remote.root, home: remote.root, lister: { _ in [] },
                                  directoryCheck: { _ in false }, volumes: { [] },
                                  watcher: { _ in SilentWatcher() }, jobs: jobs)
        let git = remote.git
        let clean = GitClean(workspace: workspace, path: clone, access: GitCleanAccess(
            preview: { Git.cleanPreview(in: $0, folders: $1, ignored: $2, git: git, cancelled: $3) },
            isFolder: GitCleanAccess.real.isFolder
        ))
        for _ in 0 ..< 1000 where clean.items == nil {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(clean.moveToTrash())
        for _ in 0 ..< 1000 where clean.runningJob != nil {
            try await Task.sleep(for: .milliseconds(10))
        }
        return try #require(workspace.jobs.first) // a job with problems stays
    }

    @Test func foldersWhoseDetailsCannotBeKeptLeaveNothingOpen() async throws {
        let remote = try GitTestRemote()
        let clone = try mess(remote)
        let before = Self.openDescriptors()
        let job = try await run(remote, clone: clone, copyDetails: { _, _ in EIO })
        #expect(job.errors.count(where: { $0.message.contains("details could not be kept") }) == Self.folders + 1)
        #expect(Self.openDescriptors() - before < 10, "\(Self.openDescriptors() - before) more open")
    }

    @Test func filesThatCannotGoBackLeaveNothingOpen() async throws {
        let remote = try GitTestRemote()
        let clone = try mess(remote)
        let before = Self.openDescriptors()
        // As the Trash refuses, the listed folder is swapped: nothing can go back through it.
        let job = try await run(remote, clone: clone, refusing: true, whileTrashing: {
            try? FileManager.default.moveItem(atPath: clone + "/many", toPath: clone + "/many-moved")
            try? FileManager.default.createDirectory(atPath: clone + "/many", withIntermediateDirectories: false)
        })
        #expect(job.errors.count(where: { $0.message.contains("could not be put back") }) == Self.folders)
        #expect(Self.openDescriptors() - before < 10, "\(Self.openDescriptors() - before) more open")
    }
}
