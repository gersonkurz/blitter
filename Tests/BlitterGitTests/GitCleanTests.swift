@testable import BlitterCore
@testable import BlitterGit
@testable import BlitterModel
import Foundation
import Testing

/// Git Clean (#71), against a real git: clone "a" of `GitTestRemote` with untracked files, an
/// untracked folder and an ignored file.
@MainActor
@Suite(.serialized)
struct GitCleanTests {
    private func makeMess(_ remote: GitTestRemote) throws {
        let clone = remote.path("a")
        try "*.log\n".write(toFile: clone + "/.gitignore", atomically: true, encoding: .utf8)
        try remote.commit(".gitignore", "*.log\n", in: "a")
        for (path, text) in [("loose.txt", "u"), ("new/inner.txt", "u"), ("debug.log", "i"), ("Ä b.txt", "u")] {
            try FileManager.default.createDirectory(atPath: (clone + "/" + path as NSString).deletingLastPathComponent,
                                                    withIntermediateDirectories: true)
            try text.write(toFile: clone + "/" + path, atomically: true, encoding: .utf8)
        }
    }

    @Test func thePreviewIsGitsOwnInEnglishWhateverTheLanguage() throws {
        let remote = try GitTestRemote()
        try makeMess(remote)
        let clone = remote.path("a")
        let plain = try #require(Git.cleanPreview(in: clone, folders: false, ignored: false, git: remote.git))
        #expect(Set(plain.removed) == ["loose.txt", "Ä b.txt"])
        let folders = try #require(Git.cleanPreview(in: clone, folders: true, ignored: false, git: remote.git))
        #expect(Set(folders.removed) == ["loose.txt", "Ä b.txt", "new/"])
        let all = try #require(Git.cleanPreview(in: clone, folders: true, ignored: true, git: remote.git))
        #expect(Set(all.removed) == ["loose.txt", "Ä b.txt", "new/", "debug.log"])
        // In a folder below: only what is in it, relative to it.
        let below = try #require(Git.cleanPreview(in: clone + "/new", folders: true, ignored: false, git: remote.git))
        #expect(below.removed == ["inner.txt"], "\(below)")
    }

    @Test func gitsQuotedPathsAndSkippedRepositoriesAreRead() {
        let preview = Git.parseCleanPreview("""
        Would remove plain.txt
        Would remove "tab\\there.txt"
        Would remove "quote\\"d \\\\ back.txt"
        Would remove "\\303\\204rger.txt"
        Would remove folder/
        Would skip repository nested/
        Would refuse to remove current working directory
        Would remove ./inner.txt
        """)
        #expect(preview.removed == ["plain.txt", "tab\there.txt", "quote\"d \\ back.txt", "Ärger.txt", "folder/",
                                    "inner.txt"])
        #expect(preview.skippedRepositories == ["nested/"])
    }

    // MARK: The model

    /// `whileTrashing`: runs as something goes to the (test) Trash, before it moves.
    /// `refusing`: the Trash refuses everything.
    private func workspace(_ remote: GitTestRemote, refusing: Bool = false,
                           copyDetails: @escaping FileOperations.DetailsCopier = FileOperations.copyFolderDetails,
                           whileTrashing: @escaping @Sendable () -> Void = {}) -> (Workspace, trash: String)
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
        return (workspace, trash)
    }

    private func access(_ git: String) -> GitCleanAccess {
        GitCleanAccess(preview: { Git.cleanPreview(in: $0, folders: $1, ignored: $2, git: git, cancelled: $3) },
                       isFolder: GitCleanAccess.real.isFolder)
    }

    private func settle(_ clean: GitClean) async {
        for _ in 0 ..< 1000 where clean.items == nil || clean.runningJob != nil {
            try? await Task.sleep(for: .milliseconds(10))
        }
    }

    /// Move to Trash takes exactly what was shown, as one undoable job; what turned up after the
    /// preview stays.
    @Test func moveToTrashTakesExactlyWhatWasShown() async throws {
        let remote = try GitTestRemote()
        try makeMess(remote)
        let (workspace, trash) = workspace(remote)
        let clone = remote.path("a")
        let clean = GitClean(workspace: workspace, path: clone + "/README.md", access: access(remote.git))
        await settle(clean)
        #expect(clean.folder == clone) // a file's folder
        #expect(Set(clean.items ?? []) == [clone + "/loose.txt", clone + "/Ä b.txt", clone + "/new"])
        try "late".write(toFile: clone + "/late.txt", atomically: true, encoding: .utf8)
        #expect(clean.moveToTrash())
        await settle(clean)
        #expect(clean.items == [clone + "/late.txt"]) // read again: only the latecomer is left
        #expect(FileManager.default.fileExists(atPath: clone + "/debug.log")) // ignored: not asked for
        // One folder in the Trash, the files in it at their paths; the emptied folder new removed.
        let trashed = try FileManager.default.contentsOfDirectory(atPath: trash)
        #expect(trashed.count == 1)
        let gathered = trash + "/" + (trashed.first ?? "")
        #expect(try Set(FileManager.default.subpathsOfDirectory(atPath: gathered))
            == ["loose.txt", "Ä b.txt", "new", "new/inner.txt"])
        #expect(!FileManager.default.fileExists(atPath: clone + "/new"))
        #expect(workspace.lastUndo?.title == "Move to Trash")

        // Undo puts each back where it was, the folder made again.
        try workspace.perform(.undo(entry: #require(workspace.lastUndo?.id)))
        for _ in 0 ..< 300 where !FileManager.default.fileExists(atPath: clone + "/new/inner.txt") {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(FileManager.default.fileExists(atPath: clone + "/new/inner.txt"))
        #expect(FileManager.default.fileExists(atPath: clone + "/loose.txt"))
        #expect(FileManager.default.fileExists(atPath: clone + "/Ä b.txt"))
    }

    @Test func deleteForGoodAndTheOptions() async throws {
        let remote = try GitTestRemote()
        try makeMess(remote)
        let (workspace, trash) = workspace(remote)
        let clone = remote.path("a")
        let clean = GitClean(workspace: workspace, path: clone, access: access(remote.git))
        await settle(clean)
        clean.includesIgnored = true
        await settle(clean)
        #expect(clean.items?.contains(clone + "/debug.log") == true && clean.items?.count == 4)
        #expect(clean.deleteForGood())
        await settle(clean)
        #expect(clean.items == [] && !clean.canRemove)
        #expect(try FileManager.default.contentsOfDirectory(atPath: trash).isEmpty) // for good, not the Trash
        #expect(FileManager.default.fileExists(atPath: clone + "/README.md")) // tracked: untouched
    }

    /// A file that turns up inside a listed folder after the list was made stays, and so does
    /// its folder; the rest goes (#71 review). Both ways of removing.
    @Test(arguments: [false, true])
    func whatTurnsUpInAListedFolderLaterStays(forGood: Bool) async throws {
        let remote = try GitTestRemote()
        try makeMess(remote)
        let (workspace, _) = workspace(remote)
        let clone = remote.path("a")
        let clean = GitClean(workspace: workspace, path: clone, access: access(remote.git))
        await settle(clean)
        #expect(clean.items?.contains(clone + "/new") == true)
        try "late".write(toFile: clone + "/new/late.txt", atomically: true, encoding: .utf8)
        #expect(forGood ? clean.deleteForGood() : clean.moveToTrash())
        await settle(clean)
        #expect(!FileManager.default.fileExists(atPath: clone + "/new/inner.txt"))
        #expect(!FileManager.default.fileExists(atPath: clone + "/loose.txt"))
        #expect(FileManager.default.fileExists(atPath: clone + "/new/late.txt")) // never shown: kept
        #expect(workspace.jobs.first?.errors.first?.message.contains("was kept") == true)
    }

    /// Repositories inside the folder are git's to leave alone, also one inside an otherwise
    /// untracked folder; their neighbours go (#71 review). With -d and -d -x, both ways of removing.
    @Test(arguments: [(false, false), (false, true), (true, false), (true, true)])
    func nestedRepositoriesSurvive(ignored: Bool, forGood: Bool) async throws {
        let remote = try GitTestRemote()
        try makeMess(remote)
        let clone = remote.path("a")
        for repository in ["nested", "untracked/inner"] {
            try FileManager.default.createDirectory(atPath: clone + "/" + repository, withIntermediateDirectories: true)
            _ = try remote.output(["init", "-q"], in: clone + "/" + repository)
            try "keep".write(toFile: clone + "/" + repository + "/repo.txt", atomically: true, encoding: .utf8)
        }
        try "u".write(toFile: clone + "/untracked/a.txt", atomically: true, encoding: .utf8)
        try "l".write(toFile: clone + "/untracked/x.log", atomically: true, encoding: .utf8)
        let (workspace, _) = workspace(remote)
        let clean = GitClean(workspace: workspace, path: clone, access: access(remote.git))
        await settle(clean)
        clean.includesIgnored = ignored
        await settle(clean)
        #expect(forGood ? clean.deleteForGood() : clean.moveToTrash())
        await settle(clean)
        for repository in ["nested", "untracked/inner"] {
            #expect(FileManager.default.fileExists(atPath: clone + "/" + repository + "/repo.txt"))
            #expect(FileManager.default.fileExists(atPath: clone + "/" + repository + "/.git"))
        }
        #expect(!FileManager.default.fileExists(atPath: clone + "/untracked/a.txt"))
        #expect(!FileManager.default.fileExists(atPath: clone + "/loose.txt"))
        #expect(FileManager.default.fileExists(atPath: clone + "/untracked/x.log") == !ignored)
    }

    /// A listed folder swapped for a link to another folder since the list was made: nothing is
    /// removed through it, in either way of removing (#71 review).
    @Test(arguments: [false, true])
    func aFolderSwappedForALinkIsNotFollowed(forGood: Bool) async throws {
        let remote = try GitTestRemote()
        try makeMess(remote)
        let (workspace, _) = workspace(remote)
        let clone = remote.path("a")
        let clean = GitClean(workspace: workspace, path: clone, access: access(remote.git))
        await settle(clean)
        let elsewhere = remote.root + "/elsewhere"
        try FileManager.default.createDirectory(atPath: elsewhere, withIntermediateDirectories: false)
        try "precious".write(toFile: elsewhere + "/inner.txt", atomically: true, encoding: .utf8)
        try FileManager.default.moveItem(atPath: clone + "/new", toPath: clone + "/new-moved")
        try FileManager.default.createSymbolicLink(atPath: clone + "/new", withDestinationPath: elsewhere)
        #expect(forGood ? clean.deleteForGood() : clean.moveToTrash())
        await settle(clean)
        #expect(FileManager.default.fileExists(atPath: elsewhere + "/inner.txt")) // never through the link
        #expect(FileManager.default.fileExists(atPath: clone + "/new-moved/inner.txt"))
        #expect(!FileManager.default.fileExists(atPath: clone + "/loose.txt")) // the rest goes
        #expect(workspace.jobs.first?.errors
            .contains { $0.message.contains("changed since the list was made") } == true)
    }

    /// Something added to a listed folder after its files went, just before the folder itself
    /// is removed: the folder stays, with it (#71 review). The test Trash adds it as the gathered
    /// files go to the Trash, which is after the files and before the folders.
    @Test func whatTurnsUpWhileRemovingStays() async throws {
        let remote = try GitTestRemote()
        try makeMess(remote)
        let clone = remote.path("a")
        let (workspace, _) = workspace(remote, whileTrashing: {
            try? "late".write(toFile: clone + "/new/late.txt", atomically: true, encoding: .utf8)
        })
        let clean = GitClean(workspace: workspace, path: clone, access: access(remote.git))
        await settle(clean)
        #expect(clean.moveToTrash())
        await settle(clean)
        #expect(FileManager.default.fileExists(atPath: clone + "/new/late.txt"))
        #expect(!FileManager.default.fileExists(atPath: clone + "/new/inner.txt"))
        #expect(workspace.jobs.first?.errors.first?.message.contains("was kept") == true)
    }

    /// A folder removed on the way to the Trash comes back with its details: private permissions
    /// and an extended attribute (#71 review).
    @Test func undoGivesAFolderItsDetailsBack() async throws {
        let remote = try GitTestRemote()
        try makeMess(remote)
        let clone = remote.path("a")
        let folder = clone + "/new"
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: folder)
        let value = Array("kept".utf8)
        #expect(setxattr(folder, "org.blitter.test", value, value.count, 0, XATTR_NOFOLLOW) == 0)
        let (workspace, _) = workspace(remote)
        let clean = GitClean(workspace: workspace, path: clone, access: access(remote.git))
        await settle(clean)
        #expect(clean.moveToTrash())
        await settle(clean)
        #expect(!FileManager.default.fileExists(atPath: folder))
        try workspace.perform(.undo(entry: #require(workspace.lastUndo?.id)))
        for _ in 0 ..< 300 where !FileManager.default.fileExists(atPath: folder + "/inner.txt") {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(FileManager.default.fileExists(atPath: folder + "/inner.txt"))
        let mode = try FileManager.default.attributesOfItem(atPath: folder)[.posixPermissions] as? Int
        #expect(mode == 0o700)
        var read = [UInt8](repeating: 0, count: 16)
        let length = getxattr(folder, "org.blitter.test", &read, read.count, 0, XATTR_NOFOLLOW)
        #expect(length == value.count && Array(read.prefix(max(length, 0))) == value)
    }

    /// The Trash refuses: everything goes back where it was, nothing is left gathered, and the
    /// job says so (#71 review).
    @Test func whenTheTrashRefusesEverythingGoesBack() async throws {
        let remote = try GitTestRemote()
        try makeMess(remote)
        let clone = remote.path("a")
        let before = try Set(FileManager.default.subpathsOfDirectory(atPath: clone).filter { !$0.hasPrefix(".git/") })
        let (workspace, _) = workspace(remote, refusing: true)
        let clean = GitClean(workspace: workspace, path: clone, access: access(remote.git))
        await settle(clean)
        #expect(clean.moveToTrash())
        await settle(clean)
        let after = try Set(FileManager.default.subpathsOfDirectory(atPath: clone).filter { !$0.hasPrefix(".git/") })
        #expect(after == before) // the files back, no "Git Clean" folder left
        #expect(workspace.jobs.first?.errors.first?.message.contains("put back") == true)
        #expect(workspace.lastUndo == nil) // nothing changed, nothing to undo
    }
}
