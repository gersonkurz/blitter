import Foundation

/// Well-known locations of the current user.
public enum UserPaths {
    /// Absolute path of the user's home directory, without a trailing slash.
    public static var home: String {
        NSHomeDirectory()
    }
}
