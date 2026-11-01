import Foundation

/// Well-known locations of the current user.
public enum UserPaths {
    /// Absolute path of the user's home directory, without a trailing slash.
    public static var home: String {
        NSHomeDirectory()
    }

    /// Where Blitter's settings live: `~/.config/blitter/settings.toml`.
    public static var settingsFile: String {
        home + "/.config/blitter/settings.toml"
    }
}
