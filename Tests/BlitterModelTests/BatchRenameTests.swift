import BlitterCore
@testable import BlitterModel
import Foundation
import Testing

/// Batch Rename's rule and preview, and the command on real files.
@MainActor
@Suite(.serialized)
struct BatchRenameTests {
    private func names(_ rule: BatchRename, _ names: [String], folders: Set<String> = []) -> [String]? {
        try? rule.newNames(for: names.map { BatchRename.Item(name: $0, isFolder: folders.contains($0)) })
    }

    private func makePreview(_ rule: BatchRename, _ items: [BatchRename.Item], taken: [String]) -> BatchRenamePreview {
        BatchRenamePreview(rule, items: items, taken: taken, folder: "/folder")
    }

    @Test func findAndReplaceWorkOnTheNameAndKeepTheExtension() {
        var rule = BatchRename()
        rule.find = "IMG"
        rule.replace = "Photo"
        #expect(names(rule, ["img_1.jpg", "IMG_2.JPG", "notes.img"]) == ["Photo_1.jpg", "Photo_2.JPG", "notes.img"])
        rule.ignoresCase = false
        #expect(names(rule, ["img_1.jpg", "IMG_2.JPG"]) == ["img_1.jpg", "Photo_2.JPG"])
        rule.find = "img"
        rule.includesExtension = true
        #expect(names(rule, ["notes.img"]) == ["notes.Photo"])
        // A folder's whole name is its name.
        rule.includesExtension = false
        #expect(names(rule, ["my.img"], folders: ["my.img"]) == ["my.Photo"])
    }

    @Test func regularExpressionsTemplatesCountersAndCase() {
        var rule = BatchRename()
        rule.usesRegex = true
        rule.find = "^(\\w+)-(\\d+)$"
        rule.replace = "$2-$1"
        #expect(names(rule, ["photo-12.jpg", "other.jpg"]) == ["12-photo.jpg", "other.jpg"])
        rule.find = "(["
        #expect(names(rule, ["a"]) == nil)

        rule = BatchRename()
        rule.template = "Holiday {n:3} ({name})"
        rule.counterStart = 9
        #expect(names(rule, ["a.jpg", "b.jpg"]) == ["Holiday 009 (a).jpg", "Holiday 010 (b).jpg"])
        rule.template = "{n}-{x}-{n:}"
        #expect(names(rule, ["a"]) == ["9-{x}-{n:}"]) // only {n} and {n:width} are counters
        // Only the template is read for them: names and replacements are put in as they are.
        rule = BatchRename()
        #expect(names(rule, ["report{n}.txt", "{name}"]) == ["report{n}.txt", "{name}"])
        rule.find = "x"
        rule.replace = "{n:3}"
        #expect(names(rule, ["axb"]) == ["a{n:3}b"])
        // The counter's range: counting on can never overflow.
        rule = BatchRename()
        rule.template = "{n:2}"
        for start in [Int.max, Int.min, -1, 1_000_000_000] {
            rule.counterStart = start
            #expect(throws: BatchRename.Problem.counterOutOfRange) {
                try rule.newNames(for: [BatchRename.Item(name: "a", isFolder: false)])
            }
        }
        rule.counterStart = 999_999_999
        #expect(names(rule, ["a", "b"]) == ["999999999", "1000000000"])
        rule.template = "{name}"
        rule.nameCase = .title
        rule.extensionCase = .lower
        #expect(names(rule, ["MY HOLIDAY.JPG", "readme"]) == ["My Holiday.jpg", "Readme"])
        rule.nameCase = .upper
        rule.extensionCase = .unchanged
        #expect(names(rule, [".bashrc"]) == [".BASHRC"]) // a leading dot is no extension
    }

    @Test func thePreviewTellsWhatCannotBe() {
        var rule = BatchRename()
        rule.template = "x"
        let items = ["a", "b"].map { BatchRename.Item(name: $0, isFolder: false) }
        var preview = makePreview(rule, items, taken: ["a", "b", "c"])
        #expect(!preview.canRename && preview.rows.allSatisfy { $0.problem != nil }) // the same name twice

        rule.template = "C" // taken by an item that keeps its name, ignoring case
        preview = makePreview(rule, [items[0]], taken: ["a", "b", "c"])
        #expect(!preview.canRename && preview.rows[0].problem != nil)

        rule.template = "{name}" // nothing changes
        preview = makePreview(rule, items, taken: ["a", "b"])
        #expect(!preview.canRename && preview.rows.allSatisfy { $0.problem == nil })

        // "a" may take "aa"'s name: "aa" is renamed too.
        rule.template = "{name}a"
        let chain = ["a", "aa"].map { BatchRename.Item(name: $0, isFolder: false) }
        preview = makePreview(rule, chain, taken: ["a", "aa"])
        #expect(preview.rows.map(\.newName) == ["aa", "aaa"] && preview.canRename)

        rule.usesRegex = true
        rule.find = "("
        preview = makePreview(rule, items, taken: ["a", "b"])
        #expect(preview.problem != nil && !preview.canRename)
    }

    @Test func theCommandRenamesTheSelectionAndSelectsTheNewNames() async throws {
        let sides = try SidesOnDisk()
        for name in ["b.txt", "a.txt", "keep.md"] {
            sides.file("left/" + name, name)
        }
        try await sides.settle()
        let workspace = sides.workspace
        workspace.perform(.select(.left, ["a.txt", "b.txt"]))
        workspace.perform(.requestBatchRename(.left))
        #expect(workspace.batchRenameRequest?.side == .left)
        var rule = BatchRename()
        rule.template = "Note {n:2}"
        // In list order: a.txt first.
        #expect(workspace.batchRenamePreview(.left, rule).rows.map(\.newName) == ["Note 01.txt", "Note 02.txt"])
        workspace.perform(.batchRename(.left, workspace.batchRenamePreview(.left, rule)))
        #expect(workspace.batchRenameRequest == nil)
        try await sides.settle()
        #expect(sides.names(.left) == ["keep.md", "Note 01.txt", "Note 02.txt"])
        #expect(workspace.state(of: .left).selection == ["Note 01.txt", "Note 02.txt"])
        #expect(FileManager.default.contents(atPath: sides.left + "/Note 01.txt") == Data("a.txt".utf8))

        // A rule that cannot be applied does nothing; Cancel ends the request.
        rule.template = "keep"
        rule.find = ""
        workspace.perform(.select(.left, ["Note 01.txt"]))
        rule.template = "keep.md"
        rule.includesExtension = true
        workspace.perform(.batchRename(.left, workspace.batchRenamePreview(.left, rule)))
        try await sides.settle()
        #expect(sides.names(.left) == ["keep.md", "Note 01.txt", "Note 02.txt"])
        workspace.perform(.requestBatchRename(.left))
        workspace.perform(.cancelBatchRename)
        #expect(workspace.batchRenameRequest == nil)
        // Not for search results.
        workspace.perform(.find(.left, pattern: "*"))
        try await sides.settle()
        workspace.perform(.select(.left, ["keep.md"]))
        #expect(!workspace.canRun("batch-rename", on: .left))
    }

    @Test func whatWasShownIsCheckedAgainstTheFolderAsItIsNow() async throws {
        let sides = try SidesOnDisk()
        for name in ["a.txt", "b.txt"] {
            sides.file("left/" + name, name)
        }
        try await sides.settle()
        let workspace = sides.workspace
        workspace.perform(.select(.left, ["a.txt", "b.txt"]))
        var rule = BatchRename()
        rule.template = "{n}"
        let shown = workspace.batchRenamePreview(.left, rule)
        #expect(shown.rows.map(\.newName) == ["1.txt", "2.txt"])
        // Another app deletes "a.txt"; the side reads the folder again.
        try FileManager.default.removeItem(atPath: sides.left + "/a.txt")
        workspace.reload(showing: [sides.left])
        try await sides.settle()
        workspace.perform(.batchRename(.left, shown)) // "b.txt" would get "2.txt", as shown, but "a.txt" is gone
        try await sides.settle()
        #expect(sides.names(.left) == ["b.txt"])
        #expect(workspace.jobs.isEmpty) // refused before any job, not by one that fails
        // And a name taken meanwhile.
        sides.file("left/1.txt", "new")
        workspace.reload(showing: [sides.left])
        try await sides.settle()
        workspace.perform(.select(.left, ["b.txt"]))
        let taken = BatchRenamePreview(rule, items: [BatchRename.Item(name: "b.txt", isFolder: false)],
                                       taken: ["b.txt"], folder: sides.left)
        #expect(taken.canRename)
        workspace.perform(.batchRename(.left, taken))
        try await sides.settle()
        #expect(sides.names(.left) == ["1.txt", "b.txt"] && FileManager.default.contents(atPath: sides.left + "/1.txt")
            == Data("new".utf8))
        #expect(workspace.jobs.isEmpty)
    }

    /// On a case-sensitive volume, "foo" and "FOO" can be side by side: renaming "foo" to "Foo"
    /// is refused, by the preview and by the job, as the rule (ignoring case) says.
    @Test func clashesIgnoreCaseOnACaseSensitiveVolume() async throws {
        let volume = try FindDiskImage(fileSystem: "Case-sensitive APFS")
        for name in ["foo", "FOO"] {
            FileManager.default.createFile(atPath: volume.mountPoint + "/" + name, contents: Data(name.utf8))
        }
        var rule = BatchRename()
        rule.nameCase = .title
        let shown = BatchRenamePreview(rule, items: [BatchRename.Item(name: "foo", isFolder: false)],
                                       taken: ["foo", "FOO"], folder: volume.mountPoint)
        #expect(shown.rows.map(\.newName) == ["Foo"] && !shown.canRename)

        let queue = JobQueue()
        let id = queue.start(.renameAll([Rename(path: volume.mountPoint + "/foo", newName: "Foo")]))
        let done = { queue.jobs.first(where: { $0.id == id })?.isDone == true }
        for _ in 0 ..< 400 where !done() {
            try await Task.sleep(for: .milliseconds(5))
        }
        #expect(queue.jobs.first { $0.id == id }?.errors.count == 1)
        let names = try FileManager.default.contentsOfDirectory(atPath: volume.mountPoint).filter { !$0.hasPrefix(".") }
        #expect(names.sorted() == ["FOO", "foo"])
    }
}
