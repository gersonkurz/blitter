@testable import BlitterModel
import Foundation
import Testing

/// #73: the schemes that come with Blitter, the owner's Tomorrow Night Blue among them, chosen by
/// name without fetching anything.
@MainActor
struct BuiltInSchemesTests {
    @Test func theyAreThereWithNamesTitlesAndModes() throws {
        let all = BuiltInScheme.all
        #expect(all.count == 22)
        #expect(Set(all.map(\.id)).count == all.count)
        let blue = try #require(all.first { $0.id == "tomorrow-night-blue" })
        #expect(blue.title == "Tomorrow Night Blue" && blue.isDark)
        #expect(blue.scheme.colors.first == RGB(red: 0x00, green: 0x24, blue: 0x51)) // base00 #002451
        #expect(blue.scheme.colors.count == 24) // Base16, with Base24's fallbacks
        #expect(all.first { $0.id == "solarized-light" }?.isDark == false)
        // Light ones first, each group by title.
        let lights = all.prefix { !$0.isDark }
        #expect(lights.map(\.title) == lights.map(\.title).sorted())
        let darkOnes = all.dropFirst(lights.count).allSatisfy(\.isDark)
        #expect(darkOnes)
    }

    /// A built-in name in the settings file is resolved at once: no download, no problem.
    @Test func aBuiltInNameNeedsNoDownload() async {
        var settings = Settings()
        settings.theme.dark = "tomorrow-night-blue"
        let folder = NSTemporaryDirectory() + "BlitterSchemes-" + UUID().uuidString
        let (resolved, downloads) = await Workspace.resolveSchemes(settings, folder: folder, home: "/home")
        #expect(downloads.isEmpty && resolved.problems.isEmpty)
        #expect(resolved.settings.theme.theme(dark: true) != nil)
        #expect(resolved.settings.theme.scheme(named: "tomorrow-night-blue")?.colors.first
            == RGB(red: 0x00, green: 0x24, blue: 0x51))
        #expect(Settings.parse(Settings.fileText(settings)).settings.theme.dark == "tomorrow-night-blue")
    }
}

extension BuiltInSchemesTests {
    /// A scheme of the settings' own with a built-in name wins, in the theme and so in the
    /// Settings window's preview (#73 review).
    @Test func aSchemeOfTheSettingsWinsOverABuiltInOfTheSameName() throws {
        let colors = (0 ..< 16).map { String(format: "#%02x%02x%02x", $0, $0, $0) }
        let own = try #require(Base24Scheme(colors))
        var settings = Settings()
        settings.theme.schemes["nord"] = own
        #expect(settings.theme.scheme(named: "nord") == own)
        #expect(settings.theme.scheme(named: "nord") != BuiltInScheme.all.first { $0.id == "nord" }?.scheme)
        #expect(settings.theme.scheme(named: "dracula") == BuiltInScheme.all.first { $0.id == "dracula" }?.scheme)
    }
}
