import BlitterCore
@testable import BlitterModel
import Foundation
import Testing
import UniformTypeIdentifiers

/// Themes (#21): Base16 schemes, roles, and the `[theme]` section of the settings file.
struct ThemeTests {
    private let solarizedBase03 = RGB(red: 0x00, green: 0x2B, blue: 0x36)

    @Test func colorsAndSlotsAreRead() {
        #expect(RGB(hex: "#7cafc2") == RGB(red: 0x7C, green: 0xAF, blue: 0xC2))
        #expect(RGB(hex: "7CAFC2") == RGB(red: 0x7C, green: 0xAF, blue: 0xC2))
        for bad in ["", "#7cafc", "7cafc2a", "#gggggg", "+7cafc", " 7cafc"] {
            #expect(RGB(hex: bad) == nil, "\(bad)")
        }
        #expect(Base16Scheme.slot("base00") == 0 && Base16Scheme.slot("base0D") == 13 && Base16Scheme
            .slot("BASE0f") == 15)
        #expect(Base16Scheme.slot("base10") == nil && Base16Scheme.slot("base0G") == nil && Base16Scheme
            .slot("base0") == nil)
        #expect(Base16Scheme.builtIn.count == 4 && Base16Scheme.builtIn.values.allSatisfy { $0.colors.count == 16 })
    }

    @Test func theDefaultIsTheSystemsOwnLook() {
        let theme = Settings().theme
        #expect(theme.theme(dark: false) == nil && theme.theme(dark: true) == nil)
        #expect(Settings.parse(Settings.defaultFile) == (Settings(), []))
    }

    @Test func lightAndDarkTakeTheirOwnSchemes() throws {
        let (settings, problems) = Settings.parse("""
        [theme]
        light = "default-light"
        dark = "solarized-dark"
        [theme.roles]
        folder = "base08"
        """)
        #expect(problems.isEmpty)
        let light = try #require(settings.theme.theme(dark: false))
        let dark = try #require(settings.theme.theme(dark: true))
        #expect(light.color(.background) == RGB(red: 0xF8, green: 0xF8, blue: 0xF8))
        #expect(dark.color(.background) == solarizedBase03)
        #expect(dark.color(.folder) == RGB(red: 0xDC, green: 0x32, blue: 0x2F)) // base08 now
        #expect(dark.color(.hidden) == RGB(red: 0x65, green: 0x7B, blue: 0x83)) // base03, the default
    }

    @Test func aSchemeOfTheUsersOwn() throws {
        let colors = (0 ..< 16).map { String(format: "base0%X = \"#%02x%02x%02x\"", $0, $0, $0, $0) }
        let (settings, problems) = Settings.parse("""
        [theme]
        dark = "mine"
        [theme.schemes.mine]
        \(colors.joined(separator: "\n"))
        """)
        #expect(problems.isEmpty)
        let dark = try #require(settings.theme.theme(dark: true))
        #expect(dark.color(.folder) == RGB(red: 13, green: 13, blue: 13)) // base0D
        #expect(settings.theme.theme(dark: false) == nil)
    }

    @Test func problemsAreReportedAndKeepTheDefaults() {
        let (settings, problems) = Settings.parse("""
        [theme]
        light = "neon"
        dark = 3
        roles = "folder"
        extra = 1
        [theme.schemes.half]
        base00 = "#000000"
        [theme.schemes.system]
        base00 = "#000000"
        """)
        #expect(settings.theme == ThemeSettings())
        #expect(problems.count == 6)
        #expect(problems.contains { $0.contains("theme.light") && $0.contains("solarized-dark") })
        #expect(problems.contains { $0.contains("theme.schemes.half") })
        #expect(problems.contains { $0.contains("theme.extra") })

        let (roles, roleProblems) = Settings.parse("[theme.roles]\nfolder = \"base10\"\nsparkle = \"base01\"\n")
        #expect(roles.theme == ThemeSettings())
        #expect(roleProblems.count == 2)
    }

    @Test func eachEntryHasItsRole() {
        func role(_ entry: DirectoryEntry, _ type: UTType = .data) -> ThemeRole {
            ListedEntry(entry: entry, contentType: type, kindDescription: "").themeRole
        }
        func entry(_ kind: DirectoryEntry.Kind, hidden: Bool = false, dataless: Bool = false, error: Int32 = 0,
                   mode: UInt16 = 0o644) -> DirectoryEntry
        {
            DirectoryEntry(name: "x", kind: kind, size: 0, modificationDate: .distantPast, isHidden: hidden,
                           isDataless: dataless, error: error, permissions: mode)
        }
        #expect(role(entry(.file)) == .text)
        #expect(role(entry(.directory), .folder) == .folder)
        #expect(role(entry(.directory), .applicationBundle) == .package)
        #expect(role(entry(.symlink)) == .symlink)
        #expect(role(entry(.file, dataless: true)) == .cloud)
        #expect(role(entry(.directory, hidden: true), .folder) == .hidden) // hidden wins over the kind
        #expect(role(entry(.file, hidden: true, error: EACCES)) == .error) // a problem wins over all
        // #31: any execute bit makes a file executable; hidden, cloud and errors still win, and
        // folders and links keep their own roles whatever their x bits.
        for mode: UInt16 in [0o755, 0o700, 0o610, 0o601, 0o4711] {
            #expect(role(entry(.file, mode: mode)) == .executable, "\(String(mode, radix: 8))")
        }
        #expect(role(entry(.file, mode: 0o666)) == .text)
        #expect(role(entry(.file, hidden: true, mode: 0o755)) == .hidden)
        #expect(role(entry(.file, dataless: true, mode: 0o755)) == .cloud)
        #expect(role(entry(.file, error: EIO, mode: 0o755)) == .error)
        #expect(role(entry(.directory, mode: 0o755), .folder) == .folder)
        #expect(role(entry(.symlink, mode: 0o755)) == .symlink)
        #expect(ThemeRole.defaultSlots[.executable] == 0xB)
        let (settings, problems) = Settings.parse("[theme.roles]\nexecutable = \"base0E\"\n")
        #expect(problems.isEmpty && settings.theme.slots[.executable] == 0xE)
    }
}
