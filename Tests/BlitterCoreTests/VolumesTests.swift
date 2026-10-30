@testable import BlitterCore
import Foundation
import Synchronization
import Testing

struct VolumesTests {
    @Test func rootVolumeComesFirstWithItsName() async throws {
        let volumes = await mountedVolumes()
        let root = try #require(volumes.first)
        #expect(root.isRoot && root.isLocal)
        #expect(root.path == "/")
        #expect(!root.name.isEmpty && root.name != "/")
        #expect(volumes.count(where: \.isRoot) == 1)
    }

    @Test func systemVolumesAreLeftOut() async {
        let volumes = await mountedVolumes()
        #expect(volumes.allSatisfy { $0.path.hasPrefix("/") })
        #expect(!volumes.contains { $0.path.hasPrefix("/System/Volumes") || $0.path == "/dev" })
    }

    /// Each call has its own mount table buffer, so many reads at once all see the same volumes.
    @Test func concurrentReadsDoNotInterfere() {
        let expected = MountTable.browsableVolumes()
        let results = Mutex([[MountedVolume]]())
        DispatchQueue.concurrentPerform(iterations: 200) { _ in
            let volumes = MountTable.browsableVolumes()
            results.withLock { $0.append(volumes) }
        }
        let all = results.withLock { $0 }
        #expect(all.count == 200)
        #expect(all.allSatisfy { $0 == expected })
    }

    @Test func volumeNameOfTheRootMatchesTheSystem() throws {
        let expected = try #require(try URL(fileURLWithPath: "/").resourceValues(forKeys: [.volumeNameKey]).volumeName)
        #expect(MountTable.volumeName(of: "/") == expected)
        #expect(MountTable.volumeName(of: "/no/such/path") == nil)
    }
}
