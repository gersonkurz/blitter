import BlitterCore
import Foundation

/// A color scheme (#21, #34): Base24's 24 colors, base00 … base0F and base10 … base17. A Base16
/// scheme gets base10 … base17 from Base24's fallbacks, so every role can name any slot.
public struct Base24Scheme: Equatable, Sendable {
    public let colors: [RGB]

    /// Where a Base16 scheme takes base10 … base17 from (tinted-theming/base24, styling.md).
    static let fallbacks = [0x0, 0x0, 0x8, 0xA, 0xB, 0xC, 0xD, 0xE]

    /// 16 (Base16) or 24 (Base24) colors like "#181818".
    init?(_ hex: [String]) {
        let colors = hex.compactMap(RGB.init(hex:))
        guard colors.count == hex.count, colors.count == 16 || colors.count == 24 else {
            return nil
        }
        self.colors = colors.count == 24 ? colors : colors + Self.fallbacks.map { colors[$0] }
    }

    /// The schemes that come with Blitter, by name.
    public static var builtInNames: [String] {
        builtIn.keys.sorted()
    }

    /// "base00" … "base0F", "base10" … "base17": what a role can take.
    public static let slotNames = (0 ..< 24).map(slotName)

    static func slotName(_ index: Int) -> String {
        (index < 16 ? "base0" : "base1") + String(index % 16, radix: 16, uppercase: true)
    }

    /// Slot names "base00" … "base0F" and "base10" … "base17" (any case) to 0 … 23.
    static func slot(_ name: String) -> Int? {
        let lower = name.lowercased()
        guard lower.count == 6, lower.hasPrefix("base"), let digit = Int(lower.suffix(1), radix: 16) else {
            return nil
        }
        switch lower.dropFirst(4).first {
        case "0": return digit
        case "1" where digit < 8: return 16 + digit
        default: return nil
        }
    }

    /// A scheme file as tinted-theming publishes it (YAML): `baseXX: "#rrggbb"` lines, under
    /// `palette:` (spec 0.11) or at the top (older files). Only those lines are read; the rest of
    /// YAML is not needed for them. Nil unless exactly base00 … base0F, or base00 … base17.
    /// The scheme in a file, or nil if it cannot be read or is none.
    static func read(_ path: String) -> Base24Scheme? {
        (try? String(contentsOfFile: path, encoding: .utf8)).flatMap(fromYAML)
    }

    /// Whether anything is at `path`, a dangling symbolic link too (`fileExists` follows links
    /// and calls those absent).
    static func entryExists(_ path: String) -> Bool {
        var info = stat()
        return lstat(path, &info) == 0
    }

    static func fromYAML(_ text: String) -> Base24Scheme? {
        var found: [Int: String] = [:]
        for line in text.split(whereSeparator: \.isNewline) {
            guard let colon = line.firstIndex(of: ":") else {
                continue
            }
            let key = line[..<colon].trimmingCharacters(in: CharacterSet.whitespaces.union(["\"", "'"]))
            guard let slot = slot(key), found[slot] == nil else {
                continue
            }
            found[slot] = value(line[line.index(after: colon)...])
        }
        let count = found.count
        let hex = (0 ..< count).compactMap { found[$0] }
        return hex.count == count ? Base24Scheme(hex) : nil
    }

    /// `"#282a36"  # comment` → "#282a36": quoted up to the closing quote, else the first word.
    private static func value(_ text: Substring) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        if let quote = trimmed.first, quote == "\"" || quote == "'" {
            let rest = trimmed.dropFirst()
            return String(rest.prefix { $0 != quote })
        }
        return String(trimmed.prefix { !$0.isWhitespace })
    }

    /// The schemes that come with Blitter (#73), by name.
    static let builtIn = Dictionary(uniqueKeysWithValues: BuiltInScheme.all.map { ($0.id, $0.scheme) })
}

/// What `light` or `dark` names when it is not "system", a built-in or an inline scheme (#34).
enum SchemeReference: Equatable {
    /// A scheme of the tinted-theming collection, by its file name ("gruvbox-dark-hard").
    case collection(String)
    /// A scheme file on this Mac (tinted-theming YAML).
    case file(String)
    /// A scheme file on the web, fetched once.
    case url(URL)

    /// The collection on GitHub, at the spec version Blitter reads.
    static let collectionBase = "https://raw.githubusercontent.com/tinted-theming/schemes/spec-0.11/"

    /// Nil for anything else: then the setting is a mistake.
    init?(_ value: String, home: String) {
        if value.hasPrefix("https://") {
            guard let url = URL(string: value), url.host != nil else {
                return nil
            }
            self = .url(url)
        } else if value.hasPrefix("/") {
            self = .file(value)
        } else if value.hasPrefix("~/") {
            self = .file(home + value.dropFirst())
        } else if let first = value.first, first.isLowercase || first.isNumber,
                  value.allSatisfy({ $0.isLowercase || $0.isNumber || "-_.".contains($0) }), !value.contains("..")
        {
            self = .collection(value)
        } else {
            return nil
        }
    }

    /// Where a fetched scheme is kept, in the settings folder's `schemes`.
    func cachePath(in folder: String) -> String? {
        switch self {
        case let .collection(name): folder + "/" + name + ".yaml"
        case let .url(url): folder + "/url-" + Self.fnv1a(url.absoluteString) + ".yaml"
        case .file: nil
        }
    }

    /// Where it is fetched from, in this order: Base24 first, then Base16.
    var downloadURLs: [URL] {
        switch self {
        case let .collection(name):
            ["base24", "base16"].compactMap { URL(string: Self.collectionBase + $0 + "/" + name + ".yaml") }
        case let .url(url): [url]
        case .file: []
        }
    }

    /// A stable name for a URL's cache file (Swift's own hashing changes with every launch).
    private static func fnv1a(_ text: String) -> String {
        var hash: UInt64 = 0xCBF2_9CE4_8422_2325
        for byte in text.utf8 {
            hash = (hash ^ UInt64(byte)) &* 0x100_0000_01B3
        }
        return String(hash, radix: 16)
    }
}

/// A scheme to fetch: what the settings call it, where from, and where it is kept.
struct SchemeDownload: Equatable, Sendable {
    let name: String
    let urls: [URL]
    let cachePath: String
}
