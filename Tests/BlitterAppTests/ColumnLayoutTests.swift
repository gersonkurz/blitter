import AppKit
@testable import Blitter
import BlitterCore
@testable import BlitterModel
import Testing

/// #123: room is taken where it is not needed before the names.
struct ColumnLayoutTests {
    private let columns = [
        ColumnLayout.Column(id: "name", role: .name, preferred: 280, fitted: 0, minimum: 40),
        ColumnLayout.Column(id: "size", role: .fitted, preferred: 80, fitted: 60, minimum: 40),
        ColumnLayout.Column(id: "date", role: .fitted, preferred: 150, fitted: 110, minimum: 40),
        ColumnLayout.Column(id: "kind", role: .text, preferred: 140, fitted: 0, minimum: 60),
    ] // preferred 650; fitted others 170 + kind 140

    private func widths(_ available: CGFloat) -> [String: CGFloat] {
        ColumnLayout.widths(columns, available: available)
    }

    @Test func withRoomToSpareNameGetsTheRest() {
        #expect(widths(800) == ["name": 430, "size": 80, "date": 150, "kind": 140])
        #expect(widths(650) == ["name": 280, "size": 80, "date": 150, "kind": 140])
    }

    /// 1. The slack first, in proportion (size 20, date 40): Name keeps its preferred width.
    @Test func theSlackGoesFirst() {
        let some = widths(620) // 30 short: 10 from size, 20 from date
        #expect(some == ["name": 280, "size": 70, "date": 130, "kind": 140])
        #expect(widths(590) == ["name": 280, "size": 60, "date": 110, "kind": 140]) // all the slack
    }

    /// 2. Then Name, down to 160; 3. then Kind, down to its minimum.
    @Test func thenNameToReadableThenKind() {
        #expect(widths(500) == ["name": 190, "size": 60, "date": 110, "kind": 140])
        #expect(widths(470) == ["name": 160, "size": 60, "date": 110, "kind": 140])
        #expect(widths(420) == ["name": 160, "size": 60, "date": 110, "kind": 90])
        #expect(widths(390) == ["name": 160, "size": 60, "date": 110, "kind": 60])
    }

    /// 4. Then Name below 160; 5. only then the dates and sizes themselves.
    @Test func thenNameBelowReadableThenTheFittedColumns() {
        #expect(widths(300) == ["name": 70, "size": 60, "date": 110, "kind": 60])
        #expect(widths(270) == ["name": 40, "size": 60, "date": 110, "kind": 60])
        let tight = widths(220) // 50 more: in proportion to what is left above their minimum (20, 70)
        #expect(tight["name"] == 40 && tight["kind"] == 60)
        #expect(abs((tight["size"] ?? 0) - (60 - 50 * 20 / 90)) < 0.001)
        #expect(abs((tight["date"] ?? 0) - (110 - 50 * 70 / 90)) < 0.001)
        #expect(widths(100).values.allSatisfy { $0 >= 40 }) // no room: every column at its minimum
    }

    /// A fitted column whose content is wider than its preferred width (a long date pattern) gets
    /// what it needs while there is room; short of room it shrinks last, as always.
    @Test func aFittedColumnGetsWhatItNeedsWhenThereIsRoom() {
        let long = [
            ColumnLayout.Column(id: "name", role: .name, preferred: 280, fitted: 0, minimum: 40),
            ColumnLayout.Column(id: "date", role: .fitted, preferred: 150, fitted: 300, minimum: 40),
        ]
        #expect(ColumnLayout.widths(long, available: 800) == ["name": 500, "date": 300])
        #expect(ColumnLayout.widths(long, available: 460) == ["name": 160, "date": 300])
        #expect(ColumnLayout.widths(long, available: 300) == ["name": 40, "date": 260])
    }

    /// Only Name shown: it takes all there is.
    @Test func nameAlone() {
        let only = [ColumnLayout.Column(id: "name", role: .name, preferred: 280, fitted: 0, minimum: 40)]
        #expect(ColumnLayout.widths(only, available: 500) == ["name": 500])
        #expect(ColumnLayout.widths(only, available: 100) == ["name": 100])
    }
}

/// The real file list, in a window whose width changes.
@MainActor
@Suite(.serialized)
final class ColumnWidthTests {
    private let workspace: Workspace
    private let list: FileListViewController
    private let window: NSWindow

    init() async throws {
        workspace = Workspace(initialLocation: "/home", home: "/home", lister: { _ in [] },
                              directoryCheck: { _ in true }, volumes: { [] }, watcher: FakeWatcher.factory)
        list = FileListViewController(workspace: workspace, side: .left)
        window = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 900, height: 400),
                          styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentViewController = list
        workspace.onChange = { [list] in list.render() }
        list.render()
        resize(900)
    }

    isolated deinit {
        window.close()
    }

    private func resize(_ width: CGFloat) {
        window.setContentSize(NSSize(width: width, height: 400))
        window.contentView?.layoutSubtreeIfNeeded()
        list.viewDidLayout()
    }

    private func width(_ id: NSUserInterfaceItemIdentifier) -> CGFloat {
        list.tableView.tableColumns.first { $0.identifier == id }?.width ?? 0
    }

    private func fitted(_ column: ListColumn) -> CGFloat {
        let tableColumn = list.tableView.tableColumns.first { $0.identifier.rawValue == column.rawValue }
        return list.fittedWidth(column, tableColumn ?? NSTableColumn())
    }

    /// Wide: the dates have their preferred width and Name the rest. Narrow: the dates go down to
    /// what they need before Name drops below a readable width.
    @Test func aNarrowSideTakesTheDatesSlackBeforeTheNames() {
        #expect(width(FileListViewController.modifiedColumn) == 150)
        let wideName = width(FileListViewController.nameColumn)
        #expect(wideName > 280)

        resize(480)
        let dateFits = fitted(.modified)
        #expect(dateFits < 150) // the slack there is to take
        #expect(width(FileListViewController.modifiedColumn) == dateFits.rounded(.down))
        #expect(width(FileListViewController.nameColumn) >= ColumnLayout.nameMinimum)

        resize(900) // and back
        #expect(width(FileListViewController.modifiedColumn) == 150)
        #expect(width(FileListViewController.nameColumn) == wideName)
    }

    /// A column the user drags keeps that width as its preferred one; Name makes room.
    @Test func aDraggedColumnKeepsItsWidth() {
        let name = width(FileListViewController.nameColumn)
        let column = list.tableView.tableColumns.first { $0.identifier == FileListViewController.sizeColumn }
        column?.width = 120 // as a drag does: AppKit posts the resize
        #expect(width(FileListViewController.sizeColumn) == 120)
        #expect(width(FileListViewController.nameColumn) == name - 40)
        #expect(list.preferredWidths[FileListViewController.sizeColumn.rawValue] == 120)
    }

    /// A bigger font: the dates need more, and get it.
    @Test func aBiggerFontRefitsTheDates() {
        resize(480)
        let before = width(FileListViewController.modifiedColumn)
        var settings = workspace.settings
        settings.font.size = 18
        workspace.settings = settings
        list.render()
        #expect(width(FileListViewController.modifiedColumn) > before)
    }

    /// Without a date column too: the permissions in a big mono font get what they need.
    @Test func aBiggerFontRefitsTheOtherColumns() {
        var settings = workspace.settings
        settings.columns = [.name, .size, .permissions]
        workspace.settings = settings
        list.render()
        #expect(width(FileListViewController.permissionsColumn) == 90)
        settings.font.size = 24
        workspace.settings = settings
        list.render()
        #expect(width(FileListViewController.permissionsColumn) > 90)
        #expect(width(FileListViewController.permissionsColumn) == fitted(.permissions).rounded(.down))
    }
}

/// Every size the formatter shows fits the Size column's fitted width (#123 review): the samples
/// cover each unit's digits.
@MainActor
struct SizeSampleTests {
    @Test func everyFormattedSizeFitsTheSizeColumn() {
        let workspace = Workspace(initialLocation: "/home", home: "/home", lister: { _ in [] },
                                  directoryCheck: { _ in true }, volumes: { [] }, watcher: FakeWatcher.factory)
        workspace.settings.font.size = 24
        let list = FileListViewController(workspace: workspace, side: .left)
        list.loadView()
        list.renderFonts()
        let column = list.tableView.tableColumns.first { $0.identifier == FileListViewController.sizeColumn }
        let fitted = list.fittedWidth(.size, column ?? NSTableColumn())
        var values: [Int64] = Array(0 ... 1100)
        for power in 1 ... 6 {
            let unit = pow(1000, Double(power))
            let spread = Array(stride(from: 1.0, to: 1000, by: 0.37))
            let mantissas = spread + Array(stride(from: 999.0, to: 1000, by: 0.0005))
            values += mantissas.map { Int64(min($0 * unit, 9.2e18)) } // below Int64.max
        }
        let widest = values.map { (Formatting.byteCount($0), $0) }
            .map { (($0.0 as NSString).size(withAttributes: [.font: list.fonts.tabular]).width, $0.0) }
            .max { $0.0 < $1.0 }
        #expect((widest?.0 ?? 0) + FileListViewController.cellPadding <= fitted, "\(widest?.1 ?? "")")
    }
}

/// The preferred widths across launches (#123 review): the widths from before #123 are taken over
/// and saved at once, so a narrow window cannot turn its cut widths into the preferences.
@MainActor
@Suite(.serialized)
final class PreferredWidthsTests {
    private let defaults: UserDefaults
    private let suite = "blitter-tests-preferred-widths-\(UUID().uuidString)"
    private let store: PreferredWidthsStore
    private var windows: [NSWindow] = []

    init() throws {
        defaults = try #require(UserDefaults(suiteName: suite))
        store = PreferredWidthsStore(defaults: defaults, key: "FileList-left-preferred")
    }

    isolated deinit {
        for window in windows {
            window.close()
        }
        defaults.removePersistentDomain(forName: suite)
    }

    /// A launch: a list on this store in a window this wide.
    private func launch(width: CGFloat, before: ((FileListViewController) -> Void)? = nil) -> FileListViewController {
        let workspace = Workspace(initialLocation: "/home", home: "/home", lister: { _ in [] },
                                  directoryCheck: { _ in true }, volumes: { [] }, watcher: FakeWatcher.factory)
        let list = FileListViewController(workspace: workspace, side: .left)
        list.preferredWidthsStore = store
        before?(list)
        let window = NSWindow(contentRect: NSRect(x: 100, y: 100, width: width, height: 400),
                              styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentViewController = list
        windows.append(window)
        list.render()
        window.setContentSize(NSSize(width: width, height: 400))
        window.contentView?.layoutSubtreeIfNeeded()
        list.viewDidLayout()
        return list
    }

    private func width(_ list: FileListViewController, _ id: NSUserInterfaceItemIdentifier) -> CGFloat {
        list.tableView.tableColumns.first { $0.identifier == id }?.width ?? 0
    }

    @Test func theWidthsFromBeforeAreKeptThroughANarrowLaunch() throws {
        // The first launch: AppKit restored a Date column the user had made 200 wide.
        let first = launch(width: 900)
        first.isLayingOutColumns = true // as AppKit's restore: not a drag
        first.tableView.tableColumns.first { $0.identifier == FileListViewController.modifiedColumn }?.width = 200
        first.isLayingOutColumns = false
        first.preferredWidths = [:]
        defaults.removeObject(forKey: store.key)
        first.loadPreferredWidths()
        let saved = try #require(store.load())
        #expect(saved[FileListViewController.modifiedColumn.rawValue] == 200)
        #expect(saved[FileListViewController.nameColumn.rawValue] == 280) // not the leftover

        // A narrow launch cuts the dates, without a drag; the preferences stay.
        let narrow = launch(width: 480)
        #expect(width(narrow, FileListViewController.modifiedColumn) < 200)
        #expect(store.load()?[FileListViewController.modifiedColumn.rawValue] == 200)

        // A wide launch again: the dates as the user had them.
        let wide = launch(width: 900)
        #expect(width(wide, FileListViewController.modifiedColumn) == 200)
    }

    /// No widths saved and none from before: the defaults are saved on the first launch.
    @Test func aFirstLaunchSavesTheDefaults() {
        _ = launch(width: 480)
        #expect(store.load()?[FileListViewController.modifiedColumn.rawValue] == 150)
        #expect(store.load()?[FileListViewController.sizeColumn.rawValue] == 80)
    }
}
