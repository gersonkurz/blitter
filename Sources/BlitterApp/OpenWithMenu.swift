import AppKit
import BlitterModel
import UniformTypeIdentifiers

/// The apps that open the selected files (#109), as a submenu: Open With opens them with the
/// chosen app, Always Open … With makes it their kind's default. Filled each time it opens, from
/// Launch Services off the main thread; each choice runs a command on what the menu was opened
/// for.
@MainActor
final class OpenWithMenu: NSMenu, NSMenuDelegate {
    private let setsDefault: Bool
    /// The workspace and side to act on, asked when the menu opens.
    private let target: () -> (workspace: Workspace, side: Side)?
    /// What the menu acts on, taken when it opens: a selection changed while it is open (from
    /// automation, say) does not change what a choice does.
    private var workspace: Workspace?
    private var paths: [String] = []
    private var kind: FileKind?
    /// Counts the openings: a lookup for an earlier one shows nothing.
    private var generation = 0
    /// The lookup under way, cancelled when the menu closes or opens again.
    private(set) var lookup: Task<[AppChoice], Never>?

    init(setsDefault: Bool, target: @escaping () -> (workspace: Workspace, side: Side)?) {
        self.setsDefault = setsDefault
        self.target = target
        super.init(title: "")
        delegate = self
        autoenablesItems = false
    }

    @available(*, unavailable)
    required init(coder _: NSCoder) {
        fatalError("not made from a nib")
    }

    /// Shows "Looking for apps…" and Other… at once; Launch Services is asked off the main
    /// thread (it reads the files' and apps' details, which a slow volume can hold up), and the
    /// apps replace the placeholder when they come, if the menu is still the one they are for.
    func menuNeedsUpdate(_: NSMenu) {
        generation += 1
        removeAllItems()
        guard let (workspace, side) = target() else {
            return
        }
        self.workspace = workspace
        paths = workspace.selectedFilePaths(on: side)
        kind = setsDefault ? workspace.selectedKind(on: side) : nil
        guard !paths.isEmpty, !setsDefault || kind != nil else {
            return
        }
        addItem(withTitle: "Looking for apps…", action: nil, keyEquivalent: "").isEnabled = false
        addOther()
        let (generation, paths, type) = (generation, paths, kind?.contentType)
        lookup?.cancel()
        let lookup = Task.detached(priority: .userInitiated) {
            Self.lookUp(paths, defaultFor: type, isCancelled: { Task.isCancelled })
        }
        self.lookup = lookup
        Task { [weak self] in
            let choices = await lookup.value
            guard let self, generation == self.generation else {
                return // closed, or opened again: a newer lookup shows its own
            }
            show(choices)
        }
    }

    func menuDidClose(_: NSMenu) {
        generation += 1 // a lookup still running has nothing to show any more
        lookup?.cancel() // and stops at its next file or app
    }

    /// Replaces the placeholder with the apps (or nothing, when none open the files).
    func show(_ choices: [AppChoice]) {
        removeAllItems()
        for choice in choices {
            let title = !setsDefault && choice.isDefault ? "\(choice.name) (default)" : choice.name
            let item = addItem(withTitle: title, action: #selector(choose(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = choice.path
            item.image = choice.icon.image
            item.state = setsDefault && choice.isDefault ? .on : .off
        }
        if !choices.isEmpty {
            addItem(.separator())
        }
        addOther()
    }

    private func addOther() {
        let other = addItem(withTitle: "Other…", action: #selector(chooseOther(_:)), keyEquivalent: "")
        other.target = self
    }

    @objc private func choose(_ sender: NSMenuItem) {
        guard let app = sender.representedObject as? String, let workspace else {
            return
        }
        if setsDefault, let kind {
            workspace.perform(.setDefaultApp(app, for: kind))
        } else if !setsDefault {
            workspace.perform(.openWithApp(app, paths: paths, title: Workspace.openWithTitle(app)))
        }
    }

    /// For what the menu was opened for, as the listed apps are.
    @objc private func chooseOther(_: NSMenuItem) {
        guard let workspace else {
            return
        }
        if setsDefault, let kind {
            workspace.perform(.chooseApp(.setDefault(kind)))
        } else if !setsDefault {
            workspace.perform(.chooseApp(.open(paths)))
        }
    }

    /// An app in the menu, found off the main thread. The icon is not touched there again.
    struct AppChoice: @unchecked Sendable {
        let path: String
        let name: String
        let icon: SendableImage
        let isDefault: Bool
    }

    struct SendableImage: @unchecked Sendable {
        let image: NSImage
    }

    /// Off the main thread: the apps that open every one of the files, the default first, the
    /// others by name. Which apps can open a file Launch Services answers by kind, so one file
    /// per name extension is asked. The default is that of the content type `type` (Always Open
    /// … With: what it changes), or, without one, the app every file opens with now — a file can
    /// have one of its own (Get Info's Open with), so each file is asked; none when they differ.
    /// `isCancelled` is asked before each question to Launch Services and each icon: once it
    /// says so, nothing more is asked and nothing is found.
    nonisolated static func lookUp(_ paths: [String], defaultFor type: UTType?,
                                   isCancelled: () -> Bool) -> [AppChoice]
    {
        var stopped = false
        func cancelled() -> Bool { // once it says so, it is not asked again
            stopped = stopped || isCancelled()
            return stopped
        }
        let found = apps(for: paths, defaultFor: type, isCancelled: cancelled)
        var choices: [AppChoice] = []
        for app in found.apps {
            guard !cancelled() else {
                return []
            }
            let icon = NSWorkspace.shared.icon(forFile: app.path)
            icon.size = NSSize(width: 16, height: 16)
            choices.append(AppChoice(path: app.path, name: displayName(of: app), icon: SendableImage(image: icon),
                                     isDefault: app == found.defaultApp))
        }
        return choices
    }

    nonisolated static func apps(for paths: [String], defaultFor type: UTType? = nil,
                                 isCancelled: () -> Bool = { false }) -> (apps: [URL], defaultApp: URL?)
    {
        let files = paths.map { URL(fileURLWithPath: $0, isDirectory: false) }
        var seen: Set<String> = []
        let samples = files.filter { seen.insert($0.pathExtension.lowercased()).inserted }
        guard let first = samples.first, !isCancelled() else {
            return ([], nil)
        }
        let workspace = NSWorkspace.shared
        var apps = unique(workspace.urlsForApplications(toOpen: first))
        for sample in samples.dropFirst() {
            guard !isCancelled() else {
                return ([], nil)
            }
            let these = Set(workspace.urlsForApplications(toOpen: sample).map(\.standardizedFileURL))
            apps.removeAll { !these.contains($0) }
        }
        let defaultApp = type.map { workspace.urlForApplication(toOpen: $0)?.standardizedFileURL }
            ?? sharedDefault(of: files, isCancelled: isCancelled)
        guard !isCancelled() else {
            return ([], nil)
        }
        var named = apps.map { ($0, displayName(of: $0)) }
        named.sort { $0.1.localizedStandardCompare($1.1) == .orderedAscending }
        apps = named.map(\.0)
        if let defaultApp {
            apps.removeAll { $0 == defaultApp }
            apps.insert(defaultApp, at: 0) // listed even if Launch Services did not count it
        }
        return (apps, defaultApp)
    }

    /// The app every one of the files opens with now, or nil when they differ.
    private nonisolated static func sharedDefault(of files: [URL], isCancelled: () -> Bool) -> URL? {
        var shared: URL?
        for file in files {
            guard !isCancelled(), let app = NSWorkspace.shared.urlForApplication(toOpen: file)?.standardizedFileURL,
                  shared == nil || shared == app
            else {
                return nil
            }
            shared = app
        }
        return shared
    }

    private nonisolated static func unique(_ urls: [URL]) -> [URL] {
        var seen: Set<URL> = []
        return urls.map(\.standardizedFileURL).filter { seen.insert($0).inserted }
    }

    nonisolated static func displayName(of app: URL) -> String {
        let name = FileManager.default.displayName(atPath: app.path)
        return name.hasSuffix(".app") ? String(name.dropLast(4)) : name
    }

    // MARK: The system services

    /// Other…: an app from the Applications folder, chosen in an open panel (a sheet on the
    /// window when there is one).
    static func chooseApp(for window: NSWindow?, _ chosen: @escaping @MainActor (String?) -> Void) {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.applicationBundle]
        panel.directoryURL = URL(fileURLWithPath: "/Applications", isDirectory: true)
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.treatsFilePackagesAsDirectories = false
        panel.prompt = "Choose"
        let done: (NSApplication.ModalResponse) -> Void = { response in
            chosen(response == .OK ? panel.url?.path : nil)
        }
        if let window {
            panel.beginSheetModal(for: window, completionHandler: done)
        } else {
            panel.begin(completionHandler: done)
        }
    }

    /// As Finder's Change All: Launch Services makes the app the type's default.
    static func setDefaultApp(_ app: String, _ contentType: String, _ done: @escaping @MainActor (String?) -> Void) {
        guard let type = UTType(contentType) else {
            done("macOS does not know the kind “\(contentType)”.")
            return
        }
        NSWorkspace.shared.setDefaultApplication(at: URL(fileURLWithPath: app, isDirectory: true),
                                                 toOpen: type)
        { error in
            Task { @MainActor in done(error?.localizedDescription) }
        }
    }
}
