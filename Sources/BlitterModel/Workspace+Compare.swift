import BlitterCore
import Foundation

/// Comparing two files or folders in a visual diff tool (#40): the one the settings name, else
/// an installed one (Beyond Compare, else FileMerge). The tool's window goes on by itself; a tool
/// that cannot be found or started becomes a notice.
extension Workspace {
    func compare(_ left: String, _ right: String) -> Bool {
        guard !left.isEmpty, !right.isEmpty else {
            return false
        }
        let configured = settings.diffTool.map { DiffTool($0) }
        let (find, launch) = (findDiffTool, launchTool)
        compareWork = Task { [weak self] in
            let failure = await Self.startDiffTool(configured, find: find, launch: launch, left: left, right: right)
            guard let self else {
                return
            }
            compareWork = nil
            if let failure {
                addNotice("Compare: \(failure)")
                notifyChange()
            }
        }
        return false
    }

    /// Off the main actor: finding a tool looks at the disk. Returns why it failed, or nil.
    private nonisolated static func startDiffTool(_ configured: DiffTool?, find: @Sendable () -> DiffTool?,
                                                  launch: @Sendable ([String], [String: String]) throws -> Void,
                                                  left: String, right: String) async -> String?
    {
        guard let tool = configured ?? find() else {
            return "no diff tool was found. Install Beyond Compare or Xcode (FileMerge), or name one in "
                + "the settings file: [diff] tool = [\"bcomp\", \"{left}\", \"{right}\"]."
        }
        do {
            try launch(tool.command(left: left, right: right), tool.environment)
            return nil
        } catch {
            return "the diff tool could not be started: \(error.localizedDescription)."
        }
    }
}
