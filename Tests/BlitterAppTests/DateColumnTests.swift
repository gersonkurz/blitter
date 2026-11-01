import AppKit
@testable import Blitter
import BlitterCore
@testable import BlitterModel
import Testing

/// The Date Modified column (#12): the settings' pattern, no relative dates, digits that line up.
@MainActor
@Suite(.serialized)
final class DateColumnTests {
    private let workspace: Workspace
    private let controller: FileListViewController
    private let window: NSWindow
    private static let yesterday = Date(timeIntervalSinceNow: -86400)

    init() async throws {
        var recent = file("recent")
        recent.modificationDate = Self.yesterday
        var old = file("old")
        old.modificationDate = DateComponents(calendar: .current, year: 2026, month: 2, day: 24, hour: 19, minute: 19)
            .date ?? .distantPast
        let entries = [old, recent]
        workspace = Workspace(initialLocation: "/dated", home: "/home", lister: { _ in entries },
                              directoryCheck: { _ in false }, volumes: { [] }, watcher: FakeWatcher.factory)
        controller = FileListViewController(workspace: workspace, side: .left)
        window = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 700, height: 300),
                          styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentViewController = controller
        workspace.onChange = { [controller] in controller.render() }
        window.makeKeyAndOrderFront(nil)
        for _ in 0 ..< 200 where workspace.state(of: .left).visibleEntries.count < 2 {
            try await Task.sleep(for: .milliseconds(10))
        }
        controller.render()
        controller.view.layoutSubtreeIfNeeded()
    }

    isolated deinit {
        window.close()
    }

    @Test func theDefaultIsDayMonthYearHoursMinutesWithoutRelativeDates() throws {
        #expect(try dateText(of: "old") == "24.02.2026 19:19")
        let recent = try dateText(of: "recent")
        #expect(recent == Formatting.dateFormatter("dd.MM.yyyy HH:mm").string(from: Self.yesterday))
        #expect(!recent.contains("Yesterday") && !recent.contains(" at "))
    }

    @Test func aNewPatternFromTheSettingsShowsInEveryRow() throws {
        workspace.settings.dateFormat = "yyyy-MM-dd"
        workspace.onChange?()
        #expect(try dateText(of: "old") == "2026-02-24")
    }

    @Test func datesAndSizesHaveDigitsOfEqualWidth() throws {
        for column in ["modified", "size"] {
            let font = try #require(cell(column, of: "old").textField?.font)
            let ones = ("11.11.1111" as NSString).size(withAttributes: [.font: font]).width
            let zeros = ("00.00.0000" as NSString).size(withAttributes: [.font: font]).width
            #expect(abs(ones - zeros) < 0.01, "\(column)")
            // The same size as the names in the small rows.
            let nameSize = try cell("name", of: "old").textField?.font?.pointSize
            #expect(font.pointSize == nameSize, "\(column)")
        }
    }

    @Test func theColumnGrowsForALongPatternButNeverShrinks() throws {
        let column = try #require(tableView.tableColumns.first { $0.identifier.rawValue == "modified" })
        let width = column.width
        workspace.settings.dateFormat = "EEEE, d. MMMM yyyy 'um' HH:mm:ss"
        workspace.onChange?()
        let text = try dateText(of: "old") as NSString
        let font = try #require(cell("modified", of: "old").textField?.font)
        #expect(column.width > width)
        #expect(column.width >= text.size(withAttributes: [.font: font]).width + 4)
        // Every weekday and month name fits, not just the one in the list (#12 review: "Donnerstag").
        let formatter = Formatting.dateFormatter(workspace.settings.dateFormat)
        for day in 1 ... 366 {
            let date = Date(timeIntervalSince1970: 1_767_225_600 + Double(day) * 86400 - 3600 + 0.5)
            let width = (formatter.string(from: date) as NSString).size(withAttributes: [.font: font]).width
            #expect(column.width >= width + 4, "\(formatter.string(from: date))")
        }

        let grown = column.width
        workspace.settings.dateFormat = "HH:mm"
        workspace.onChange?()
        #expect(column.width == grown)
    }

    // MARK: Helpers

    private var tableView: NSTableView {
        controller.tableView
    }

    private func cell(_ column: String, of name: String) throws -> NSTableCellView {
        let columnIndex = try #require(tableView.tableColumns.firstIndex { $0.identifier.rawValue == column })
        let row = try #require(workspace.state(of: .left).visibleEntries.firstIndex { $0.entry.name == name })
        tableView.layoutSubtreeIfNeeded()
        return try #require(tableView.view(atColumn: columnIndex, row: row, makeIfNecessary: true) as? NSTableCellView)
    }

    private func dateText(of name: String) throws -> String {
        try #require(cell("modified", of: name).textField?.stringValue)
    }
}
