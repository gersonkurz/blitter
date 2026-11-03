/// One connection to Blitter for a client that lives long (`blitter mcp`, #60): opened when first
/// needed, opened again when Blitter was restarted. A request is sent again only when that cannot
/// carry it out twice: it never reached Blitter, or it only reads. Otherwise the uncertainty is
/// reported, never hidden by a second try (#60 review).
public final class AutomationSession {
    private var client: AutomationClient?
    private let connect: () throws -> AutomationClient

    /// The methods that change nothing, so asking twice is harmless.
    public static let readOnly: Set<String> = ["hello", "state", "listing", "actions", "preview"]

    public init(connect: @escaping () throws -> AutomationClient = { try AutomationClient() }) {
        self.connect = connect
    }

    public func call(_ method: String, _ params: JSONValue) throws -> JSONValue {
        if let client {
            do {
                return try client.call(method, params)
            } catch AutomationClient.Failure.notSent {
                self.client = nil // Blitter went away before it got this: send it to the new one
            } catch AutomationClient.Failure.closed {
                self.client = nil
                guard Self.readOnly.contains(method) else {
                    throw AutomationClient.Failure.closed // it may have run: say so, do not repeat it
                }
            }
        }
        let fresh = try connect()
        client = fresh
        return try fresh.call(method, params)
    }
}
