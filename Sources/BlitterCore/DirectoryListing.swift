import Dispatch
import Foundation
import Synchronization

/// One item in a folder, as returned by `listDirectory(_:)`.
public struct DirectoryEntry: Equatable, Sendable {
    public enum Kind: Equatable, Sendable {
        case file
        case directory
        case symlink
        /// Devices, sockets, FIFOs and anything else that is not a file, folder or symlink.
        case other
    }

    public var name: String
    public var kind: Kind
    /// Logical size in bytes for files and symlinks, 0 for everything else.
    public var size: Int64
    public var modificationDate: Date
    /// Name starts with "." or the item has the `UF_HIDDEN` flag.
    public var isHidden: Bool
    /// A cloud placeholder (`SF_DATALESS`) whose contents are not on this Mac yet.
    public var isDataless: Bool
    /// Non-zero errno if the file system could not read this entry's attributes. The other fields
    /// then hold whatever could be read.
    public var error: Int32

    public init(name: String, kind: Kind, size: Int64, modificationDate: Date, isHidden: Bool, isDataless: Bool,
                error: Int32)
    {
        self.name = name
        self.kind = kind
        self.size = size
        self.modificationDate = modificationDate
        self.isHidden = isHidden
        self.isDataless = isDataless
        self.error = error
    }
}

/// Lists the items of a folder with `getattrlistbulk(2)`: one system call returns attributes for
/// many entries, with no per-file `stat` and no `URL` or `FileManager` overhead.
///
/// The work runs on a GCD queue rather than the Swift concurrency pool, so a slow network or cloud
/// volume blocks only its own thread. Cancelling the calling task stops the listing between batches
/// and throws `CancellationError`. File system failures throw `POSIXError`. Only attributes are read
/// and no file is ever opened, so placeholder files of cloud drives are listed, not downloaded.
public func listDirectory(_ path: String) async throws -> [DirectoryEntry] {
    let cancelled = CancellationFlag()
    return try await withTaskCancellationHandler {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                continuation.resume(with: Result { try BulkLister.list(path, cancelled: cancelled) })
            }
        }
    } onCancel: {
        cancelled.set()
    }
}

final class CancellationFlag: Sendable {
    private let flag = Atomic(false)

    func set() {
        flag.store(true, ordering: .relaxed)
    }

    var isSet: Bool {
        flag.load(ordering: .relaxed)
    }
}

enum BulkLister {
    /// 256 KiB holds a few thousand entries per system call.
    static let defaultBufferSize = 256 * 1024

    /// `onBatch` is called after each system call that returned entries. Tests use it, together with
    /// a small `bufferSize`, to cover listings that span several buffers and cancellation mid-listing.
    static func list(_ path: String, cancelled: CancellationFlag, bufferSize: Int = defaultBufferSize,
                     onBatch: (() -> Void)? = nil) throws -> [DirectoryEntry]
    {
        if cancelled.isSet {
            throw CancellationError()
        }

        let directoryFD = open(path, O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        if directoryFD < 0 {
            throw posixError()
        }
        defer { close(directoryFD) }

        var request = attrlist()
        request.bitmapcount = u_short(ATTR_BIT_MAP_COUNT)
        // The C constants import with different integer types, so each is converted on its own.
        request.commonattr = attrgroup_t(ATTR_CMN_RETURNED_ATTRS) | attrgroup_t(ATTR_CMN_NAME)
            | attrgroup_t(ATTR_CMN_ERROR) | attrgroup_t(ATTR_CMN_OBJTYPE) | attrgroup_t(ATTR_CMN_MODTIME)
            | attrgroup_t(ATTR_CMN_FLAGS)
        request.fileattr = attrgroup_t(ATTR_FILE_DATALENGTH)

        let buffer = UnsafeMutableRawBufferPointer.allocate(byteCount: bufferSize, alignment: 16)
        defer { buffer.deallocate() }

        var entries: [DirectoryEntry] = []
        while true {
            if cancelled.isSet {
                throw CancellationError()
            }
            let count = getattrlistbulk(directoryFD, &request, buffer.baseAddress, bufferSize, 0)
            if count < 0 {
                if errno == EINTR {
                    continue
                }
                throw posixError()
            }
            if count == 0 {
                break
            }

            var offset = 0
            for _ in 0 ..< count {
                let entryLength = Int(buffer.load(fromByteOffset: offset, as: UInt32.self))
                entries.append(parseEntry(UnsafeRawBufferPointer(rebasing: buffer[offset ..< offset + entryLength])))
                offset += entryLength
            }
            onBatch?()
        }
        return entries
    }

    /// Decodes one packed entry. Attributes appear in a fixed order (the returned-attributes set
    /// and error first, then the rest by ascending bit value), but only those the file system
    /// actually returned, so every field is guarded by its bit in the returned set.
    static func parseEntry(_ entry: UnsafeRawBufferPointer) -> DirectoryEntry {
        var cursor = MemoryLayout<UInt32>.size // skip the entry length
        func read<T>(_: T.Type) -> T {
            let value = entry.loadUnaligned(fromByteOffset: cursor, as: T.self)
            cursor += MemoryLayout<T>.size
            return value
        }

        let returned = read(attribute_set_t.self)
        let common = returned.commonattr

        var result = DirectoryEntry(name: "", kind: .other, size: 0, modificationDate: Date(timeIntervalSince1970: 0),
                                    isHidden: false, isDataless: false, error: 0)

        if common & attrgroup_t(ATTR_CMN_ERROR) != 0 {
            result.error = Int32(bitPattern: read(UInt32.self))
        }
        if common & attrgroup_t(ATTR_CMN_NAME) != 0 {
            let referenceOffset = cursor
            let reference = read(attrreference_t.self)
            let nameStart = referenceOffset + Int(reference.attr_dataoffset)
            // attr_length includes the terminating NUL.
            let nameBytes = UnsafeRawBufferPointer(
                rebasing: entry[nameStart ..< nameStart + max(Int(reference.attr_length) - 1, 0)]
            )
            // APFS and HFS+ guarantee UTF-8 names. Other file systems (e.g. some SMB shares) may not;
            // lossy decoding keeps such entries visible instead of dropping them.
            // swiftlint:disable:next optional_data_string_conversion
            result.name = String(decoding: nameBytes, as: UTF8.self)
        }
        if common & attrgroup_t(ATTR_CMN_OBJTYPE) != 0 {
            result.kind = switch vtype(read(fsobj_type_t.self)) {
            case VREG: .file
            case VDIR: .directory
            case VLNK: .symlink
            default: .other
            }
        }
        if common & attrgroup_t(ATTR_CMN_MODTIME) != 0 {
            let time = read(timespec.self)
            result.modificationDate = Date(timeIntervalSince1970: Double(time.tv_sec) + Double(time.tv_nsec) / 1e9)
        }
        var flags: UInt32 = 0
        if common & attrgroup_t(ATTR_CMN_FLAGS) != 0 {
            flags = read(UInt32.self)
        }
        if returned.fileattr & attrgroup_t(ATTR_FILE_DATALENGTH) != 0 {
            result.size = read(off_t.self)
        }

        result.isHidden = result.name.hasPrefix(".") || flags & UInt32(UF_HIDDEN) != 0
        result.isDataless = flags & UInt32(SF_DATALESS) != 0
        return result
    }

    private static func posixError() -> POSIXError {
        POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
    }
}
