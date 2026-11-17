import AppKit
@testable import Blitter
import BlitterCore
@testable import BlitterModel
import Testing

/// #112: the jobs strip's line, and the Jobs window where questions are answered and problems
/// dismissed.
extension FileOperationsInteractionTests {
    /// The strip says a question is waiting and offers Show Jobs; the question is answered in
    /// the Jobs window, which came forward for it.
    @Test func aConflictIsAnsweredInTheJobsWindow() async throws {
        let jobsWindow = JobsWindowController()
        defer { jobsWindow.close() }
        var shown = false
        jobsStrip.showJobs = { shown = true }
        FileManager.default.createFile(atPath: root + "/right/report.txt", contents: Data("old".utf8))
        workspace.perform(.select(.left, ["report.txt"]))
        workspace.perform(.copyToOtherSide)
        try await waitUntil { self.texts().contains("Copying “report.txt” to “right”: a question is waiting.") }
        #expect(!jobsStrip.view.isHidden)
        try #require(button("Show Jobs")).performClick(nil)
        #expect(shown)

        jobsWindow.render(workspace)
        #expect(jobsWindow.isShown)
        let row = try #require(jobsWindow.shownRows.first)
        let rowTexts = allSubviews(of: row).compactMap { ($0 as? NSTextField)?.stringValue }
        #expect(rowTexts.contains("“report.txt” already exists in “right”."))
        let keepBoth = allSubviews(of: row).compactMap { $0 as? NSButton }.first { $0.title == "Keep Both" }
        try #require(keepBoth).performClick(nil)
        try await waitUntil { self.workspace.jobs.isEmpty }
        let copied = try FileManager.default.contentsOfDirectory(atPath: root + "/right").sorted()
        #expect(copied == ["report 2.txt", "report.txt"])
        #expect(jobsStrip.view.isHidden)
    }

    @Test func aJobWithProblemsStaysUntilDismissedInTheJobsWindow() async throws {
        let jobsWindow = JobsWindowController()
        defer { jobsWindow.close() }
        workspace.perform(.rename(.left, path: root + "/left/report.txt", newName: "a/b"))
        try await waitUntil { self.texts().contains("1 job had problems") }
        jobsWindow.render(workspace)
        let row = try #require(jobsWindow.shownRows.first)
        let rowTexts = allSubviews(of: row).compactMap { ($0 as? NSTextField)?.stringValue }
        #expect(rowTexts.contains { $0.contains("is not a valid name") })
        let dismiss = allSubviews(of: row).compactMap { $0 as? NSButton }.first { $0.title == "Dismiss" }
        try #require(dismiss).performClick(nil)
        #expect(workspace.jobs.isEmpty)
        jobsStrip.render()
        #expect(jobsStrip.view.isHidden)
    }

    /// #112 review: a job cancelled without problems leaves the list; the strip, empty, hides.
    @Test func aCancelledJobLeavesAndTheStripHides() async throws {
        let jobsWindow = JobsWindowController()
        defer { jobsWindow.close() }
        FileManager.default.createFile(atPath: root + "/right/report.txt", contents: Data("old".utf8))
        workspace.perform(.select(.left, ["report.txt"]))
        workspace.perform(.copyToOtherSide)
        try await waitUntil { self.texts().contains("Copying “report.txt” to “right”: a question is waiting.") }
        jobsWindow.render(workspace)
        let row = try #require(jobsWindow.shownRows.first)
        let cancel = allSubviews(of: row).compactMap { $0 as? NSButton }.first { $0.title == "Cancel" }
        try #require(cancel).performClick(nil)
        try await waitUntil { self.workspace.jobs.isEmpty }
        jobsStrip.render()
        #expect(jobsStrip.view.isHidden)
        jobsWindow.render(workspace)
        #expect(jobsWindow.shownRows.isEmpty && !jobsWindow.isShown)
    }
}
