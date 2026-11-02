import Foundation

/// A visual diff tool's command line (#40): the program and its arguments with `{left}` and
/// `{right}` standing for what is compared, and anything its environment needs.
public struct DiffTool: Equatable, Sendable {
    public let arguments: [String]
    public let environment: [String: String]

    public init(_ arguments: [String], environment: [String: String] = [:]) {
        self.arguments = arguments
        self.environment = environment
    }

    /// The command line for comparing `left` with `right`. Each argument is read once, front to
    /// back: what is put in is never looked at again, so a file named "{right}.txt" stays one.
    public func command(left: String, right: String) -> [String] {
        arguments.map { argument in
            var result = ""
            var rest = argument[...]
            while !rest.isEmpty {
                if rest.hasPrefix("{left}") {
                    result += left
                    rest = rest.dropFirst(6)
                } else if rest.hasPrefix("{right}") {
                    result += right
                    rest = rest.dropFirst(7)
                } else {
                    result.append(rest.removeFirst())
                }
            }
            return result
        }
    }

    /// The installed tool to use when the settings name none: Beyond Compare (`bcomp` on the
    /// search path, or inside the app), else FileMerge, which comes with Xcode, through
    /// `opendiff` (told which Xcode, so it never asks to install developer tools). Looks at the
    /// disk: call it off the main thread.
    public static func detect(applications: [String] = ["/Applications", NSHomeDirectory() + "/Applications"],
                              searchPath: [String]? = nil, opendiff: String = "/usr/bin/opendiff") -> DiffTool?
    {
        if let bcomp = FileOperations.executable("bcomp", searching: searchPath ?? FileOperations.searchPath()) {
            return DiffTool([bcomp, "{left}", "{right}"])
        }
        let bundles = applications.flatMap { folder in
            ((try? FileManager.default.contentsOfDirectory(atPath: folder)) ?? []).sorted().map { (folder, $0) }
        }
        for (folder, name) in bundles where name.hasPrefix("Beyond Compare") && name.hasSuffix(".app") {
            let bcomp = folder + "/" + name + "/Contents/MacOS/bcomp"
            if FileManager.default.isExecutableFile(atPath: bcomp) {
                return DiffTool([bcomp, "{left}", "{right}"])
            }
        }
        guard FileManager.default.isExecutableFile(atPath: opendiff) else {
            return nil
        }
        for (folder, name) in bundles where name.hasPrefix("Xcode") && name.hasSuffix(".app") {
            let xcode = folder + "/" + name
            if FileManager.default.fileExists(atPath: xcode + "/Contents/Applications/FileMerge.app") {
                return DiffTool([opendiff, "{left}", "{right}"],
                                environment: ["DEVELOPER_DIR": xcode + "/Contents/Developer"])
            }
        }
        return nil
    }
}
