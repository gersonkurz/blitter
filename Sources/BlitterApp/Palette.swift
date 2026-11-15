import AppKit
import BlitterModel

/// The colors the views draw with (#21): the settings' Base16 theme for the current appearance,
/// or macOS's own colors when the theme is "system" — exactly the look Blitter had before themes.
/// Colors are made once per theme: `changed(from:…)` resolves only the theme (a dictionary
/// lookup) and builds the colors when it differs from the one in use.
@MainActor
struct Palette: Equatable {
    let theme: Theme?
    /// Lines or stripes (#91).
    let rows: RowStyle
    /// The line under each row in "lines" (#91, #92): the background with a fifth of the text
    /// mixed in, so it shows in dark schemes too (their stripe color is barely off the
    /// background) and stays light. Without a scheme, the same mix of macOS's colors, in the
    /// window's mode.
    let lineColor: NSColor
    private let colors: [ThemeRole: NSColor]
    /// How much of the text color the line takes.
    nonisolated static let lineStrength: CGFloat = 0.2

    init(_ settings: ThemeSettings, appearance: NSAppearance) {
        self.init(theme: Self.theme(settings, appearance: appearance), rows: settings.rows)
    }

    /// A new palette if the theme for the view's window, or the rows, differ from `current`'s,
    /// else nil.
    static func changed(from current: Palette?, _ settings: ThemeSettings, for view: NSView) -> Palette? {
        let theme = theme(settings, appearance: view.window?.effectiveAppearance ?? NSApp.effectiveAppearance)
        if let current, current.theme == theme, current.rows == settings.rows {
            return nil
        }
        return Palette(theme: theme, rows: settings.rows)
    }

    /// The scheme follows the WINDOW's mode (light or dark), not a view's own appearance, which
    /// a theme overrides.
    private static func theme(_ settings: ThemeSettings, appearance: NSAppearance) -> Theme? {
        settings.theme(dark: appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua)
    }

    /// macOS's colors with the settings' rows: for the windows a scheme does not color (the Git
    /// windows), whose lists still take lines or stripes (#91).
    static func system(rows: RowStyle) -> Palette {
        Palette(theme: nil, rows: rows)
    }

    private init(theme: Theme?, rows: RowStyle) {
        self.theme = theme
        self.rows = rows
        var colors: [ThemeRole: NSColor] = [:]
        for role in ThemeRole.allCases {
            colors[role] = theme.map { Self.color($0.color(role)) } ?? Self.system(role)
        }
        self.colors = colors
        lineColor = theme == nil ? Self.systemLine : Self.mix(colors[.background], colors[.text])
    }

    var isThemed: Bool {
        theme != nil
    }

    /// Whether AppKit draws the stripes: without a scheme, in "stripes" (with one, the rows do).
    var systemStripes: Bool {
        !isThemed && rows == .stripes
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
        lhs.theme == rhs.theme && lhs.rows == rhs.rows
    }

    private static func color(_ rgb: RGB) -> NSColor {
        NSColor(srgbRed: CGFloat(rgb.red) / 255, green: CGFloat(rgb.green) / 255, blue: CGFloat(rgb.blue) / 255,
                alpha: 1)
    }

    /// `lineStrength` of `text` over `background`, in sRGB (a text color's own transparency counts).
    private nonisolated static func mix(_ background: NSColor?, _ text: NSColor?) -> NSColor {
        guard let base = background?.usingColorSpace(.sRGB), let ink = text?.usingColorSpace(.sRGB) else {
            return .separatorColor
        }
        let amount = lineStrength * ink.alphaComponent
        func channel(_ from: CGFloat, _ toward: CGFloat) -> CGFloat {
            from + (toward - from) * amount
        }
        return NSColor(srgbRed: channel(base.redComponent, ink.redComponent),
                       green: channel(base.greenComponent, ink.greenComponent),
                       blue: channel(base.blueComponent, ink.blueComponent), alpha: 1)
    }

    /// macOS's background and text mixed, for light or dark mode as the window is drawn.
    private static let systemLine = NSColor(name: "BlitterRowLine") { appearance in
        var line = NSColor.separatorColor
        appearance.performAsCurrentDrawingAppearance {
            line = mix(.controlBackgroundColor, .labelColor)
        }
        return line
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

/// A row of a list or the tree drawn by Blitter: with a scheme, the background and stripes in
/// its colors, the selection in its selection color, and the text keeps its role colors when
/// selected; in "lines", a thin line under the row (#91), with or without a scheme. Rows have one
/// height, so the stripe follows from where the row is, which stays right when rows are
/// inserted or removed without a reload. A line drawn by the row, not the table's grid, is under
/// real rows only: the empty space below the last one stays clean.
final class ListRowView: NSTableRowView {
    static let identifier = NSUserInterfaceItemIdentifier("ListRow")
    var palette: Palette?
    var drawsLine = false

    private var isThemed: Bool {
        palette?.isThemed == true
    }

    /// Section headers in a themed tree are drawn like any row (#14).
    override var isGroupRowStyle: Bool {
        get { isThemed ? false : super.isGroupRowStyle }
        set { super.isGroupRowStyle = newValue }
    }

    override var interiorBackgroundStyle: NSView.BackgroundStyle {
        isThemed ? .normal : super.interiorBackgroundStyle
    }

    override func drawBackground(in dirtyRect: NSRect) {
        guard let palette, palette.isThemed else {
            super.drawBackground(in: dirtyRect)
            drawLine()
            return
        }
        let row = frame.height > 0 ? Int((frame.minY / frame.height).rounded()) : 0
        let striped = palette.rows == .stripes && !row.isMultiple(of: 2)
        palette.color(striped ? .stripe : .background).setFill()
        bounds.fill()
        drawLine()
    }

    private func drawLine() {
        guard drawsLine, let palette else {
            return
        }
        let thickness = 1 / (window?.backingScaleFactor ?? 2)
        palette.lineColor.setFill()
        NSRect(x: bounds.minX, y: isFlipped ? bounds.maxY - thickness : bounds.minY, width: bounds.width,
               height: thickness).fill()
    }

    override func drawSelection(in dirtyRect: NSRect) {
        guard let palette, palette.isThemed else {
            super.drawSelection(in: dirtyRect)
            return
        }
        palette.color(.selection).setFill()
        bounds.fill()
    }

    /// A reused row view if there is one, set to the palette; nil where AppKit's own row does:
    /// no scheme and no line.
    @MainActor
    static func make(in tableView: NSTableView, palette: Palette, lines: Bool) -> ListRowView? {
        let drawsLine = lines && palette.rows == .lines
        guard palette.isThemed || drawsLine else {
            return nil
        }
        let view = tableView.makeView(withIdentifier: identifier, owner: nil) as? ListRowView ?? ListRowView()
        view.identifier = identifier
        view.palette = palette
        view.drawsLine = drawsLine
        view.needsDisplay = true
        return view
    }
}
