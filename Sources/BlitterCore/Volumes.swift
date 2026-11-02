import Foundation

/// A mounted volume the user can browse.
public struct MountedVolume: Equatable, Sendable {
    public var name: String
    /// Mount point, e.g. "/" or "/Volumes/Backup".
    public var path: String
    /// False for network volumes.
    public var isLocal: Bool
    public var isRoot: Bool

    public init(name: String, path: String, isLocal: Bool, isRoot: Bool) {
        self.name = name
        self.path = path
        self.isLocal = isLocal
        self.isRoot = isRoot
    }
}

/// The volumes Finder would show, from the kernel's mount table. `MNT_NOWAIT` returns the cached
/// table without asking any file system, so an offline network volume cannot stall it; mounts
/// flagged `MNT_DONTBROWSE` (system, recovery and simulator volumes) are left out. The root volume
/// comes first. Runs on a GCD queue like `listDirectory`, because naming the root volume asks it.
public func mountedVolumes() async -> [MountedVolume] {
    await withCheckedContinuation { continuation in
        DispatchQueue.global(qos: .userInitiated).async {
            continuation.resume(returning: MountTable.browsableVolumes())
        }
    }
}

enum MountTable {
    static func browsableVolumes() -> [MountedVolume] {
        // getmntinfo would share one static buffer between all callers; this variant allocates
        // a buffer per call, so concurrent refreshes cannot overwrite each other's table.
        var mounts: UnsafeMutablePointer<statfs>?
        let count = getmntinfo_r_np(&mounts, MNT_NOWAIT)
        defer { free(mounts) }
        guard count > 0, let mounts else {
            return []
        }
        var volumes: [MountedVolume] = []
        for index in 0 ..< Int(count) {
            var info = mounts[index]
            let flags = UInt32(info.f_flags)
            guard flags & UInt32(MNT_DONTBROWSE) == 0 else {
                continue
            }
            let path = withUnsafeBytes(of: &info.f_mntonname) { bytes in
                String(cString: bytes.bindMemory(to: CChar.self)
                    .baseAddress!) // swiftlint:disable:this force_unwrapping
            }
            let isRoot = flags & UInt32(MNT_ROOTFS) != 0
            let name = isRoot ? volumeName(of: path) ?? "Macintosh HD" : (path as NSString).lastPathComponent
            volumes.append(MountedVolume(name: name, path: path, isLocal: flags & UInt32(MNT_LOCAL) != 0,
                                         isRoot: isRoot))
        }
        return volumes
            .sorted {
                $0.isRoot != $1.isRoot ? $0.isRoot : $0.name.localizedStandardCompare($1.name) == .orderedAscending
            }
    }

    /// The volume's own name (e.g. "Macintosh HD"), which its mount point "/" does not show.
    static func volumeName(of path: String) -> String? {
        var request = attrlist()
        request.bitmapcount = u_short(ATTR_BIT_MAP_COUNT)
        request.volattr = attrgroup_t(ATTR_VOL_INFO) | attrgroup_t(ATTR_VOL_NAME)
        var buffer = [UInt8](repeating: 0, count: 1024)
        let result = buffer.withUnsafeMutableBytes { getattrlist(path, &request, $0.baseAddress, $0.count, 0) }
        guard result == 0 else {
            return nil
        }
        return buffer.withUnsafeBytes { bytes in
            // u_int32_t length, then the attrreference_t of the name, relative to itself.
            let reference = bytes.loadUnaligned(fromByteOffset: 4, as: attrreference_t.self)
            let start = 4 + Int(reference.attr_dataoffset)
            let length = Int(reference.attr_length)
            guard length > 1, start + length <= bytes.count else {
                return nil
            }
            return String(bytes: bytes[start ..< start + length - 1], encoding: .utf8)
        }
    }
}

/// The space available on the volume holding `path`, as the Finder counts it (purgeable space
/// included), or nil if it cannot be read. Blocks a GCD thread, never the caller's: a stalled
/// network volume can take long to answer.
public func freeSpace(at path: String) async -> Int64? {
    await withCheckedContinuation { continuation in
        DispatchQueue.global(qos: .utility).async {
            let keys: Set<URLResourceKey> = [.volumeAvailableCapacityForImportantUsageKey, .volumeAvailableCapacityKey]
            let values = try? URL(fileURLWithPath: path, isDirectory: true).resourceValues(forKeys: keys)
            // Some volumes (network shares) know only the plain figure.
            let plain = values?.volumeAvailableCapacity.map(Int64.init)
            continuation.resume(returning: values?.volumeAvailableCapacityForImportantUsage ?? plain)
        }
    }
}
