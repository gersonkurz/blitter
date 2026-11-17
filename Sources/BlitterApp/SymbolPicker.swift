import AppKit
import SwiftUI

/// Picking a toolbar button's icon (#111): a searchable grid of SF Symbols that suit a file
/// manager's buttons, and the action's own icon. Any other symbol can still be typed by name.
struct SymbolPicker: View {
    /// The action's own icon, offered first as "Default".
    let own: String
    let app: String?
    /// Called with the chosen name, or "" for the action's own icon.
    let pick: (String) -> Void
    @State private var search = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            TextField("Search", text: $search, prompt: Text("Search, e.g. folder"))
                .textFieldStyle(.roundedBorder)
            Button {
                pick("")
            } label: {
                HStack {
                    ActionIcon(symbol: own, app: app).frame(width: 20)
                    Text("Default")
                }
            }
            .buttonStyle(.borderless)
            ScrollView {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 34), spacing: 4)], spacing: 4) {
                    ForEach(Self.matching(search), id: \.self) { name in
                        Button {
                            pick(name)
                        } label: {
                            Image(systemName: name).font(.system(size: 16)).frame(width: 30, height: 26)
                        }
                        .buttonStyle(.borderless)
                        .help(name)
                        .accessibilityLabel(name)
                    }
                }
            }
            .frame(height: 220)
        }
        .padding(12)
        .frame(width: 320)
    }

    /// The offered symbols whose names contain every word of the search (any case); all for an
    /// empty search.
    static func matching(_ search: String) -> [String] {
        let words = search.lowercased().split(whereSeparator: { $0 == " " || $0 == "." }).map(String.init)
        return available.filter { name in words.allSatisfy { name.contains($0) } }
    }

    /// The offered symbols this macOS has, in the list's order.
    static let available = symbols.filter { NSImage(systemSymbolName: $0, accessibilityDescription: nil) != nil }

    /// Grouped by what a button does: files and folders, places, moving things, tools, marks,
    /// media, and the rest.
    static let symbols = [
        "folder", "folder.fill", "folder.badge.plus", "folder.badge.gearshape", "folder.badge.person.crop",
        "doc", "doc.fill", "doc.text", "doc.richtext", "doc.on.doc", "doc.badge.plus", "doc.zipper",
        "archivebox", "archivebox.fill", "shippingbox", "cube", "tray", "tray.full",
        "externaldrive", "internaldrive", "opticaldiscdrive", "server.rack", "network", "globe", "icloud",
        "cloud", "house", "desktopcomputer", "laptopcomputer",
        "arrow.clockwise", "arrow.triangle.2.circlepath", "arrow.left.arrow.right", "arrow.up.arrow.down",
        "arrow.right.square", "arrow.up.forward.app", "arrow.down.circle", "arrow.up.circle",
        "square.and.arrow.up", "square.and.arrow.down", "tray.and.arrow.down", "tray.and.arrow.up",
        "terminal", "apple.terminal", "chevron.left.forwardslash.chevron.right", "curlybraces", "hammer",
        "wrench.and.screwdriver", "gearshape", "gearshape.2", "slider.horizontal.3", "magnifyingglass",
        "eye", "eye.slash", "scissors", "pencil", "character.cursor.ibeam", "textformat", "number.square",
        "star", "star.fill", "heart", "flag", "tag", "bookmark", "pin", "paperclip", "link", "lock",
        "lock.open", "key", "checkmark.circle", "xmark.circle", "exclamationmark.triangle", "info.circle",
        "questionmark.circle", "plus.circle", "minus.circle",
        "photo", "film", "music.note", "play", "camera", "mic",
        "chart.pie", "chart.bar", "list.bullet", "square.grid.2x2", "rectangle.split.2x1", "macwindow",
        "app.badge", "puzzlepiece", "bolt", "sparkles", "clock", "calendar", "person", "envelope", "printer",
        "scalemass", "trash", "xmark.bin",
    ]
}
