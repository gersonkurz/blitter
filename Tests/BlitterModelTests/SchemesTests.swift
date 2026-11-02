import BlitterCore
@testable import BlitterModel
import Foundation
import Synchronization
import Testing

/// Base24 and schemes from tinted-theming, files and the web (#34). No real network: the
/// workspace's fetcher is replaced.
@MainActor
@Suite(.serialized)
struct SchemesTests {
    /// The shape tinted-theming publishes (spec 0.11): a palette with comments, mixed case.
    private static let base24 = """
    system: "base24"
    name: "Test 24"
    variant: "dark"
    palette:
      base00: "#282a36"  # Default Background
    """ + "\n" + (1 ..< 24).map { index in
        String(format: "  %@: \"#%02X%02X%02x\"  # c", Base24Scheme.slotName(index), index, index, index)
    }.joined(separator: "\n") + "\n"

    private static let base16 = """
    system: "base16"
    name: "Test 16"
    palette:
    """ + "\n" + (0 ..< 16).map { String(format: "  base0%X: \"#%02x0000\"", $0, $0 * 16) }.joined(separator: "\n")

    @Test func schemeFilesAreReadInBothShapes() throws {
        let dracula = try #require(Base24Scheme.fromYAML(Self.base24))
        #expect(dracula.colors[0] == RGB(red: 0x28, green: 0x2A, blue: 0x36))
        #expect(dracula.colors[23] == RGB(red: 23, green: 23, blue: 23)) // base17, its own
        // Older files: flat, unquoted, without "#".
        let flat = "scheme: \"Old\"\n" + (0 ..< 16).map { String(format: "base0%X: %02x%02x%02x", $0, $0, $0, $0) }
            .joined(separator: "\n")
        let old = try #require(Base24Scheme.fromYAML(flat))
        #expect(old.colors[13] == RGB(red: 13, green: 13, blue: 13))
        // Neither 16 nor 24, a gap, or a bad color: not a scheme.
        #expect(Base24Scheme.fromYAML(Self.base16.replacingOccurrences(of: "  base0F: \"#f00000\"", with: "")) == nil)
        #expect(Base24Scheme.fromYAML(Self.base24.replacingOccurrences(of: "base05", with: "base1F")) == nil)
        #expect(Base24Scheme.fromYAML(Self.base16.replacingOccurrences(of: "#000000", with: "#00000")) == nil)
    }

    @Test func aBase16SchemeGetsBase24sFallbacks() throws {
        let scheme = try #require(Base24Scheme.fromYAML(Self.base16))
        #expect(scheme.colors.count == 24)
        // base10, base11 → base00; base12 → base08; base13 → base0A … base17 → base0E.
        let from = [0x0, 0x0, 0x8, 0xA, 0xB, 0xC, 0xD, 0xE]
        #expect((0 ..< 8).allSatisfy { scheme.colors[16 + $0] == scheme.colors[from[$0]] })

        let colors = (0 ..< 24).map { String(format: "%@ = \"#%02x%02x%02x\"", Base24Scheme.slotName($0), $0, $0, $0) }
        let (settings, problems) = Settings.parse("""
        [theme]
        dark = "mine"
        [theme.schemes.mine]
        \(colors.joined(separator: "\n"))
        [theme.roles]
        folder = "base16"
        """)
        #expect(problems.isEmpty)
        let dark = try #require(settings.theme.theme(dark: true))
        #expect(dark.color(.folder) == RGB(red: 22, green: 22, blue: 22)) // base16 is slot 22
    }

    @Test func aSchemeIsNamedByNameFileOrAddress() throws {
        #expect(SchemeReference("gruvbox-dark-hard", home: "/h") == .collection("gruvbox-dark-hard"))
        #expect(SchemeReference("~/themes/x.yaml", home: "/h") == .file("/h/themes/x.yaml"))
        #expect(SchemeReference("/etc/x.yaml", home: "/h") == .file("/etc/x.yaml"))
        let url = try #require(URL(string: "https://example.com/s/x.yaml"))
        #expect(SchemeReference("https://example.com/s/x.yaml", home: "/h") == .url(url))
        for bad in ["Neon", "my theme", "../up", "a/../b", "http://example.com/x.yaml", "https://", ""] {
            #expect(SchemeReference(bad, home: "/h") == nil, "\(bad)")
        }
        #expect(SchemeReference.collection("dracula").downloadURLs.map(\.absoluteString) == [
            "https://raw.githubusercontent.com/tinted-theming/schemes/spec-0.11/base24/dracula.yaml",
            "https://raw.githubusercontent.com/tinted-theming/schemes/spec-0.11/base16/dracula.yaml",
        ])
        // A URL's cache name is stable from launch to launch.
        #expect(SchemeReference.url(url).cachePath(in: "/c") == SchemeReference.url(url).cachePath(in: "/c"))
        #expect(SchemeReference.url(url).cachePath(in: "/c")?.hasPrefix("/c/url-") == true)
    }

    // MARK: Fetching

    /// Answers by address; counts the requests.
    private final class FakeWeb: Sendable {
        let pages: [String: String]
        let requests = Mutex<[String]>([])

        init(_ pages: [String: String]) {
            self.pages = pages
        }

        var fetch: @Sendable (URL) async throws -> Data {
            { [self] url in
                requests.withLock { $0.append(url.absoluteString) }
                guard let page = pages[url.absoluteString] else {
                    throw Downloads.Failure.status(404)
                }
                return Data(page.utf8)
            }
        }
    }

    private func workspace(_ folder: TemporaryFolder, settings: String, web: FakeWeb) async throws -> Workspace {
        let path = folder.path + "/settings.toml"
        try settings.write(toFile: path, atomically: true, encoding: .utf8)
        let workspace = Workspace(initialLocation: "/", home: folder.path, lister: { _ in [] },
                                  directoryCheck: { _ in false }, volumes: { [] }, watcher: FakeWatcher.factory,
                                  settingsFile: path)
        workspace.fetch = web.fetch
        return workspace
    }

    private func settle(_ workspace: Workspace) async throws {
        for _ in 0 ..< 50 {
            await workspace.settle()
            try await Task.sleep(for: .milliseconds(5)) // a finished fetch reads the settings again
            if workspace.schemeWork.isEmpty, workspace.settingsWork == nil {
                return
            }
        }
    }

    private let collection = SchemeReference.collectionBase

    @Test func aSchemeFromTheCollectionIsFetchedOnceAndKept() async throws {
        let folder = try TemporaryFolder()
        let web = FakeWeb([collection + "base24/dracula.yaml": Self.base24])
        let workspace = try await workspace(folder, settings: "[theme]\ndark = \"dracula\"\n", web: web)
        try await settle(workspace)
        let dark = try #require(workspace.settings.theme.theme(dark: true))
        #expect(dark.color(.background) == RGB(red: 0x28, green: 0x2A, blue: 0x36))
        #expect(workspace.settings.theme.dark == "dracula")
        #expect(workspace.notices.isEmpty)
        #expect(web.requests.withLock { $0 } == [collection + "base24/dracula.yaml"])
        #expect(try String(contentsOfFile: folder.path + "/schemes/dracula.yaml", encoding: .utf8) == Self.base24)

        // The next launch takes it from the folder: nothing is fetched.
        let again = try await self.workspace(folder, settings: "[theme]\ndark = \"dracula\"\n", web: web)
        try await settle(again)
        #expect(again.settings.theme.theme(dark: true) == dark)
        #expect(web.requests.withLock { $0 }.count == 1)
    }

    @Test func withoutABase24VersionTheBase16OneIsTaken() async throws {
        let folder = try TemporaryFolder()
        let web = FakeWeb([collection + "base16/old.yaml": Self.base16])
        let workspace = try await workspace(folder, settings: "[theme]\nlight = \"old\"\n", web: web)
        try await settle(workspace)
        #expect(workspace.settings.theme.theme(dark: false)?.color(.error) == RGB(red: 0x80, green: 0, blue: 0))
        #expect(web.requests.withLock { $0 } == [collection + "base24/old.yaml", collection + "base16/old.yaml"])
    }

    @Test func aSchemeThatCannotBeFetchedIsANoticeAndNotTriedAgain() async throws {
        let folder = try TemporaryFolder()
        let web = FakeWeb([collection + "base24/broken.yaml": "<html>not found</html>"])
        let workspace = try await workspace(folder, settings: "[theme]\ndark = \"broken\"\n", web: web)
        try await settle(workspace)
        try await Task.sleep(for: .milliseconds(50))
        #expect(workspace.settings.theme.dark == "system") // the system's colors meanwhile
        #expect(workspace.notices.map(\.text) == [
            "The color scheme “broken” could not be fetched: \(collection)base16/broken.yaml: "
                + "the server answered 404.",
        ])
        #expect(web.requests.withLock { $0 }.count == 2) // both tried once, no loop
        #expect(!FileManager.default.fileExists(atPath: folder.path + "/schemes/broken.yaml"))
    }

    /// #34 review: a kept file that cannot be read (not UTF-8) is reported; it is not fetched
    /// over, which would not replace it and would start again with every read.
    @Test func anUnreadableKeptSchemeIsReportedNotFetchedAgain() async throws {
        let folder = try TemporaryFolder()
        try FileManager.default.createDirectory(atPath: folder.path + "/schemes", withIntermediateDirectories: true)
        try Data([0x62, 0x61, 0x73, 0x65, 0xFF, 0xFE])
            .write(to: URL(fileURLWithPath: folder.path + "/schemes/dracula.yaml"))
        let web = FakeWeb([collection + "base24/dracula.yaml": Self.base24])
        let workspace = try await workspace(folder, settings: "[theme]\ndark = \"dracula\"\n", web: web)
        try await settle(workspace)
        try await Task.sleep(for: .milliseconds(50))
        #expect(workspace.schemeWork.isEmpty)
        #expect(web.requests.withLock { $0 }.isEmpty)
        #expect(workspace.settings.theme.dark == "system")
        #expect(workspace.notices.count == 1)
        #expect(workspace.notices.first?.text
            .contains("dracula.yaml” is not a readable Base16 or Base24 scheme") == true)

        // The second guard: a fetch never writes over a file that is in the way.
        let download = try SchemeDownload(name: "x", urls: [#require(URL(string: collection + "base24/dracula.yaml"))],
                                          cachePath: folder.path + "/schemes/dracula.yaml")
        workspace.download([download])
        try await settle(workspace)
        #expect(workspace.notices.last?.text.hasSuffix("dracula.yaml is in the way.") == true)
        #expect(web.requests.withLock { $0 }.count == 1)
    }

    /// #34 review, round 2: a dangling symbolic link where the scheme is kept looks absent to
    /// `fileExists`; it must be reported like any other unreadable file, never fetched over.
    @Test func aDanglingLinkWhereTheSchemeIsKeptIsReportedNotFetchedAgain() async throws {
        let folder = try TemporaryFolder()
        try FileManager.default.createDirectory(atPath: folder.path + "/schemes", withIntermediateDirectories: true)
        let kept = folder.path + "/schemes/dracula.yaml"
        try FileManager.default.createSymbolicLink(atPath: kept, withDestinationPath: folder.path + "/nowhere.yaml")
        let web = FakeWeb([collection + "base24/dracula.yaml": Self.base24])
        let workspace = try await workspace(folder, settings: "[theme]\ndark = \"dracula\"\n", web: web)
        try await settle(workspace)
        try await Task.sleep(for: .milliseconds(50))
        #expect(workspace.schemeWork.isEmpty)
        #expect(web.requests.withLock { $0 }.isEmpty)
        #expect(workspace.notices.map(\.text) == [
            "Settings file: “theme.dark”: “\(kept)” is not a readable Base16 or Base24 scheme.",
        ])

        // Fetched straight into it: reported, not a reload.
        let download = try SchemeDownload(name: "x", urls: [#require(URL(string: collection + "base24/dracula.yaml"))],
                                          cachePath: kept)
        workspace.download([download])
        try await settle(workspace)
        #expect(workspace.notices.last?.text.hasSuffix("dracula.yaml is in the way.") == true)
        #expect(web.requests.withLock { $0 }.count == 1)
    }

    @Test func aFileOrAnAddressWorksToo() async throws {
        let folder = try TemporaryFolder()
        try Self.base16.write(toFile: folder.path + "/mine.yaml", atomically: true, encoding: .utf8)
        let address = "https://example.com/themes/x.yaml"
        let web = FakeWeb([address: Self.base24])
        let workspace = try await workspace(folder, settings: """
        [theme]
        light = "~/mine.yaml"
        dark = "\(address)"
        """, web: web)
        try await settle(workspace)
        #expect(workspace.settings.theme.theme(dark: false)?.color(.error) == RGB(red: 0x80, green: 0, blue: 0))
        #expect(workspace.settings.theme.theme(dark: true)?.color(.background)
            == RGB(red: 0x28, green: 0x2A, blue: 0x36))
        #expect(web.requests.withLock { $0 } == [address])
        #expect(workspace.notices.isEmpty)

        let missing = try await self.workspace(folder, settings: "[theme]\nlight = \"~/gone.yaml\"\n", web: web)
        try await settle(missing)
        #expect(missing.settings.theme.light == "system")
        #expect(missing.notices.first?.text.contains("gone.yaml” could not be read") == true)
    }
}
