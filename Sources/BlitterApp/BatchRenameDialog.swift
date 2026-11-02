import AppKit
import BlitterModel
import SwiftUI

/// Batch Rename's state: the rule being edited and what it would do, read from the workspace
/// after every change of the rule and whenever the side's listing or selection changed (a file
/// deleted meanwhile): Rename carries out exactly what is shown. The rule is offered again next
/// time, for this run of the app.
@MainActor
@Observable
final class BatchRenameModel {
    private let workspace: Workspace
    let side: Side
    var rule: BatchRename {
        didSet {
            Self.lastRule = rule
            preview = workspace.batchRenamePreview(side, rule)
        }
    }

    /// What the preview was made from, besides the rule.
    private var shownFrom: (version: Int, selection: Set<String>)

    private(set) var preview: BatchRenamePreview
    /// Called once the dialog is done, renamed or not.
    var onClose: (() -> Void)?
    static var lastRule = BatchRename()

    init(workspace: Workspace, side: Side) {
        self.workspace = workspace
        self.side = side
        rule = Self.lastRule
        preview = workspace.batchRenamePreview(side, Self.lastRule)
        let state = workspace.state(of: side)
        shownFrom = (state.entriesVersion, state.selection)
    }

    /// After a workspace change: the preview is made again if the listing or the selection changed.
    func refresh() {
        let state = workspace.state(of: side)
        guard state.entriesVersion != shownFrom.version || state.selection != shownFrom.selection else {
            return
        }
        shownFrom = (state.entriesVersion, state.selection)
        preview = workspace.batchRenamePreview(side, rule)
    }

    /// The line below the preview: the first problem, or how many names change.
    var status: String {
        if let problem = preview.problem ?? preview.rows.first(where: { $0.problem != nil })?.problem {
            return problem
        }
        let total = preview.rows.count
        let change = total == 1 ? "name changes" : "names change"
        return "\(preview.changeCount.formatted()) of \(total.formatted()) \(change)"
    }

    func rename() {
        workspace.perform(.batchRename(side, preview))
        onClose?()
    }

    func cancel() {
        workspace.perform(.cancelBatchRename)
        onClose?()
    }
}

struct BatchRenameView: View {
    @Bindable var model: BatchRenameModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Form {
                TextField("Find:", text: $model.rule.find)
                TextField("Replace with:", text: $model.rule.replace)
                HStack {
                    Toggle("Regular expression", isOn: $model.rule.usesRegex)
                    Toggle("Ignore case", isOn: $model.rule.ignoresCase)
                    Toggle("Include extension", isOn: $model.rule.includesExtension)
                }
                TextField("New name:", text: $model.rule.template, prompt: Text("{name}"))
                TextField("Counter starts at:", value: $model.rule.counterStart, format: .number)
                Picker("Name case:", selection: $model.rule.nameCase) { caseOptions }
                Picker("Extension case:", selection: $model.rule.extensionCase) { caseOptions }
            }
            Text("{name} is the name after Find and Replace, {n} the counter, {n:3} with three digits.")
                .font(.caption).foregroundStyle(.secondary)
            List(model.preview.rows.indices, id: \.self) { index in
                row(model.preview.rows[index])
            }
            .frame(minHeight: 200)
            Text(model.status).foregroundStyle(model.preview.canRename ? Color.secondary : Color.red)
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { model.cancel() }.keyboardShortcut(.cancelAction)
                Button("Rename") { model.rename() }.keyboardShortcut(.defaultAction)
                    .disabled(!model.preview.canRename)
            }
        }
        .padding(20)
        .frame(width: 560)
    }

    @ViewBuilder private var caseOptions: some View {
        Text("Unchanged").tag(BatchRename.CaseChange.unchanged)
        Text("lowercase").tag(BatchRename.CaseChange.lower)
        Text("UPPERCASE").tag(BatchRename.CaseChange.upper)
        Text("Title Case").tag(BatchRename.CaseChange.title)
    }

    private func row(_ row: BatchRenamePreview.Row) -> some View {
        HStack {
            Text(row.oldName).lineLimit(1).truncationMode(.middle).frame(maxWidth: .infinity, alignment: .leading)
            Image(systemName: "arrow.right").foregroundStyle(.secondary)
            Text(row.newName).lineLimit(1).truncationMode(.middle).frame(maxWidth: .infinity, alignment: .leading)
                .foregroundStyle(row.problem != nil ? Color.red : row.changes ? Color.primary : Color.secondary)
                .help(row.problem ?? "")
        }
    }
}
