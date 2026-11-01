import Foundation

/// Path arithmetic on strings. Nothing here touches the disk, so it is safe on the main thread
/// even for paths on slow volumes. `..` is resolved lexically, as file managers and shells do.
enum Paths {
    /// Turns what the user typed into an absolute, normalized path: `~` and `~/…` start at `home`,
    /// a relative path starts at `base`, and empty, `.` and `..` components are resolved.
    /// Returns nil for input that is empty apart from line breaks. `~user` is not expanded.
    static func resolve(_ input: String, relativeTo base: String, home: String) -> String? {
        var path = input.trimmingCharacters(in: .newlines)
        guard !path.isEmpty else {
            return nil
        }
        if path == "~" || path.hasPrefix("~/") {
            path = home + path.dropFirst()
        }
        if !path.hasPrefix("/") {
            path = base + "/" + path
        }
        return normalize(path)
    }

    /// The folder that contains `path`, or nil for the root.
    static func parent(of path: String) -> String? {
        guard path != "/" else {
            return nil
        }
        return normalize(path + "/..")
    }

    /// Whether `path` is `folder` itself or somewhere below it.
    static func contains(_ path: String, in folder: String) -> Bool {
        folder == "/" || path == folder || path.hasPrefix(folder + "/")
    }

    static func appending(_ name: String, to folder: String) -> String {
        folder == "/" ? "/" + name : folder + "/" + name
    }

    /// The last component, e.g. the folder name to select after going up from `path`.
    static func lastComponent(of path: String) -> String {
        path.split(separator: "/").last.map(String.init) ?? "/"
    }

    private static func normalize(_ path: String) -> String {
        var components: [Substring] = []
        for component in path.split(separator: "/") {
            switch component {
            case ".":
                continue
            case "..":
                _ = components.popLast()
            default:
                components.append(component)
            }
        }
        return "/" + components.joined(separator: "/")
    }

    /// Why a folder could not be read, as the list shows it.
    static func listingMessage(for error: Error, location: String) -> String {
        if let posix = error as? POSIXError {
            return "\(location): \(String(cString: strerror(posix.code.rawValue)))"
        }
        return "\(location): \(error.localizedDescription)"
    }
}
