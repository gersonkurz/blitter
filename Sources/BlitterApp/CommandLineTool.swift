import AppKit

/// Blitter → Install Command-Line Tool… (#97): `blitter` on the PATH, as a symbolic link
/// `/usr/local/bin/blitter` to the tool inside this Blitter.app, so it follows the app through
/// updates. `/usr/local/bin` is on every Mac's default PATH (`/etc/paths`). Writing there usually
/// takes an administrator's password, asked for by macOS's own prompt; a folder the user may write
/// to (some Intel Macs with Homebrew) needs none.
///
/// Everything here touches the file system: it runs off the main actor (#97 review). Making and
/// removing the link is one shell script either way, and the script itself looks again at what
/// is there right before it changes anything: something that is not a Blitter's link, also one
/// that appeared while the password was asked for, is never written over or removed.
struct CommandLineTool: Sendable {
    enum Status: Equatable, Sendable {
        case notInstalled
        /// A link to a Blitter.app's tool: this one's, or another copy's.
        case installed(target: String)
        /// Something else is there: never touched.
        case taken
    }

    /// The tool inside the app, and where its link goes.
    let tool: String
    let link: String
    /// Runs a shell script as the user; nil if it worked, else why not. Tests replace it.
    var runAsUser: @Sendable (String) async -> String? = { await CommandLineTool.run(script: $0, privileged: false) }
    /// Runs a shell script as an administrator (macOS asks for the password); nil if it worked or
    /// the user cancelled, else why not. Tests replace it.
    var runAsAdministrator: @Sendable (String) async -> String? = { await CommandLineTool.run(script: $0) }

    static var current: CommandLineTool {
        CommandLineTool(tool: Bundle.main.bundlePath + "/Contents/Helpers/blitter", link: "/usr/local/bin/blitter")
    }

    /// What is at the link now.
    var status: Status {
        guard let destination = try? FileManager.default.destinationOfSymbolicLink(atPath: link) else {
            return (try? FileManager.default.attributesOfItem(atPath: link)) == nil ? .notInstalled : .taken
        }
        return destination.hasSuffix(Self.toolSuffix) ? .installed(target: destination) : .taken
    }

    /// Only a Blitter in an Applications folder is linked: a link into a build folder would break
    /// with the next build or clean.
    var isInstallable: Bool {
        FileManager.default.isExecutableFile(atPath: tool) && Self.isInApplications(tool, home: NSHomeDirectory())
    }

    /// Whether `tool` (…/X.app/Contents/Helpers/blitter) is in /Applications or ~/Applications.
    static func isInApplications(_ tool: String, home: String) -> Bool {
        var path = tool as NSString
        for _ in 0 ..< 4 { // blitter, Helpers, Contents, X.app
            path = path.deletingLastPathComponent as NSString
        }
        return path as String == "/Applications" || path as String == home + "/Applications"
    }

    /// Links the tool (replacing a link to another Blitter's); nil if it worked, else why not.
    func install() async -> String? {
        guard status != .taken else {
            return Self.taken(link)
        }
        return await run(Self.installScript(tool: tool, link: link))
    }

    /// Removes the link, only if it is a Blitter's; nil if it worked (or there is none), else why not.
    func uninstall() async -> String? {
        guard case .installed = status else {
            return nil
        }
        return await run(Self.uninstallScript(link: link))
    }

    /// As the user where the link's folder lets them write, else as an administrator.
    private func run(_ script: String) async -> String? {
        let folder = (link as NSString).deletingLastPathComponent
        if FileManager.default.isWritableFile(atPath: folder) {
            return await runAsUser(script)
        }
        return await runAsAdministrator(script)
    }

    // MARK: Scripts

    private static let toolSuffix = ".app/Contents/Helpers/blitter"

    static func taken(_ link: String) -> String {
        "\(link) is something else; Blitter leaves it alone."
    }

    /// Stops (status 3, the reason on stderr) unless the link is missing or a Blitter's link.
    private static func checkFree(_ link: String) -> String {
        let word = quoted(link)
        let refuse = "echo \(quoted(taken(link))) >&2; exit 3"
        return "if [ -L \(word) ]; then case \"$(readlink \(word))\" in *\(toolSuffix)) ;; *) \(refuse);; esac; "
            + "elif [ -e \(word) ]; then \(refuse); fi"
    }

    /// Its folder if missing, a look at what is there now, then the link.
    static func installScript(tool: String, link: String) -> String {
        "mkdir -p \(quoted((link as NSString).deletingLastPathComponent)) && \(checkFree(link)) && "
            + "ln -sfn \(quoted(tool)) \(quoted(link))"
    }

    /// A look at what is there now, then away with it if it is a Blitter's link.
    static func uninstallScript(link: String) -> String {
        "\(checkFree(link)) && rm -f \(quoted(link))"
    }

    /// A shell word: in single quotes, a single quote written as '\''.
    static func quoted(_ text: String) -> String {
        "'" + text.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// AppleScript's `do shell script`, the script in an AppleScript string; `privileged`: as an
    /// administrator (macOS's own password prompt, no helper tool to install).
    static func appleScript(_ script: String, privileged: Bool = true) -> String {
        let escaped = script.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
        return "do shell script \"\(escaped)\"" + (privileged ? " with administrator privileges" : "")
    }

    /// Runs `script` through osascript as an administrator (`privileged`), else through sh; nil
    /// if it worked, else why not (nothing if the user cancelled the password prompt).
    static func run(script: String, privileged: Bool = true) async -> String? {
        let process = Process()
        if privileged {
            process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
            process.arguments = ["-e", appleScript(script)]
        } else {
            process.executableURL = URL(fileURLWithPath: "/bin/sh")
            process.arguments = ["-c", script]
        }
        let errors = Pipe()
        process.standardError = errors
        return await withCheckedContinuation { continuation in
            process.terminationHandler = { process in
                let text = String(bytes: errors.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
                // -128: the user cancelled the password prompt; nothing to report.
                let failure: String? = if process.terminationStatus == 0 || (privileged && text.contains("-128")) {
                    nil
                } else {
                    text.trimmingCharacters(in: .whitespacesAndNewlines)
                }
                continuation.resume(returning: failure)
            }
            do {
                try process.run()
            } catch {
                continuation.resume(returning: error.localizedDescription)
            }
        }
    }
}

extension AppDelegate {
    /// The Blitter menu's item, from the status last read (menus are validated on the main
    /// thread, which never reads the disk).
    static func commandLineToolTitle(_ status: CommandLineTool.Status) -> String {
        if case .installed = status {
            return "Uninstall Command-Line Tool…"
        }
        return "Install Command-Line Tool…"
    }

    /// Reads what is at the link, off the main thread, for the menu's title: at launch, and when
    /// Blitter becomes active again (a terminal may have changed it).
    func refreshCommandLineTool() {
        Task {
            commandLineToolStatus = await Task.detached { CommandLineTool.current.status }.value
        }
    }

    /// Uninstall while a Blitter's tool is linked, else Install; the disk is read and changed off
    /// the main thread.
    @objc func toggleCommandLineTool(_: Any?) {
        Task {
            let tool = CommandLineTool.current
            let (before, installable) = await Task.detached { (tool.status, tool.isInstallable) }.value
            if case .installed = before {
                if let problem = await Task.detached(operation: { await tool.uninstall() }).value {
                    explain("The command-line tool could not be removed.", problem)
                }
            } else if !installable {
                explain("Only a Blitter in the Applications folder links its tool.",
                        "This one is at \(Bundle.main.bundlePath). Move it to /Applications, or add its "
                            + "Contents/Helpers folder to your PATH.")
            } else if let problem = await Task.detached(operation: { await tool.install() }).value {
                explain("The command-line tool could not be installed.", problem)
            }
            let after = await Task.detached { tool.status }.value
            commandLineToolStatus = after
            if before != after, after == .installed(target: tool.tool) {
                explain("blitter is installed in \(tool.link).", "In a new terminal window, try “blitter --help”.")
            }
        }
    }

    private func explain(_ message: String, _ detail: String) {
        let alert = NSAlert()
        alert.messageText = message
        alert.informativeText = detail
        alert.runModal()
    }
}
