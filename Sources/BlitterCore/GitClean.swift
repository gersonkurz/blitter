import Foundation

/// What `git clean` would remove in a folder (#71): paths relative to it, a folder's ending in
/// "/", and the nested repositories it leaves alone.
public struct GitCleanPreview: Equatable, Sendable {
    public var removed: [String] = []
    public var skippedRepositories: [String] = []

    public init(removed: [String] = [], skippedRepositories: [String] = []) {
        self.removed = removed
        self.skippedRepositories = skippedRepositories
    }
}

public extension Git {
    /// `git clean -n` in `folder`, with `-d` (untracked folders) and `-x` (ignored files too) as
    /// asked. Git's own decision of what is untracked, nested repositories included. Nil if git
    /// fails or is cancelled. Reads the disk: off the main thread.
    static func cleanPreview(in folder: String, folders: Bool, ignored: Bool, git: String? = executable,
                             timeout: TimeInterval = 30,
                             cancelled: CancellationFlag = CancellationFlag()) -> GitCleanPreview?
    {
        guard let git else {
            return nil
        }
        let arguments = ["-c", "core.quotepath=false", "clean", "-n"] + (folders ? ["-d"] : []) +
            (ignored ? ["-x"] : [])
        // Started in the folder: git lists what is in it, and never offers the folder itself.
        guard let data = run(git, arguments, in: folder, until: Date() + timeout, cancelled: cancelled,
                             english: true, startingIn: true)
        else {
            return nil
        }
        // swiftlint:disable:next optional_data_string_conversion
        var preview = parseCleanPreview(String(decoding: data, as: UTF8.self)) // lossy is fine: a bad path fails later
        preview.removed.removeAll { $0.isEmpty || $0 == "." } // never the folder itself
        return preview
    }

    /// "Would remove <path>" and "Would skip repository <path>" lines, paths unquoted and without
    /// the "./" git puts in front when the whole folder is untracked (it then also says it
    /// would refuse to remove the folder itself, which is no path to take).
    static func parseCleanPreview(_ text: String) -> GitCleanPreview {
        func path(_ text: Substring) -> String {
            let path = unquote(String(text))
            return path.hasPrefix("./") ? String(path.dropFirst(2)) : path
        }
        var preview = GitCleanPreview()
        for line in text.split(separator: "\n", omittingEmptySubsequences: true) {
            if line.hasPrefix("Would remove ") {
                preview.removed.append(path(line.dropFirst("Would remove ".count)))
            } else if line.hasPrefix("Would skip repository ") {
                preview.skippedRepositories.append(path(line.dropFirst("Would skip repository ".count)))
            }
        }
        return preview
    }

    /// A path as git prints it: as is, or in double quotes with C escapes (\\, \", \n, \t,
    /// \NNN octal bytes) when it has unusual characters.
    static func unquote(_ path: String) -> String {
        guard path.count >= 2, path.hasPrefix("\""), path.hasSuffix("\"") else {
            return path
        }
        var bytes: [UInt8] = []
        var characters = Array(path.utf8.dropFirst().dropLast())[...]
        while let byte = characters.popFirst() {
            guard byte == UInt8(ascii: "\\"), let next = characters.popFirst() else {
                bytes.append(byte)
                continue
            }
            switch next {
            case UInt8(ascii: "n"): bytes.append(0x0A)
            case UInt8(ascii: "t"): bytes.append(0x09)
            case UInt8(ascii: "a"): bytes.append(0x07)
            case UInt8(ascii: "b"): bytes.append(0x08)
            case UInt8(ascii: "f"): bytes.append(0x0C)
            case UInt8(ascii: "r"): bytes.append(0x0D)
            case UInt8(ascii: "v"): bytes.append(0x0B)
            case UInt8(ascii: "0") ... UInt8(ascii: "7"):
                var value = Int(next - UInt8(ascii: "0"))
                for _ in 0 ..< 2 {
                    guard let digit = characters.first, (UInt8(ascii: "0") ... UInt8(ascii: "7")).contains(digit) else {
                        break
                    }
                    characters.removeFirst()
                    value = value * 8 + Int(digit - UInt8(ascii: "0"))
                }
                bytes.append(UInt8(value & 0xFF))
            default: bytes.append(next) // \\ and \"
            }
        }
        // swiftlint:disable:next optional_data_string_conversion
        return String(decoding: bytes, as: UTF8.self) // a path that is not UTF-8 is not found: reported, never guessed
    }
}
