import BlitterCore
import Foundation
import Testing

struct UserPathsTests {
    @Test func homeIsAnExistingAbsoluteDirectory() {
        let home = UserPaths.home
        #expect(home.hasPrefix("/"))
        #expect(!home.hasSuffix("/"))

        var isDirectory: ObjCBool = false
        #expect(FileManager.default.fileExists(atPath: home, isDirectory: &isDirectory))
        #expect(isDirectory.boolValue)
    }
}
