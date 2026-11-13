import AppKit
import BlitterModel
import SwiftUI

/// The toolbar's buttons (#88): actions, each with its icon, and gaps. The selected button's
/// icon can be another SF Symbol; empty keeps the action's own.
struct ToolbarEditor: View {
    @Binding var items: [ToolbarEntry]
    let choices: [ActionChoice]
    @State private var selection: Int?

    var body: some View {
        OrderedListEditor(items: $items, selection: $selection, row: row, add: addMenu, detail: detail)
    }

    private func choice(_ id: String) -> ActionChoice? {
        choices.first { $0.id == id }
    }

    @ViewBuilder private func row(_ item: ToolbarEntry) -> some View {
        switch item {
        case let .action(id, icon):
            HStack {
                SymbolImage(name: icon ?? choice(id)?.symbol ?? "").frame(width: 20)
                Text(choice(id)?.title ?? id)
                Spacer()
                Text(id).foregroundStyle(.secondary)
            }
        case .gap:
            Text("Gap").foregroundStyle(.secondary).frame(maxWidth: .infinity)
        }
    }

    private func addMenu(_ insert: @escaping (ToolbarEntry) -> Void) -> some View {
        Menu("Add") {
            Menu("Action") {
                ForEach(choices) { choice in
                    Button(choice.title) { insert(.action(choice.id, icon: nil)) }
                }
            }
            Button("Gap") { insert(.gap) }
        }
        .fixedSize()
    }

    @ViewBuilder private func detail(_ item: Binding<ToolbarEntry>) -> some View {
        if case let .action(id, _) = item.wrappedValue {
            // A field of its own per button shown, as the shortcut field's (FieldID).
            IconField(item: item, own: choice(id)?.symbol ?? "")
                .id(FieldID(selection: selection, count: items.count))
        }
    }
}

/// The selected button's icon. The field keeps what is typed: a name on the way to another
/// ("trash" while typing "trash.fill") is not cleared because it is the action's own (#88
/// review). Only what it means goes into the item: the action's own name, or none, is no icon
/// of its own.
struct IconField: View {
    @Binding var item: ToolbarEntry
    /// The action's own symbol.
    let own: String
    @State private var text = ""

    var body: some View {
        if case let .action(id, icon) = item {
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    TextField("Icon", text: $text, prompt: Text(own))
                    SymbolImage(name: icon ?? own).frame(width: 24)
                }
                Text("An SF Symbols name, e.g. star or folder.badge.plus (the SF Symbols app lists them). "
                    + "Empty: the action's own.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            .onAppear { text = icon ?? "" }
            .onChange(of: text) { item = .action(id, icon: Self.icon(for: text, own: own)) }
            .onChange(of: icon) {
                if Self.icon(for: text, own: own) != icon { // changed elsewhere (Revert)
                    text = icon ?? ""
                }
            }
        }
    }

    /// What the text means as the item's icon.
    static func icon(for text: String, own: String) -> String? {
        let name = text.trimmingCharacters(in: .whitespaces)
        return name.isEmpty || name == own ? nil : name
    }
}

/// An SF Symbol by name, or the toolbar's sign for a name that is none.
struct SymbolImage: View {
    let name: String

    var body: some View {
        let known = NSImage(systemSymbolName: name, accessibilityDescription: nil) != nil
        Image(systemName: known ? name : WindowToolbar.unknownSymbol)
    }
}
