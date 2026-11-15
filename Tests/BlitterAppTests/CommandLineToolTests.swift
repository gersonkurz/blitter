import AppKit
@testable import Blitter
import Foundation
import Synchronization
import Testing

/// #97: the `blitter` link on the PATH: made, replaced, removed only when it is a Blitter's;
/// without a password where the folder is writable, through the administrator prompt elsewhere.
@MainActor
final class CommandLineToolTests {
    private let folder = NSTemporaryDirectory() + "BlitterCLI-" + UUID().uuidString
    private let tool: String
    private let other = "/Applications/Other Copy.app/Contents/Helpers/blitter"

    init() throws {
        tool = folder + "/Blitter.app/Contents/Helpers/blitter"
        try FileManager.default.createDirectory(atPath: folder + "/bin", withIntermediateDirectories: true)
    }

    deinit {
        try? FileManager.default.removeItem(atPath: folder)
    }

    private func installer(_ link: String? = nil) -> CommandLineTool {
        CommandLineTool(tool: tool, link: link ?? folder + "/bin/blitter")
    }

    @Test func installReplaceAndRemoveAWritableLink() async throws {
        let cli = installer()
        #expect(cli.status == .notInstalled)
        try FileManager.default.createSymbolicLink(atPath: cli.link, withDestinationPath: other)
        #expect(cli.status == .installed(target: other)) // another copy's: counts, Uninstall removes it

        #expect(await cli.install() == nil) // replaced by this one's
        #expect(cli.status == .installed(target: tool))
        #expect(await cli.uninstall() == nil)
        #expect(cli.status == .notInstalled)
    }

    @Test func somethingElseThereIsLeftAlone() async throws {
        let cli = installer()
        FileManager.default.createFile(atPath: cli.link, contents: Data("mine".utf8))
        #expect(cli.status == .taken)
        #expect(await cli.install()?.contains("something else") == true)
        #expect(await cli.uninstall() == nil) // nothing to remove: not a Blitter's
        #expect(try String(contentsOfFile: cli.link, encoding: .utf8) == "mine")

        try FileManager.default.removeItem(atPath: cli.link)
        try FileManager.default.createSymbolicLink(atPath: cli.link, withDestinationPath: "/usr/bin/true")
        #expect(cli.status == .taken) // a link, but not to a Blitter's tool
    }

    @Test func aFolderOnlyAnAdministratorMayWriteToAsks() async {
        let scripts = Mutex<[String]>([])
        var cli = installer("/no-such-folder-\(UUID().uuidString)/bin/blitter")
        cli.runAsAdministrator = { script in
            scripts.withLock { $0.append(script) }
            return nil
        }
        #expect(await cli.install() == nil)
        #expect(scripts.withLock { $0 } == [CommandLineTool.installScript(tool: tool, link: cli.link)])
    }

    /// #97 review: something that appears at the link after the first look (while the password
    /// is asked for) is neither written over nor removed: the script looks again.
    @Test func somethingThatAppearsMeanwhileIsLeftAlone() async throws {
        var cli = installer()
        let link = cli.link
        cli.runAsUser = { script in
            FileManager.default.createFile(atPath: link, contents: Data("arrived".utf8)) // meanwhile
            return await CommandLineTool.run(script: script, privileged: false)
        }
        #expect(await cli.install() == CommandLineTool.taken(link))
        #expect(try String(contentsOfFile: link, encoding: .utf8) == "arrived")

        try FileManager.default.removeItem(atPath: link)
        try FileManager.default.createSymbolicLink(atPath: link, withDestinationPath: other) // a Blitter's
        cli.runAsUser = { script in
            try? FileManager.default.removeItem(atPath: link)
            try? FileManager.default.createSymbolicLink(atPath: link, withDestinationPath: "/usr/bin/true")
            return await CommandLineTool.run(script: script, privileged: false)
        }
        #expect(await cli.uninstall() == CommandLineTool.taken(link))
        #expect(try FileManager.default.destinationOfSymbolicLink(atPath: link) == "/usr/bin/true")
    }

    @Test func wordsAreQuotedForTheShell() {
        #expect(CommandLineTool.quoted("/Applications/Blitter.app") == "'/Applications/Blitter.app'")
        #expect(CommandLineTool.quoted("it's") == "'it'\\''s'")
    }

    /// Only a Blitter in an Applications folder is linked, never a build folder's.
    @Test func onlyAnApplicationsFoldersBlitterIsLinked() {
        let helper = "/Blitter.app/Contents/Helpers/blitter"
        #expect(CommandLineTool.isInApplications("/Applications" + helper, home: "/Users/me"))
        #expect(CommandLineTool.isInApplications("/Users/me/Applications" + helper, home: "/Users/me"))
        #expect(!CommandLineTool.isInApplications("/Users/me/dev/build/Debug" + helper, home: "/Users/me"))
        #expect(!installer().isInstallable) // a temporary folder's
    }

    /// The Blitter menu offers it, titled by whether the tool is linked now.
    @Test func theBlitterMenuOffersIt() throws {
        let appMenu = try #require(NSApp.mainMenu?.items.first?.submenu)
        let item = try #require(appMenu.items.first { $0.action == NSSelectorFromString("toggleCommandLineTool:") })
        let delegate = try #require(NSApp.delegate as? AppDelegate)
        #expect(delegate.validateMenuItem(item))
        #expect(item.title == AppDelegate.commandLineToolTitle(delegate.commandLineToolStatus))
        #expect(AppDelegate.commandLineToolTitle(.notInstalled) == "Install Command-Line Tool…")
        #expect(AppDelegate.commandLineToolTitle(.installed(target: other)) == "Uninstall Command-Line Tool…")
    }

    /// The scripts as osascript would run them, for real through the shell (the administrator
    /// prompt needs a person), and the AppleScript string they become: a folder named with a space, quotes and a
    /// backslash is made, the
    /// link in it points at the tool, and then it is removed.
    @Test func theScriptsRunThroughAppleScript() async throws {
        let odd = folder + "/it's \"odd\" \\ bin"
        let link = odd + "/blitter"
        #expect(await CommandLineTool.run(script: CommandLineTool.installScript(tool: tool, link: link),
                                          privileged: false) == nil)
        #expect(try FileManager.default.destinationOfSymbolicLink(atPath: link) == tool)
        #expect(await CommandLineTool.run(script: CommandLineTool.uninstallScript(link: link),
                                          privileged: false) == nil)
        #expect(!FileManager.default.fileExists(atPath: link))

        // The same script as the AppleScript string the password prompt runs, through osascript
        // (without the prompt): the quotes and the backslash survive both languages.
        try osascript(CommandLineTool.appleScript(CommandLineTool.installScript(tool: tool, link: link),
                                                  privileged: false))
        #expect(try FileManager.default.destinationOfSymbolicLink(atPath: link) == tool)
        #expect(CommandLineTool.appleScript("true").hasSuffix(" with administrator privileges"))
    }

    private func osascript(_ source: String) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-e", source]
        try process.run()
        process.waitUntilExit()
        #expect(process.terminationStatus == 0)
    }
}
