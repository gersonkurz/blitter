import AppKit
import BlitterModel

/// The fonts the file lists and folder trees draw with (#62), made from the settings once and
/// shared: a cell compares its font by identity, so it is set only when the fonts change.
@MainActor
struct ListFonts {
    let settings: FontSettings
    /// Names, folders, and the columns without their own font.
    let text: NSFont
    /// A fast-filter match (#39).
    let bold: NSFont
    /// The tree's section headers.
    let section: NSFont
    /// Sizes: the text font with digits of equal width, so they line up from row to row.
    let tabular: NSFont
    /// Dates and permissions: every character the same width.
    let mono: NSFont
    /// Room for the taller of the two fonts, with AppKit's padding: at the default size it is
    /// AppKit's own small row height, whatever that is on this macOS.
    let rowHeight: CGFloat

    private static var cached: ListFonts?

    static func current(_ settings: FontSettings) -> ListFonts {
        if let cached, cached.settings == settings {
            return cached
        }
        let fonts = ListFonts(settings)
        cached = fonts
        return fonts
    }

    private init(_ settings: FontSettings) {
        self.settings = settings
        let size = CGFloat(settings.size)
        let manager = NSFontManager.shared
        if let face = settings.face, let font = manager.font(withFamily: face, traits: [], weight: 5, size: size) {
            text = font
            bold = manager.convert(font, toHaveTrait: .boldFontMask)
            section = bold
            tabular = Self.withTabularDigits(font)
        } else {
            text = .systemFont(ofSize: size)
            bold = .boldSystemFont(ofSize: size)
            section = .systemFont(ofSize: size, weight: .semibold)
            tabular = .monospacedDigitSystemFont(ofSize: size, weight: .regular)
        }
        mono = settings.mono.flatMap { manager.font(withFamily: $0, traits: [], weight: 5, size: size) }
            ?? .monospacedSystemFont(ofSize: size, weight: .regular)
        let lineHeight = max(Self.lineHeight(text), Self.lineHeight(mono))
        rowHeight = max(lineHeight + Self.rowPadding, Self.iconSize)
    }

    private static func lineHeight(_ font: NSFont) -> CGFloat {
        ceil(NSLayoutManager().defaultLineHeight(for: font))
    }

    /// What AppKit's small rows add to the line height of their font.
    private static let rowPadding: CGFloat = {
        let table = NSTableView()
        table.style = .fullWidth
        table.rowSizeStyle = .small
        return max(table.rowHeight - lineHeight(.systemFont(ofSize: NSFont.smallSystemFontSize)), 0)
    }()

    /// The list's and tree's icons: rows are never lower than they are.
    static let iconSize: CGFloat = 16

    /// The font's own figures of equal width; a font without them keeps its figures.
    private static func withTabularDigits(_ font: NSFont) -> NSFont {
        let feature: [NSFontDescriptor.FeatureKey: Int] = [
            .typeIdentifier: kNumberSpacingType,
            .selectorIdentifier: kMonospacedNumbersSelector,
        ]
        let descriptor = font.fontDescriptor.addingAttributes([.featureSettings: [feature]])
        return NSFont(descriptor: descriptor, size: font.pointSize) ?? font
    }
}
