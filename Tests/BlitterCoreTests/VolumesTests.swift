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

    /// Free space as the Finder counts it (#51); nil for a path that is not there.
    @Test func freeSpaceOfAVolume() async throws {
        let expected = try #require(try URL(fileURLWithPath: NSTemporaryDirectory())
            .resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
            .volumeAvailableCapacityForImportantUsage)
        let space = try #require(await freeSpace(at: NSTemporaryDirectory()))
        // Other processes write meanwhile: the two reads agree to within a gigabyte.
        #expect(space > 0 && abs(space - expected) < 1_000_000_000)
        #expect(await freeSpace(at: "/no/such/path") == nil)
    }
}

/// #84: Eject on a real volume: a disk image made and mounted for the test.
struct EjectVolumeTests {
    @Test func aMountedImageIsEjectedAFolderIsNot() async throws {
        let folder = NSTemporaryDirectory() + "BlitterEject-" + UUID().uuidString
        try FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: folder) }
        let image = folder + "/test.dmg"
        let mount = folder + "/mnt"
        try hdiutil("create", "-size", "4m", "-fs", "HFS+", "-volname", "BlitterEject", "-quiet", image)
        try hdiutil("attach", "-nobrowse", "-quiet", "-mountpoint", mount, image)
        defer { try? hdiutil("detach", "-force", "-quiet", mount) } // only if the eject failed
        #expect(isMountPoint(mount))

        try await ejectVolume(at: mount)
        #expect(!isMountPoint(mount))
        // A folder that is no volume: the system says why, nothing else happens.
        await #expect(throws: (any Error).self) { try await ejectVolume(at: folder) }
    }

    /// A mount point is on another device than the folder it is in.
    private func isMountPoint(_ path: String) -> Bool {
        var inner = stat()
        var outer = stat()
        return stat(path, &inner) == 0 && stat((path as NSString).deletingLastPathComponent, &outer) == 0
            && inner.st_dev != outer.st_dev
    }

    private func hdiutil(_ arguments: String...) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/hdiutil")
        process.arguments = arguments
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw POSIXError(.EIO)
        }
    }
}
