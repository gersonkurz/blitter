import AppKit
@testable import Blitter
@testable import BlitterCore
@testable import BlitterModel
import Testing

/// Themes in the views (#21): the file list, the tree and the jobs strip in a window.
@MainActor
@Suite(.serialized)
final class ThemeInteractionTests {
    private let workspace: Workspace
    private let side: SideViewController
    private let jobs: JobsViewController
    private let window: NSWindow

    init() async throws {
        var hidden = file(".hidden")
        hidden.isHidden = true
        var script = file("run.sh")
        script.permissions = 0o755
        let entries = [folder("sub"), file("a.txt"), hidden, script]
        workspace = Workspace(initialLocation: "/fake", home: "/fake", lister: { path in
            guard path == "/fake" else {
                throw POSIXError(.EACCES)
            }
            return entries
        }, directoryCheck: { _ in false }, volumes: { [] }, watcher: FakeWatcher.factory,
        // Every trash fails, so a job ends with a problem; nothing is ever really trashed.
        jobs: JobQueue(trash: { _ in throw POSIXError(.EACCES) }))
        workspace.perform(.toggleHiddenFiles)
        side = SideViewController(workspace: workspace, side: .left)
        jobs = JobsViewController(workspace: workspace)
        window = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 900, height: 500),
                          styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentViewController = side
        _ = jobs.view
        workspace.onChange = { [side, jobs] in
            side.render()
            jobs.render()
        }
        window.makeKeyAndOrderFront(nil)
        for _ in 0 ..< 200 where workspace.state(of: .left).visibleEntries.count < 4 {
            try await Task.sleep(for: .milliseconds(10))
        }
        workspace.onChange?()
        side.view.layoutSubtreeIfNeeded()
    }

    isolated deinit {
        window.close()
    }

    @Test func theSystemThemeKeepsMacOSsLook() throws {
        let table = list.tableView
        #expect(table.usesAlternatingRowBackgroundColors)
        #expect(table.backgroundColor == .controlBackgroundColor)
        #expect(table.rowView(atRow: 0, makeIfNecessary: true).map { $0 is ThemedRowView } == false)
        #expect(try textColor(".hidden") == .secondaryLabelColor && textColor("sub") == .labelColor)
        #expect(try textColor("run.sh") == .labelColor) // executables are colored only by a theme (#31)
    }

    @Test func aSchemeColorsTheListTreeAndJobsStripAndCanBeTurnedOffAgain() throws {
        setScheme("solarized-dark")
        let table = list.tableView
        #expect(!table.usesAlternatingRowBackgroundColors)
        #expect(try hex(#require(table.backgroundColor)) == "002b36") // base00
        #expect(table.rowView(atRow: 0, makeIfNecessary: true) is ThemedRowView)
        #expect(try hex(textColor("sub")) == "268bd2") // folder: base0D
        #expect(try hex(textColor(".hidden")) == "657b83") // hidden: base03
        #expect(try hex(textColor("a.txt")) == "93a1a1") // text: base05
        #expect(try hex(textColor("run.sh")) == "859900") // executable: base0B (#31)

        // A dark scheme draws controls, icons and headers dark, whatever the window's mode.
        #expect(list.view.appearance?.name == .darkAqua)
        #expect(list.view.layer?.backgroundColor.flatMap(NSColor.init(cgColor:)).map(hex) == "002b36")
        #expect(side.splitViewItems[0].viewController.view.appearance?.name == .darkAqua)
        let outline = try #require(treeOutline)
        #expect(try hex(#require(outline.backgroundColor)) == "002b36")
        #expect(outline.rowView(atRow: 0, makeIfNecessary: true) is ThemedRowView)

        workspace.addNotice("Settings file: something.")
        workspace.onChange?()
        let notice = try #require(noticeText)
        #expect(hex(notice.textColor ?? .clear) == "dc322f") // error: base08

        setScheme("solarized-light")
        #expect(list.view.appearance?.name == .aqua)

        setScheme("system")
        #expect(list.view.appearance == nil)
        #expect(list.view.layer?.backgroundColor == nil)
        #expect(table.usesAlternatingRowBackgroundColors)
        #expect(table.rowView(atRow: 0, makeIfNecessary: true).map { $0 is ThemedRowView } == false)
        #expect(try textColor("sub") == .labelColor)
        #expect(notice.textColor == .systemOrange)
    }

    /// Failures read as errors: a folder that cannot be read, and a job that ended with problems.
    @Test func failuresTakeTheErrorColor() async throws {
        workspace.perform(.select(.left, ["a.txt"]))
        workspace.perform(.trashSelection(.left))
        for _ in 0 ..< 300 where workspace.jobs.first?.isDone != true {
            try await Task.sleep(for: .milliseconds(10))
        }
        workspace.perform(.navigate(.left, path: "/locked"))
        for _ in 0 ..< 300 where workspace.state(of: .left).status == .loading {
            try await Task.sleep(for: .milliseconds(10))
        }
        workspace.onChange?()
        let status = try #require(label(in: list.view) { $0.hasPrefix("/locked: ") }) // not the path field
        let title = "Moving “a.txt” to the Trash"
        let problem = try #require(label(in: jobs.view) { $0.contains("a.txt") && $0 != title })
        #expect(status.textColor == .secondaryLabelColor && problem.textColor == .secondaryLabelColor) // system

        setScheme("solarized-dark")
        #expect(hex(status.textColor ?? .clear) == "dc322f")
        #expect(hex(problem.textColor ?? .clear) == "dc322f")
        let titleLabel = try #require(label(in: jobs.view) { $0 == title })
        #expect(hex(titleLabel.textColor ?? .clear) == "93a1a1") // the title stays text
    }

    @Test func anUnchangedThemeBuildsNoNewPalette() throws {
        let view = list.view
        let current = try #require(Palette.changed(from: nil, workspace.settings.theme, for: view))
        #expect(Palette.changed(from: current, workspace.settings.theme, for: view) == nil)
        var other = workspace.settings.theme
        other.light = "solarized-dark"
        other.dark = "solarized-dark"
        #expect(Palette.changed(from: current, other, for: view) != nil)
    }

    @Test func lightAndDarkModeTakeTheirOwnScheme() throws {
        var settings = ThemeSettings()
        settings.light = "default-light"
        settings.dark = "solarized-dark"
        let light = try Palette(settings,
                                appearance: #require(
                                    NSAppearance(named: .aqua)
                                )) // swiftlint:disable:this force_unwrapping
        let dark = try Palette(settings,
                               appearance: #require(
                                   NSAppearance(named: .darkAqua)
                               )) // swiftlint:disable:this force_unwrapping
        #expect(hex(light.color(.background)) == "f8f8f8")
        #expect(hex(dark.color(.background)) == "002b36")
    }

    // MARK: Helpers

    private var list: FileListViewController {
        // swiftlint:disable:next force_cast
        side.splitViewItems[1].viewController as! FileListViewController
    }

    private var treeOutline: NSOutlineView? {
        (side.splitViewItems[0].viewController.view as? NSScrollView)?.documentView as? NSOutlineView
    }

    private var noticeText: NSTextField? {
        jobs.view.subviews.compactMap { $0 as? NoticeRowView }.first?.text
    }

    private func label(in view: NSView, _ matches: (String) -> Bool) -> NSTextField? {
        if let field = view as? NSTextField, matches(field.stringValue) {
            return field
        }
        for subview in view.subviews {
            if let field = label(in: subview, matches) {
                return field
            }
        }
        return nil
    }

    private func setScheme(_ name: String) {
        workspace.settings.theme.light = name
        workspace.settings.theme.dark = name
        workspace.onChange?()
        side.view.layoutSubtreeIfNeeded()
    }

    private func textColor(_ name: String) throws -> NSColor {
        let table = list.tableView
        let row = try #require(list.entries.firstIndex { $0.entry.name == name })
        let cell = table.view(atColumn: 0, row: row, makeIfNecessary: true) as? NSTableCellView
        return try #require(cell?.textField?.textColor)
    }

    private func hex(_ color: NSColor) -> String {
        guard let rgb = color.usingColorSpace(.sRGB) else {
            return "?"
        }
        return String(format: "%02x%02x%02x", Int((rgb.redComponent * 255).rounded()),
                      Int((rgb.greenComponent * 255).rounded()), Int((rgb.blueComponent * 255).rounded()))
    }
}
