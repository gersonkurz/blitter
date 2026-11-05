import CoreText
import Foundation
import TOMLKit

/// The fonts of the file lists and folder trees (#62): one face for the text, one fixed-width
/// face for the columns that must line up (dates, permissions), and one size for both. Dialogs
/// keep the system font.
public struct FontSettings: Equatable, Sendable {
    /// A font family's name; nil is the system font.
    public var face: String?
    /// A fixed-width font family's name; nil is the system's fixed-width font.
    public var mono: String?
    /// In points; the default is the size of AppKit's small rows.
    public var size = 11.0

    public static let sizes = 8.0 ... 32.0
    static let keys: Set = ["face", "mono", "size"]

    public init(face: String? = nil, mono: String? = nil, size: Double = 11) {
        self.face = face
        self.mono = mono
        self.size = size
    }

    /// Applies one of `keys`, or explains why it can't; whatever is invalid keeps its default.
    mutating func apply(key: String, value: TOMLValueConvertible) -> String? {
        switch key {
        case "face", "mono":
            let isMono = key == "mono"
            guard let name = value.string, !name.isEmpty else {
                return "expected \"system\" or the name of a font family such as \"\(isMono ? "Menlo" : "Helvetica")\"."
            }
            var family: String?
            if name != "system" {
                guard let installed = Self.installedFamily(name) else {
                    return "no font family “\(name)” is installed."
                }
                guard !isMono || installed.isFixedWidth else {
                    return "“\(name)” is not a fixed-width font."
                }
                family = installed.name
            }
            if isMono {
                mono = family
            } else {
                face = family
            }
            return nil
        case "size":
            // TOML keeps 11 and 11.5 apart; either is a size.
            guard let points = value.double ?? value.int.map(Double.init), Self.sizes.contains(points) else {
                return "expected a size in points from \(Int(Self.sizes.lowerBound)) to \(Int(Self.sizes.upperBound))."
            }
            size = points
            return nil
        default:
            preconditionFailure("not one of FontSettings.keys: \(key)")
        }
    }

    /// The installed family a name stands for (any case), and whether its regular face is
    /// fixed-width. CoreText rather than AppKit: the model never imports AppKit.
    static func installedFamily(_ name: String) -> (name: String, isFixedWidth: Bool)? {
        let families = CTFontManagerCopyAvailableFontFamilyNames() as? [String] ?? []
        guard let family = families.first(where: { $0.caseInsensitiveCompare(name) == .orderedSame }) else {
            return nil
        }
        let descriptor = CTFontDescriptorCreateWithAttributes([kCTFontFamilyNameAttribute: family] as CFDictionary)
        let font = CTFontCreateWithFontDescriptor(descriptor, 12, nil)
        return (family, CTFontGetSymbolicTraits(font).contains(.traitMonoSpace))
    }
}
