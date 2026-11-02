import AppKit
import BlitterModel

/// The colors the views draw with (#21): the settings' Base16 theme for the current appearance,
/// or macOS's own colors when the theme is "system" — exactly the look Blitter had before themes.
/// Colors are made once per theme: `changed(from:…)` resolves only the theme (a dictionary
/// lookup) and builds the colors when it differs from the one in use.
@MainActor
struct Palette: Equatable {
    let theme: Theme?
    private let colors: [ThemeRole: NSColor]

    init(_ settings: ThemeSettings, appearance: NSAppearance) {
        self.init(theme: Self.theme(settings, appearance: appearance))
    }

    /// A new palette if the theme for the view's window differs from `current`'s, else nil.
    static func changed(from current: Palette?, _ settings: ThemeSettings, for view: NSView) -> Palette? {
        let theme = theme(settings, appearance: view.window?.effectiveAppearance ?? NSApp.effectiveAppearance)
        if let current, current.theme == theme {
            return nil
        }
        return Palette(theme: theme)
    }

    /// The scheme follows the WINDOW's mode (light or dark), not a view's own appearance, which
    /// a theme overrides.
    private static func theme(_ settings: ThemeSettings, appearance: NSAppearance) -> Theme? {
        settings.theme(dark: appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua)
    }

    private init(theme: Theme?) {
        self.theme = theme
        var colors: [ThemeRole: NSColor] = [:]
        for role in ThemeRole.allCases {
            colors[role] = theme.map { Self.color($0.color(role)) } ?? Self.system(role)
        }
        self.colors = colors
    }

    var isThemed: Bool {
        theme != nil
    }

    /// For a themed view: light or dark controls, icons and headers to suit the scheme's
    /// background, whatever mode the window is in. Nil keeps the window's own.
    var appearance: NSAppearance? {
        guard let background = theme?.color(.background) else {
            return nil
        }
        let luminance = 0.2126 * Double(background.red) + 0.7152 * Double(background.green)
            + 0.0722 * Double(background.blue)
        return NSAppearance(named: luminance < 128 ? .darkAqua : .aqua)
    }

    func color(_ role: ThemeRole) -> NSColor {
        colors[role] ?? .labelColor
    }

    nonisolated static func == (lhs: Palette, rhs: Palette) -> Bool {
        lhs.theme == rhs.theme
    }

    private static func color(_ rgb: RGB) -> NSColor {
        NSColor(srgbRed: CGFloat(rgb.red) / 255, green: CGFloat(rgb.green) / 255, blue: CGFloat(rgb.blue) / 255,
                alpha: 1)
    }

    /// What each role looked like before themes existed.
    private static func system(_ role: ThemeRole) -> NSColor {
        switch role {
        case .background: .controlBackgroundColor
        case .stripe: NSColor.alternatingContentBackgroundColors.last ?? .controlBackgroundColor
        case .selection: .selectedContentBackgroundColor
        case .dimText, .hidden: .secondaryLabelColor
        case .text, .folder, .symlink, .cloud, .package, .executable, .error: .labelColor
        // Git colors show without a theme too: they carry information.
        case .gitClean: .systemGreen
        case .gitModified: .systemRed
        case .gitAheadOrBehind: .systemOrange
        }
    }
}

/// A row in a themed list or tree: background and stripes from the theme, the selection in the
/// theme's selection color, and the text keeps its role colors when selected. Rows have one
/// height, so the stripe follows from where the row is, which stays right when rows are
/// inserted or removed without a reload.
final class ThemedRowView: NSTableRowView {
    static let identifier = NSUserInterfaceItemIdentifier("ThemedRow")
    var palette: Palette?

    override var isGroupRowStyle: Bool {
        get { false } // section headers in the tree are drawn like any row (#14)
        set { _ = newValue }
    }

    override var interiorBackgroundStyle: NSView.BackgroundStyle {
        .normal
    }

    override func drawBackground(in _: NSRect) {
        guard let palette else {
            return
        }
        let row = frame.height > 0 ? Int((frame.minY / frame.height).rounded()) : 0
        palette.color(row.isMultiple(of: 2) ? .background : .stripe).setFill()
        bounds.fill()
    }

    override func drawSelection(in _: NSRect) {
        palette?.color(.selection).setFill()
        bounds.fill()
    }

    /// A reused row view if there is one, set to the palette.
    @MainActor
    static func make(in tableView: NSTableView, palette: Palette) -> ThemedRowView {
        let view = tableView.makeView(withIdentifier: identifier, owner: nil) as? ThemedRowView ?? ThemedRowView()
        view.identifier = identifier
        view.palette = palette
        return view
    }
}
