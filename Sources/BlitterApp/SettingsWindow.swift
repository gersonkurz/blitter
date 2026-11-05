import AppKit
import BlitterModel
import SwiftUI

/// The Settings window's state (#64): the settings file as it was read, and the draft the window
/// shows. Save writes what changed into the file as it is then (a command); Revert drops the
/// draft. While nothing is edited, the window follows the file when it changes.
@MainActor
@Observable
final class SettingsWindowModel {
    private let workspace: Workspace
    private(set) var document: SettingsDocument?
    private(set) var original = BlitterModel.Settings()
    var draft = BlitterModel.Settings() {
        didSet {
            if draft != oldValue {
                draftProblems = draft.problems
            }
        }
    }

    var tab = SettingsTab.files
    /// What the file could not hold, as entered: Save waits until there is none.
    private(set) var draftProblems: [String] = []
    /// While a save runs: Save waits, and the file is not read again.
    private(set) var isSaving = false
    /// Why the last save failed; the draft keeps its changes, to save again.
    private(set) var saveProblem: String?
    private var readsSeen = -1
    private var loading: Task<Void, Never>?
    /// How the file is read: the workspace's document (tests make it wait).
    private let read: () async -> SettingsDocument

    init(workspace: Workspace, read: (() async -> SettingsDocument)? = nil) {
        self.workspace = workspace
        self.read = read ?? { await workspace.readSettingsDocument() }
        load()
    }

    var isDirty: Bool {
        draft != original
    }

    var canSave: Bool {
        isDirty && !isSaving && draftProblems.isEmpty && document?.canBeSaved == true
    }

    /// Reads the file and shows it. Edits made while it was being read are kept: they are applied
    /// to what was read, entry by entry, as Save applies them to the file.
    func load() {
        readsSeen = workspace.settingsReads
        loading?.cancel()
        let draftBefore = draft
        loading = Task { [weak self, read] in
            let document = await read()
            guard !Task.isCancelled, let self else {
                return
            }
            self.document = document
            original = document.settings
            draft = document.settings.applying(changesFrom: draftBefore, to: draft)
            draftProblems = isDirty ? draft.problems : []
            loading = nil
        }
    }

    /// The settings were read again (a save, an editor, a zoom): shown, unless the draft has changes.
    func workspaceChanged() {
        if workspace.settingsReads != readsSeen, !isDirty, !isSaving {
            load()
        }
    }

    /// The draft is clean only once it is in the file: a failed save keeps the changes, and
    /// changes made while saving stay changes.
    func save() {
        guard canSave else {
            return
        }
        let saved = draft
        isSaving = true
        saveProblem = nil
        workspace.perform(.saveSettings(original: original, edited: saved))
        Task { [weak self, workspace] in
            let problem = await workspace.finishSavingSettings()
            guard let self else {
                return
            }
            isSaving = false
            if let problem {
                saveProblem = problem
            } else {
                original = saved
                workspaceChanged() // the file as saved, unless editing went on
            }
        }
    }

    func revert() {
        draft = original
    }

    func openFile() {
        workspace.perform(.openSettingsFile)
    }

    /// Installed font families, and those of them with fixed-width letters, for the pickers.
    static let families: (all: [String], fixedWidth: [String]) = {
        let manager = NSFontManager.shared
        let all = manager.availableFontFamilies.filter { !$0.hasPrefix(".") }.sorted()
        let fixed = all.filter { manager.font(withFamily: $0, traits: [], weight: 5, size: 12)?.isFixedPitch == true }
        return (all, fixed)
    }()
}

enum SettingsTab: CaseIterable {
    case files, fonts, colors, compare, tools

    var title: String {
        switch self {
        case .files: "Files"
        case .fonts: "Fonts"
        case .colors: "Colors"
        case .compare: "Compare"
        case .tools: "Tools & Menus"
        }
    }
}

/// One window, opened by Settings… (⌘,).
@MainActor
final class SettingsWindowController: NSWindowController, NSWindowDelegate {
    let model: SettingsWindowModel
    private(set) static var current: SettingsWindowController?

    static func show(_ workspace: Workspace) {
        let controller = current ?? SettingsWindowController(workspace: workspace)
        current = controller
        controller.showWindow(nil)
        controller.window?.makeKeyAndOrderFront(nil)
    }

    private init(workspace: Workspace) {
        model = SettingsWindowModel(workspace: workspace)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 620, height: 520),
                              styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.title = "Settings"
        window.isReleasedWhenClosed = false
        window.contentViewController = NSHostingController(rootView: SettingsView(model: model))
        window.setContentSize(NSSize(width: 620, height: 520))
        window.center()
        super.init(window: window)
        window.delegate = self
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    func windowWillClose(_: Notification) {
        Self.current = nil // a new window reads the file again
    }
}

struct SettingsView: View {
    @Bindable var model: SettingsWindowModel

    var body: some View {
        VStack(spacing: 0) {
            // A segmented control, not a TabView: a window's TabView moves its tabs into the title
            // bar, where they collapse behind an overflow button.
            Picker("", selection: $model.tab) {
                ForEach(SettingsTab.allCases, id: \.self) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
            .padding(.top, 12)
            Group {
                switch model.tab {
                case .files: FilesSettings(draft: $model.draft)
                case .fonts: FontSettingsView(font: $model.draft.font)
                case .colors: ColorSettings(theme: $model.draft.theme)
                case .compare: CompareSettings(tool: $model.draft.diffTool)
                case .tools: ToolsSettings(open: model.openFile)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            Divider().padding(.top, 8)
            footer.padding()
        }
        .frame(minWidth: 560, minHeight: 460)
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let document = model.document, !document.canBeSaved {
                Label("The settings file cannot be read as a whole; fix it in a text editor first.",
                      systemImage: "exclamationmark.triangle").foregroundStyle(.red)
            } else if let problems = model.document?.problems, !problems.isEmpty {
                Label("Problems in the settings file; saving writes these entries with their defaults: "
                    + problems.joined(separator: " "), systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.orange)
            }
            if let problem = model.saveProblem {
                Label(problem, systemImage: "xmark.octagon").foregroundStyle(.red)
            }
            ForEach(model.draftProblems, id: \.self) { problem in
                Label(problem, systemImage: "xmark.octagon").foregroundStyle(.red)
            }
            HStack {
                Text("Saving writes the whole settings file; comments of your own in it are not kept.")
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Open Settings File", action: model.openFile)
                Button("Revert", action: model.revert).disabled(!model.isDirty)
                Button("Save", action: model.save).keyboardShortcut("s").disabled(!model.canSave)
            }
        }
        .font(.callout)
        .lineLimit(3)
    }
}
