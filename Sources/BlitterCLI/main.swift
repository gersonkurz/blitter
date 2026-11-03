import BlitterCore
import Foundation

// The `blitter` tool (#59): one request to the running Blitter per call, the result printed as
// JSON. Exit status: 0 done, 1 Blitter answered with an error (or a usage error), 2 Blitter is
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

func main() -> Int32 {
    let arguments = Array(CommandLine.arguments.dropFirst())
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
