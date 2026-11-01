import TOMLKit
import UniformTypeIdentifiers

/// A color as the settings file writes it ("#7cafc2"). The app turns it into an NSColor.
public struct RGB: Equatable, Hashable, Sendable {
    public let red: UInt8
    public let green: UInt8
    public let blue: UInt8

    public init(red: UInt8, green: UInt8, blue: UInt8) {
        self.red = red
        self.green = green
        self.blue = blue
    }

    /// "#7cafc2" or "7cafc2".
    init?(hex: String) {
        let digits = hex.hasPrefix("#") ? hex.dropFirst() : Substring(hex)
        guard digits.count == 6, digits.allSatisfy(\.isHexDigit), let value = UInt32(digits, radix: 16) else {
            return nil
        }
        self.init(red: UInt8(value >> 16), green: UInt8((value >> 8) & 0xFF), blue: UInt8(value & 0xFF))
    }
}

/// A Base16 scheme: 16 colors, base00 (darkest background in a dark scheme) to base0F.
public struct Base16Scheme: Equatable, Sendable {
    public let colors: [RGB]

    init?(_ hex: [String]) {
        let colors = hex.compactMap(RGB.init(hex:))
        guard colors.count == 16, hex.count == 16 else {
            return nil
        }
        self.colors = colors
    }

    static func slotName(_ index: Int) -> String {
        "base0" + String(index, radix: 16, uppercase: true)
    }

    /// Slot names "base00"…"base0F" (any case) to 0…15.
    static func slot(_ name: String) -> Int? {
        let lower = name.lowercased()
        guard lower.count == 6, lower.hasPrefix("base0"), let index = Int(lower.suffix(1), radix: 16) else {
            return nil
        }
        return index
    }

    // swiftlint:disable force_unwrapping
    /// Base16 Default by Chris Kempson, and Solarized by Ethan Schoonover, as Base16 schemes.
    static let builtIn: [String: Base16Scheme] = [
        "default-dark": Base16Scheme([
            "181818", "282828", "383838", "585858", "b8b8b8", "d8d8d8", "e8e8e8", "f8f8f8",
            "ab4642", "dc9656", "f7ca88", "a1b56c", "86c1b9", "7cafc2", "ba8baf", "a16946",
        ])!,
        "default-light": Base16Scheme([
            "f8f8f8", "e8e8e8", "d8d8d8", "b8b8b8", "585858", "383838", "282828", "181818",
            "ab4642", "dc9656", "f7ca88", "a1b56c", "86c1b9", "7cafc2", "ba8baf", "a16946",
        ])!,
        "solarized-dark": Base16Scheme([
            "002b36", "073642", "586e75", "657b83", "839496", "93a1a1", "eee8d5", "fdf6e3",
            "dc322f", "cb4b16", "b58900", "859900", "2aa198", "268bd2", "6c71c4", "d33682",
        ])!,
        "solarized-light": Base16Scheme([
            "fdf6e3", "eee8d5", "93a1a1", "839496", "657b83", "586e75", "073642", "002b36",
            "dc322f", "cb4b16", "b58900", "859900", "2aa198", "268bd2", "6c71c4", "d33682",
        ])!,
    ]
    // swiftlint:enable force_unwrapping
}

/// What a color means; each role takes one of the scheme's 16 slots.
public enum ThemeRole: String, CaseIterable, Sendable {
    case background
    /// Every other row.
    case stripe
    case selection
    case text
    /// Secondary text: sizes of folders, details in the jobs strip, section headers.
    case dimText = "dim_text"
    case folder
    case hidden
    case symlink
    /// A cloud placeholder whose contents are not on this Mac.
    case cloud
    case package
    /// An entry the file system could not read, and problems in the jobs strip.
    case error

    /// Base16's styling guidelines: 00 background, 01 lighter background, 02 selection,
    /// 03 comments, 04 dark foreground, 05 foreground; 08 red … 0D blue, 0E purple.
    static let defaultSlots: [ThemeRole: Int] = [
        .background: 0x0, .stripe: 0x1, .selection: 0x2, .text: 0x5, .dimText: 0x4,
        .folder: 0xD, .hidden: 0x3, .symlink: 0xC, .cloud: 0x4, .package: 0xE, .error: 0x8,
    ]
}

/// The colors to draw with: a scheme and which slot each role takes.
public struct Theme: Equatable, Sendable {
    public let scheme: Base16Scheme
    public let slots: [ThemeRole: Int]

    public func color(_ role: ThemeRole) -> RGB {
        scheme.colors[slots[role] ?? ThemeRole.defaultSlots[role] ?? 5]
    }
}

/// `[theme]` in the settings file: a scheme for light mode and one for dark mode ("system" keeps
/// macOS's own colors, the default), the role slots, and schemes of the user's own.
public struct ThemeSettings: Equatable, Sendable {
    public var light = "system"
    public var dark = "system"
    public var slots = ThemeRole.defaultSlots
    public var schemes: [String: Base16Scheme] = [:]

    /// The theme for the appearance, or nil for the system's colors.
    public func theme(dark isDark: Bool) -> Theme? {
        let name = isDark ? dark : light
        return scheme(named: name).map { Theme(scheme: $0, slots: slots) }
    }

    func scheme(named name: String) -> Base16Scheme? {
        schemes[name] ?? Base16Scheme.builtIn[name]
    }

    /// Applies `[theme]`. Each entry with a problem is reported and keeps its previous value.
    mutating func apply(_ table: TOMLTable, entries: (TOMLTable) -> [(key: String, value: TOMLValueConvertible?)])
        -> [String]
    {
        var problems: [String] = []
        // Schemes first, so light and dark may name them wherever they are in the section.
        if let value = table["schemes"] {
            problems += readSchemes(value, entries: entries)
        }
        for (key, value) in entries(table) {
            let name = "theme.\(key)"
            switch (key, value) {
            case ("schemes", _?):
                continue // read above
            case let ("light", value?), let ("dark", value?):
                guard let scheme = value.string, scheme == "system" || self.scheme(named: scheme) != nil else {
                    problems.append("“\(name)”: expected \"system\" or a scheme: \(schemeNames).")
                    continue
                }
                if key == "light" {
                    light = scheme
                } else {
                    dark = scheme
                }
            case let ("roles", value?):
                problems += readRoles(value, entries: entries)
            default:
                problems.append(value == nil ? "A setting starting with “\(name)” has a control character."
                    : "Unknown setting “\(name)”.")
            }
        }
        return problems
    }

    private var schemeNames: String {
        (["system"] + (Array(Base16Scheme.builtIn.keys) + Array(schemes.keys)).sorted()).joined(separator: ", ")
    }

    private mutating func readRoles(_ value: TOMLValueConvertible,
                                    entries: (TOMLTable) -> [(key: String, value: TOMLValueConvertible?)])
        -> [String]
    {
        guard let table = value.table else {
            return ["“theme.roles” must be a section: [theme.roles] folder = \"base0D\"."]
        }
        var problems: [String] = []
        for (key, value) in entries(table) {
            guard let role = ThemeRole(rawValue: key) else {
                problems.append("“theme.roles.\(key)”: unknown role. Roles: "
                    + ThemeRole.allCases.map(\.rawValue).joined(separator: ", ") + ".")
                continue
            }
            guard let slot = value?.string.flatMap(Base16Scheme.slot) else {
                problems.append("“theme.roles.\(key)”: expected a slot from \"base00\" to \"base0F\".")
                continue
            }
            slots[role] = slot
        }
        return problems
    }

    private mutating func readSchemes(_ value: TOMLValueConvertible,
                                      entries: (TOMLTable) -> [(key: String, value: TOMLValueConvertible?)])
        -> [String]
    {
        guard let table = value.table else {
            return ["“theme.schemes” must hold sections: [theme.schemes.<name>] base00 = \"#181818\" …"]
        }
        var problems: [String] = []
        for (name, value) in entries(table) {
            guard let colors = value?.table, name != "system" else {
                problems.append("“theme.schemes.\(name)” must be a section with base00 … base0F.")
                continue
            }
            // Base16 files write "base0A"; "base0a" is accepted too.
            let hex = (0 ..< 16).map { index in
                let slot = Base16Scheme.slotName(index)
                return (colors[slot] ?? colors[slot.lowercased()])?.string ?? ""
            }
            guard let scheme = Base16Scheme(hex), colors.keys.count == 16 else {
                problems.append("“theme.schemes.\(name)” needs exactly base00 … base0F, each a color like \"#181818\".")
                continue
            }
            schemes[name] = scheme
        }
        return problems
    }
}

public extension ListedEntry {
    /// The role an entry's name is drawn in. A problem reading it wins, then hidden (as the owner
    /// asked: hidden items get their own color), then what kind of item it is.
    var themeRole: ThemeRole {
        if entry.error != 0 {
            return .error
        }
        if entry.isHidden {
            return .hidden
        }
        if entry.isDataless {
            return .cloud
        }
        switch entry.kind {
        case .symlink:
            return .symlink
        case .directory:
            return contentType.conforms(to: .package) ? .package : .folder
        case .file, .other:
            return .text
        }
    }
}
