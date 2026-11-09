import Foundation

/// Well-known locations of the current user.
public enum UserPaths {
    /// Absolute path of the user's home directory, without a trailing slash.
    public static var home: String {
        NSHomeDirectory()
    }

    /// A folder of its own for an isolated Blitter (#69: the manual's menu screenshots), from
    /// `BLITTER_PROFILE`: its settings file and automation socket are there, and it saves no window
    /// state, so the user's own Blitter is left alone. Nil normally.
    public static var profile: String? {
        profile(in: ProcessInfo.processInfo.environment)
    }

    /// Where Blitter's settings live: `~/.config/blitter/settings.toml` (or in the profile).
    public static var settingsFile: String {
        settingsFile(in: ProcessInfo.processInfo.environment)
    }

    /// The automation socket (#58), private to the user: the CLI, MCP and Python reach Blitter here.
    public static var automationSocket: String {
        automationSocket(in: ProcessInfo.processInfo.environment)
    }

    static func profile(in environment: [String: String]) -> String? {
        environment["BLITTER_PROFILE"].flatMap { $0.isEmpty ? nil : $0 }
    }

    static func settingsFile(in environment: [String: String]) -> String {
        profile(in: environment).map { $0 + "/settings.toml" } ?? home + "/.config/blitter/settings.toml"
    }

    static func automationSocket(in environment: [String: String]) -> String {
        profile(in: environment).map { $0 + "/automation.sock" }
            ?? home + "/Library/Application Support/Blitter/automation.sock"
    }
}
