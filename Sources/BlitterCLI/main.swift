import BlitterCore
import Foundation

// The `blitter` tool (#59): one request to the running Blitter per call, the result printed as
// JSON; or folders to show (#98), printing nothing. Exit status: 0 done, 1 Blitter answered with an error (or a usage
// error), 2 Blitter is
// not running.

/// Writes to standard error.
func complain(_ text: String) {
    FileHandle.standardError.write(Data((text + "\n").utf8))
}

func pretty(_ value: JSONValue) -> String {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
    return (try? encoder.encode(value)).flatMap { String(bytes: $0, encoding: .utf8) } ?? value.line
}

/// `blitter mcp` (#60): MCP over stdin and stdout until stdin ends, on one session with Blitter
/// (`AutomationSession`). Only protocol lines go to stdout.
func serveMCP() -> Int32 {
    let session = AutomationSession()
    let server = MCPServer(call: session.call)
    while let line = readLine(strippingNewline: true) {
        if let reply = server.handle(line) {
            print(reply)
            fflush(stdout)
        }
    }
    return 0
}

/// The Blitter.app this tool is part of (followed through a link such as /usr/local/bin/blitter),
/// nil for a tool outside one.
func appBundle() -> String? {
    var size: UInt32 = 0
    _NSGetExecutablePath(nil, &size)
    var buffer = [CChar](repeating: 0, count: Int(size))
    guard _NSGetExecutablePath(&buffer, &size) == 0 else {
        return nil
    }
    var path = URL(fileURLWithPath: String(cString: buffer)).resolvingSymlinksInPath().path as NSString
    for _ in 0 ..< 3 { // blitter, Helpers, Contents
        path = path.deletingLastPathComponent as NSString
    }
    return path.hasSuffix(".app") ? path as String : nil
}

/// Brings that Blitter to the front, starting it if it is not running; whether it did.
func openApp() -> Bool {
    guard let app = appBundle() else {
        return false
    }
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
    process.arguments = ["-a", app]
    guard (try? process.run()) != nil else {
        return false
    }
    process.waitUntilExit()
    return process.terminationStatus == 0
}

/// `blitter [--new] [FOLDER [FOLDER]]` (#98): Blitter in front (started if need be; not for a
/// socket of BLITTER_SOCKET's, which tests and a second instance use), then the folders shown.
func showFolders(_ show: ShowFolders) -> Int32 {
    let started = ProcessInfo.processInfo.environment["BLITTER_SOCKET"] == nil && openApp()
    // A Blitter just started serves its socket a moment later: wait up to 10 seconds for it.
    for attempt in 1 ... (started ? 100 : 1) {
        do {
            let client = try AutomationClient()
            if let problem = try show.perform(with: client) {
                complain(problem)
                return 1
            }
            return 0
        } catch let AutomationClient.Failure.notRunning(path) {
            guard attempt < (started ? 100 : 1) else {
                complain("blitter: Blitter is not running (nothing serves \(path)).")
                return 2
            }
            usleep(100_000)
        } catch {
            complain("blitter: \(error)")
            return 1
        }
    }
    return 2
}

func main() -> Int32 {
    let arguments = Array(CommandLine.arguments.dropFirst())
    if arguments == ["mcp"] {
        return serveMCP()
    }
    do {
        if let show = try ShowFolders.parse(arguments, in: FileManager.default.currentDirectoryPath,
                                            home: NSHomeDirectory(), kind: ShowFolders.kind(of:))
        {
            return showFolders(show)
        }
    } catch {
        complain(error.message)
        return 1
    }
    let request: (method: String, params: JSONValue)
    do {
        request = try AutomationCommandLine.request(arguments)
    } catch {
        let wanted = ["help", "-h", "--help"].contains(arguments.first ?? "")
        if wanted {
            print(error.message)
            return 0
        }
        complain(error.message)
        return 1
    }
    do {
        let reply = try AutomationClient().call(request.method, request.params)
        if let error = reply["error"] {
            complain("blitter: \(error["message"]?.string ?? "error") (code \(error["code"]?.int ?? 0))")
            return 1
        }
        print(pretty(reply["result"] ?? .null))
        return 0
    } catch let AutomationClient.Failure.notRunning(path) {
        complain("blitter: Blitter is not running (nothing serves \(path)).")
        return 2
    } catch {
        complain("blitter: \(error)")
        return 1
    }
}

exit(main())
