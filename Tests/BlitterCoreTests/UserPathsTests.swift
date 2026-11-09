@testable import BlitterCore
import Foundation
import Testing

/// #69: an isolated Blitter's files are in its profile folder. Given environments, never the
/// process's own: other suites read the real paths at the same time.
struct UserPathsTests {
    @Test func aProfileHasItsOwnSettingsAndSocket() {
        for none in [[:], ["BLITTER_PROFILE": ""]] {
            #expect(UserPaths.profile(in: none) == nil)
            #expect(UserPaths.settingsFile(in: none) == NSHomeDirectory() + "/.config/blitter/settings.toml")
            #expect(UserPaths.automationSocket(in: none)
                == NSHomeDirectory() + "/Library/Application Support/Blitter/automation.sock")
        }
        let profile = ["BLITTER_PROFILE": "/tmp/demo-profile"]
        #expect(UserPaths.settingsFile(in: profile) == "/tmp/demo-profile/settings.toml")
        #expect(UserPaths.automationSocket(in: profile) == "/tmp/demo-profile/automation.sock")
    }
}
