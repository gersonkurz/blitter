import Foundation

/// Fetching a small file over HTTPS (a color scheme, #34): no cookies or cache shared with
/// anything else, a time limit, and a size limit.
public enum Downloads {
    /// Larger answers are refused: scheme files are about 2 KB.
    public static let sizeLimit = 256 * 1024

    public enum Failure: Error, LocalizedError, Equatable {
        case notHTTPS
        case status(Int)
        case tooLarge

        public var errorDescription: String? {
            switch self {
            case .notHTTPS: "only https addresses are fetched"
            case let .status(code): "the server answered \(code)"
            case .tooLarge: "the answer is larger than \(Downloads.sizeLimit / 1024) KB"
            }
        }
    }

    public static func fetch(_ url: URL) async throws -> Data {
        guard url.scheme?.lowercased() == "https" else {
            throw Failure.notHTTPS
        }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 15
        configuration.timeoutIntervalForResource = 30
        let session = URLSession(configuration: configuration)
        defer { session.finishTasksAndInvalidate() }
        let (bytes, response) = try await session.bytes(from: url)
        if let http = response as? HTTPURLResponse, http.statusCode != 200 {
            throw Failure.status(http.statusCode)
        }
        if response.expectedContentLength > sizeLimit {
            throw Failure.tooLarge
        }
        var data = Data()
        for try await byte in bytes {
            data.append(byte)
            if data.count > sizeLimit {
                throw Failure.tooLarge
            }
        }
        return data
    }
}
