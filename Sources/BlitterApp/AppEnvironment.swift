import Foundation

enum AppEnvironment {
    /// The app is hosting the app test bundle. Then it shares the real app's defaults, so it
    /// must not restore or save the workspace, and its views must not autosave their layout.
    static let isHostedTest = ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil

    /// An autosave name for windows, split views and tables, or nil while hosting tests.
    static func autosaveName(_ name: String) -> String? {
        isHostedTest ? nil : name
    }
}
