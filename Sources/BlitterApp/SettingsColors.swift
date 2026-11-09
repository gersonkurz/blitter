import BlitterModel
import SwiftUI

/// The Colors tab (#73): a scheme for light mode and one for dark mode, picked from the schemes
/// that come with Blitter, each shown with its colors, the chosen one as a few rows of a list.
/// Any other scheme (a tinted-theming name, a file, an address) can be typed; the roles each
/// color takes stay in the settings file.
struct ColorSettings: View {
    @Binding var theme: ThemeSettings

    var body: some View {
        HStack(alignment: .top, spacing: 16) {
            SchemeChooser(title: "Light mode", name: $theme.light, darkFirst: false, theme: theme)
            SchemeChooser(title: "Dark mode", name: $theme.dark, darkFirst: true, theme: theme)
        }
        .padding()
    }
}

/// One mode's scheme: System, then the built-in schemes of that mode, then the others.
struct SchemeChooser: View {
    let title: String
    @Binding var name: String
    let darkFirst: Bool
    /// For the roles, and the settings' own schemes, which win over built-in ones of the same name.
    let theme: ThemeSettings
    @State private var other = ""

    private var builtIn: [BuiltInScheme] {
        BuiltInScheme.all.filter { $0.isDark == darkFirst } + BuiltInScheme.all.filter { $0.isDark != darkFirst }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.headline)
            ScrollViewReader { scroller in
                List(selection: Binding<String?>(get: { name }, set: { $0.map { name = $0 } })) {
                    Text("System (macOS's colors)").tag("system").id("system")
                    ForEach(builtIn) { scheme in
                        HStack {
                            Swatches(scheme: theme.scheme(named: scheme.id) ?? scheme.scheme)
                            Text(scheme.title)
                        }
                        .help(scheme.author)
                        .tag(scheme.id)
                        .id(scheme.id)
                    }
                }
                .frame(minHeight: 200)
                .onAppear { scroller.scrollTo(name, anchor: .center) } // the chosen one in sight
            }
            Preview(scheme: theme.scheme(named: name), name: name, slots: theme.slots)
            TextField("Other", text: $other, prompt: Text("a tinted-theming name, a file or an https address"))
                .onSubmit {
                    let typed = other.trimmingCharacters(in: .whitespaces)
                    if !typed.isEmpty {
                        name = typed
                    }
                }
            Link(
                "The tinted-theming gallery",
                destination: URL(string: "https://tinted-theming.github.io/tinted-gallery/")!
            )
            .font(.caption)
        }
        .onAppear { other = isBuiltIn ? "" : name }
        .onChange(of: name) { other = isBuiltIn ? "" : name }
    }

    private var isBuiltIn: Bool {
        name == "system" || BuiltInScheme.all.contains { $0.id == name }
    }
}

/// A scheme's background colors, then its accents, as small squares.
struct Swatches: View {
    let scheme: Base24Scheme

    var body: some View {
        HStack(spacing: 0) {
            ForEach([0, 1, 3, 5, 8, 9, 10, 11, 12, 13, 14, 15], id: \.self) { slot in
                Rectangle().fill(Color(scheme.colors[slot])).frame(width: 9, height: 14)
            }
        }
        .border(Color.secondary.opacity(0.4))
    }
}

/// A few rows of a list in the scheme's colors, as the roles take them.
struct Preview: View {
    let scheme: Base24Scheme?
    let name: String
    let slots: [ThemeRole: Int]

    var body: some View {
        if let scheme {
            VStack(alignment: .leading, spacing: 0) {
                row("Documents", .folder, background: .background, scheme)
                row("notes.txt", .text, background: .stripe, scheme)
                row("Blitter.app", .package, background: .selection, scheme)
                row(".hidden", .hidden, background: .stripe, scheme)
                row("build.sh", .executable, background: .background, scheme)
            }
            .border(Color.secondary.opacity(0.4))
        } else {
            Text(name == "system" ? "macOS's own colors." : "Shown once it is read: save to see it in the lists.")
                .font(.caption).foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, minHeight: 90, alignment: .center)
        }
    }

    private func row(_ text: String, _ role: ThemeRole, background: ThemeRole, _ scheme: Base24Scheme) -> some View {
        Text(text)
            .font(.callout)
            .foregroundStyle(color(role, scheme))
            .padding(.horizontal, 6).padding(.vertical, 2)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(color(background, scheme))
    }

    private func color(_ role: ThemeRole, _ scheme: Base24Scheme) -> Color {
        Color(scheme.colors[slots[role] ?? 0])
    }
}

extension Color {
    init(_ rgb: RGB) {
        self.init(red: Double(rgb.red) / 255, green: Double(rgb.green) / 255, blue: Double(rgb.blue) / 255)
    }
}
