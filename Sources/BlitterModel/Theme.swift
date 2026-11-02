import Foundation
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
    /// A file with an execute bit (#31).
    case executable
    /// An entry the file system could not read, and problems in the jobs strip.
    case error
    /// Git (#22): a clean working copy; changes in it or below a folder; ahead of or behind its
    /// upstream.
    case gitClean = "git_clean"
    case gitModified = "git_modified"
    case gitAheadOrBehind = "git_ahead_behind"

    /// Base16's styling guidelines: 00 background, 01 lighter background, 02 selection,
    /// 03 comments, 04 dark foreground, 05 foreground; 08 red … 0D blue, 0E purple.
    static let defaultSlots: [ThemeRole: Int] = [
        .background: 0x0, .stripe: 0x1, .selection: 0x2, .text: 0x5, .dimText: 0x4,
        .folder: 0xD, .hidden: 0x3, .symlink: 0xC, .cloud: 0x4, .package: 0xE, .executable: 0xB, .error: 0x8,
        .gitClean: 0xB, .gitModified: 0x8, .gitAheadOrBehind: 0xA,
    ]
}

/// The colors to draw with: a scheme and which slot each role takes.
public struct Theme: Equatable, Sendable {
    public let scheme: Base24Scheme
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
    public var schemes: [String: Base24Scheme] = [:]

    /// The theme for the appearance, or nil for the system's colors.
    public func theme(dark isDark: Bool) -> Theme? {
        let name = isDark ? dark : light
        return scheme(named: name).map { Theme(scheme: $0, slots: slots) }
    }

    func scheme(named name: String) -> Base24Scheme? {
        schemes[name] ?? Base24Scheme.builtIn[name]
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
                // A name from the collection, a file or an address is looked for later, when the
                // settings are read (#34); here only its form is checked.
                guard let scheme = value.string, scheme == "system" || self.scheme(named: scheme) != nil
                    || SchemeReference(scheme, home: "") != nil
                else {
                    problems.append("“\(name)”: expected \"system\", a scheme (\(schemeNames)), a scheme "
                        + "name from tinted-theming such as \"dracula\", a file path or an https address.")
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

    /// Finds the schemes `light` and `dark` name that are neither built in nor in the file (#34):
    /// a file is read, a scheme from the collection or the web is taken from `cacheFolder` if
    /// fetched before, else listed to be fetched. Until then, and when it cannot be read, the
    /// setting is "system". Reads files: off the main thread.
    mutating func resolve(cacheFolder: String?, home: String) -> (problems: [String], downloads: [SchemeDownload]) {
        var problems: [String] = []
        var downloads: [SchemeDownload] = []
        for key in ["light", "dark"] {
            let name = key == "light" ? light : dark
            guard name != "system", scheme(named: name) == nil, let reference = SchemeReference(name, home: home) else {
                continue
            }
            let path = if case let .file(path) = reference {
                path
            } else {
                cacheFolder.flatMap(reference.cachePath)
            }
            // A file that is there but cannot be read is reported, never fetched over: the fetch
            // would not replace it, and would start again with every read (#34 review).
            if let path, Base24Scheme.entryExists(path) {
                if let scheme = Base24Scheme.read(path) {
                    schemes[name] = scheme
                    continue
                }
                problems.append("“theme.\(key)”: “\(path)” is not a readable Base16 or Base24 scheme.")
            } else if case .file = reference {
                problems.append("“theme.\(key)”: “\(path ?? name)” could not be read.")
            } else if let path {
                if !downloads.contains(where: { $0.name == name }) {
                    downloads.append(SchemeDownload(name: name, urls: reference.downloadURLs, cachePath: path))
                }
            } else {
                problems.append("“theme.\(key)”: “\(name)” needs a settings file to keep it in.")
            }
            if key == "light" {
                light = "system"
            } else {
                dark = "system"
            }
        }
        return (problems, downloads)
    }

    private var schemeNames: String {
        (["system"] + (Array(Base24Scheme.builtIn.keys) + Array(schemes.keys)).sorted()).joined(separator: ", ")
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
            guard let slot = value?.string.flatMap(Base24Scheme.slot) else {
                problems.append("“theme.roles.\(key)”: expected a slot from \"base00\" to \"base17\".")
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
            // Base16 (base00 … base0F) or Base24 (… base17). Files write "base0A"; "base0a" works too.
            let count = colors.keys.count
            let hex = (0 ..< count).map { index in
                let slot = Base24Scheme.slotName(index)
                return (colors[slot] ?? colors[slot.lowercased()])?.string ?? ""
            }
            guard let scheme = Base24Scheme(hex) else {
                problems.append("“theme.schemes.\(name)” needs exactly base00 … base0F (Base16) or base00 … "
                    + "base17 (Base24), each a color like \"#181818\".")
                continue
            }
            schemes[name] = scheme
        }
        return problems
    }
}

public extension ListedEntry {
    /// The role an entry's name is drawn in. A problem reading it wins, then hidden (as the owner
    /// asked: hidden items get their own color), then what kind of item it is; a file that can
    /// be run is executable (#31).
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
        case .file:
            return entry.isExecutable ? .executable : .text
        case .other:
            return .text
        }
    }
}
