import BlitterModel
import SwiftUI

/// A list whose items are arranged by hand (#65): new items go after the selected one, ↑ and ↓
/// move it, − removes it; below the list, what the selected item has to edit.
struct OrderedListEditor<Item, Row: View, Add: View, Detail: View>: View {
    @Binding var items: [Item]
    @Binding var selection: Int?
    let row: (Item) -> Row
    /// The Add control; it inserts with the function it is given.
    let add: (@escaping (Item) -> Void) -> Add
    let detail: (Binding<Item>) -> Detail
    /// A double-click on an item.
    var open: (Int) -> Void = { _ in }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            List(selection: $selection) {
                ForEach(items.indices, id: \.self) { index in
                    row(items[index]).tag(index)
                }
            }
            .contextMenu(forSelectionType: Int.self, menu: { _ in }, primaryAction: { rows in
                if let row = rows.first {
                    open(row)
                }
            })
            HStack(spacing: 4) {
                add(insert)
                Spacer()
                Button { move(by: -1) } label: { Image(systemName: "arrow.up") }
                    .disabled(!canMove(by: -1)).help("Move up")
                Button { move(by: 1) } label: { Image(systemName: "arrow.down") }
                    .disabled(!canMove(by: 1)).help("Move down")
                Button(action: remove) { Image(systemName: "minus") }
                    .disabled(selected == nil).help("Remove")
            }
            if let index = selected {
                detail(binding(index))
            }
        }
    }

    private var selected: Int? {
        selection.flatMap { items.indices.contains($0) ? $0 : nil }
    }

    /// The item at `index` while it is there; a removal must not leave the detail reading past
    /// the end.
    private func binding(_ index: Int) -> Binding<Item> {
        let shown = items[index]
        return Binding(
            get: { items.indices.contains(index) ? items[index] : shown },
            set: { item in
                if items.indices.contains(index) {
                    items[index] = item
                }
            }
        )
    }

    private func insert(_ item: Item) {
        let index = selected.map { $0 + 1 } ?? items.count
        items.insert(item, at: index)
        selection = index
    }

    private func canMove(by offset: Int) -> Bool {
        selected.map { items.indices.contains($0 + offset) } ?? false
    }

    private func move(by offset: Int) {
        guard let index = selected, canMove(by: offset) else {
            return
        }
        items.swapAt(index, index + offset)
        selection = index + offset
    }

    private func remove() {
        guard let index = selected else {
            return
        }
        items.remove(at: index)
        selection = items.isEmpty ? nil : min(index, items.count - 1)
    }
}

/// A context menu: actions, separators and submenus. A double-click (or Open) goes into a
/// submenu, Back out of it.
struct MenuEditor: View {
    @Binding var menu: [MenuEntry]
    let choices: [ActionChoice]
    /// The submenu shown: the positions of the submenus on the way; [] is the menu itself.
    @Binding var path: [Int]
    @State private var selection: Int?

    var body: some View {
        // The menu may have changed under the submenu shown (Revert, a removal): only as much of
        // the path as still leads through submenus counts.
        let shown = menu.validSubmenuPath(path)
        VStack(alignment: .leading, spacing: 6) {
            if !shown.isEmpty {
                HStack {
                    Button { leave() } label: { Label("Back", systemImage: "chevron.left") }
                    Text(menu.submenuTitles(shown).joined(separator: " › ")).foregroundStyle(.secondary)
                }
            }
            OrderedListEditor(items: $menu[submenu: shown], selection: $selection, row: row, add: addMenu,
                              detail: detail, open: enter)
        }
        .onChange(of: menu) {
            if menu.validSubmenuPath(path) != path {
                path = menu.validSubmenuPath(path)
                selection = nil
            }
        }
    }

    @ViewBuilder private func row(_ entry: MenuEntry) -> some View {
        switch entry {
        case let .action(id):
            HStack {
                Text(choices.first { $0.id == id }?.title ?? id)
                Spacer()
                Text(id).foregroundStyle(.secondary)
            }
        case .separator:
            Text("Separator").foregroundStyle(.secondary).frame(maxWidth: .infinity)
        case let .submenu(title, inner):
            HStack {
                Label(title, systemImage: "chevron.right.square")
                Spacer()
                Text(inner.count == 1 ? "1 entry" : "\(inner.count) entries").foregroundStyle(.secondary)
            }
        }
    }

    private func addMenu(_ insert: @escaping (MenuEntry) -> Void) -> some View {
        Menu("Add") {
            Menu("Action") {
                ForEach(choices) { choice in
                    Button(choice.title) { insert(.action(choice.id)) }
                }
            }
            Button("Separator") { insert(.separator) }
            Button("Submenu") { insert(.submenu("Submenu", [])) }
        }
        .fixedSize()
    }

    @ViewBuilder private func detail(_ entry: Binding<MenuEntry>) -> some View {
        if case let .submenu(title, inner) = entry.wrappedValue {
            HStack {
                TextField("Submenu title", text: Binding(get: { title },
                                                         set: { entry.wrappedValue = .submenu($0, inner) }))
                Button("Open") { selection.map(enter) }
            }
        }
    }

    private func enter(_ index: Int) {
        let level = menu[submenu: path]
        guard level.indices.contains(index), case .submenu = level[index] else {
            return
        }
        path.append(index)
        selection = nil
    }

    private func leave() {
        path = menu.validSubmenuPath(path)
        selection = path.popLast()
    }
}

/// The File or Edit menu's action items, with their shortcuts.
struct MenuBarEditor: View {
    @Binding var items: [MenuBarItem]
    let choices: [ActionChoice]
    /// A shortcut typed that is none yet.
    @Binding var problem: String?
    @State private var selection: Int?

    var body: some View {
        OrderedListEditor(items: $items, selection: $selection, row: row, add: addMenu, detail: detail)
    }

    @ViewBuilder private func row(_ item: MenuBarItem) -> some View {
        switch item {
        case let .action(id, shortcut, alternate):
            HStack {
                Text(choices.first { $0.id == id }?.title ?? id)
                if alternate {
                    Text("(alternate)").foregroundStyle(.secondary)
                }
                Spacer()
                Text(shortcut?.glyphs ?? "").monospaced()
            }
        case .separator:
            Text("Separator").foregroundStyle(.secondary).frame(maxWidth: .infinity)
        }
    }

    private func addMenu(_ insert: @escaping (MenuBarItem) -> Void) -> some View {
        Menu("Add") {
            Menu("Action") {
                ForEach(choices) { choice in
                    Button(choice.title) { insert(.action(choice.id, shortcut: nil, alternate: false)) }
                }
            }
            Button("Separator") { insert(.separator) }
        }
        .fixedSize()
    }

    @ViewBuilder private func detail(_ item: Binding<MenuBarItem>) -> some View {
        if case .action = item.wrappedValue {
            // A field of its own per item shown: another selection, or a removal or insertion that
            // puts another item at the same place, starts afresh, whatever the items' shortcuts
            // (and drops what was typed, see ShortcutField).
            ShortcutField(item: item, problem: $problem).id(FieldID(selection: selection, count: items.count))
        }
    }
}

private struct FieldID: Hashable {
    let selection: Int?
    let count: Int
}

/// The selected item's shortcut, typed as the settings file writes it ("shift+cmd+n", "f2"),
/// and whether it is an alternate. Text that is no shortcut yet is the field's `problem` (Save
/// waits) while the field is there; when it goes (another item, pane or tab), so does that text.
struct ShortcutField: View {
    @Binding var item: MenuBarItem
    @Binding var problem: String?
    @State private var text = ""

    var body: some View {
        if case let .action(id, shortcut, alternate) = item {
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    TextField("Shortcut", text: $text, prompt: Text("none, or e.g. shift+cmd+n, f2"))
                    Text(Shortcut(text)?.glyphs ?? "").monospaced().frame(minWidth: 60)
                }
                if let problem {
                    Text(problem).font(.caption).foregroundStyle(.red)
                }
                Toggle("Alternate: shown in place of the item before it while the extra modifier is held",
                       isOn: Binding(get: { alternate },
                                     set: { item = .action(id, shortcut: shortcut, alternate: $0) }))
            }
            .onAppear { text = shortcut?.text ?? "" }
            .onDisappear { problem = nil }
            .onChange(of: text) { take(text, id: id, alternate: alternate) }
            .onChange(of: shortcut) {
                if Shortcut(text) != shortcut, !(text.isEmpty && shortcut == nil) { // Revert
                    text = shortcut?.text ?? ""
                }
            }
        }
    }

    private func take(_ text: String, id: String, alternate: Bool) {
        let typed = text.trimmingCharacters(in: .whitespaces)
        if typed.isEmpty {
            problem = nil
            item = .action(id, shortcut: nil, alternate: alternate)
        } else if let shortcut = Shortcut(typed) {
            problem = nil
            item = .action(id, shortcut: shortcut, alternate: alternate)
        } else {
            problem = "“\(typed)” is not a shortcut: modifiers (cmd, shift, opt, ctrl) and a key, joined by +."
        }
    }
}
