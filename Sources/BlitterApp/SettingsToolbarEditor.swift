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
                ActionIcon(symbol: icon ?? choice(id)?.symbol ?? "", app: icon == nil ? choice(id)?.app : nil)
                    .frame(width: 20)
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
            IconField(item: item, own: choice(id)?.symbol ?? "", app: choice(id)?.app)
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
    /// A tool's app, whose icon is the button's own while no symbol is typed (#110).
    let app: String?
    @State private var text = ""
    @State private var picking = false

    var body: some View {
        if case let .action(id, icon) = item {
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    TextField("Icon", text: $text, prompt: Text(own))
                    ActionIcon(symbol: icon ?? own, app: icon == nil ? app : nil).frame(width: 24)
                    Button("Choose…") { picking = true } // #111
                        .popover(isPresented: $picking, arrowEdge: .bottom) {
                            SymbolPicker(own: own, app: app) { name in
                                text = name
                                picking = false
                            }
                        }
                }
                Text("Choose… one, or type any SF Symbols name, e.g. folder.badge.plus (the SF Symbols app "
                    + "lists them). Empty: the action's own.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            .onAppear { text = icon ?? "" }
            .onChange(of: text) { item = .action(id, icon: Self.icon(for: text, own: ownSymbol)) }
            .onChange(of: icon) {
                if Self.icon(for: text, own: ownSymbol) != icon { // changed elsewhere (Revert)
                    text = icon ?? ""
                }
            }
        }
    }

    /// The symbol that is the button's own icon: none for a tool whose own icon is its app's
    /// (#110), where `own` (app.badge) typed in is a choice of its own (#110 review).
    var ownSymbol: String? {
        app == nil ? own : nil
    }

    /// What the text means as the item's icon: empty, or the action's own symbol, is none.
    static func icon(for text: String, own: String?) -> String? {
        let name = text.trimmingCharacters(in: .whitespaces)
        return name.isEmpty || name == own ? nil : name
    }
}

/// A button's icon as the toolbar shows it: the app's own icon (#110) once it is found, else the
/// symbol.
struct ActionIcon: View {
    let symbol: String
    let app: String?
    @State private var appIcon: NSImage?

    var body: some View {
        Group {
            if let appIcon {
                Image(nsImage: appIcon).resizable().scaledToFit().frame(width: 18, height: 18)
            } else {
                SymbolImage(name: symbol)
            }
        }
        .task(id: app) {
            appIcon = app.flatMap(AppIcons.shared.cached) // at once when known: no flicker
            if let app, appIcon == nil, let found = await Self.lookUp(app) {
                appIcon = found
            }
        }
    }

    /// The app's icon (nil: not found), or nothing when the view's task was cancelled meanwhile:
    /// the view shows another app or a symbol now, and the shared lookup ran on regardless
    /// (#110 review).
    static func lookUp(_ app: String) async -> NSImage?? {
        let icon = await AppIcons.shared.icon(for: app)
        return Task.isCancelled ? nil : .some(icon)
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
