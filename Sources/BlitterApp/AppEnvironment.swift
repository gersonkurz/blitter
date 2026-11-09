import BlitterCore
import Foundation

enum AppEnvironment {
    /// The app is hosting the app test bundle. Then it shares the real app's defaults, so it
    /// must not restore or save the workspace, and its views must not autosave their layout.
    static let isHostedTest = ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil

    /// An isolated run (`BLITTER_PROFILE`, #69): nothing of the window or workspace is restored
    /// or saved, so the user's own Blitter keeps its state.
    static let isProfile = UserPaths.profile != nil

    /// An autosave name for windows, split views and tables, or nil while hosting tests or in a
    /// profile.
    static func autosaveName(_ name: String) -> String? {
        isHostedTest || isProfile ? nil : name
    }
}
