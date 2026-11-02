import BlitterCore
import Foundation

/// What a commit (#44) runs: its steps, and the files they give git — the message and the paths,
/// in a folder of its own that the plan owns until `discard`. Prepared and discarded off the main
/// actor: it writes to the disk.
struct GitCommitPlan: Sendable {
    let folder: String
    let steps: [Step]

    struct Step: Sendable {
        let step: GitCommitter.Step
        let arguments: [String]
    }

    /// The paths a commit of the chosen files names, each as it is on disk (`--only`): a staged
    /// rename's old path too, so its deletion goes along — but only while nothing at all is at
    /// that path on disk. Anything there (a file listed on its own, a folder with files of its
    /// own, an ignored file) is not part of the rename, and naming the path would commit it
    /// (#44 review). A copy's source is never named: it did not change.
    static func paths(of chosen: [GitFileChange], isOnDisk: (String) -> Bool) -> [String] {
        chosen.flatMap { file in
            guard file.staged == "R", let old = file.oldPath, !isOnDisk(old) else {
                return [file.path]
            }
            return [file.path, old]
        }
    }

    /// Whether anything (a file, folder or link) is at the working copy's relative `path`.
    static func isOnDisk(_ path: String, in root: String) -> Bool {
        var info = stat()
        return lstat(root + "/" + path, &info) == 0
    }

    /// Writes the files into `folder` and returns the plan; nothing is left behind if that fails.
    /// The paths go to git in a file (`--pathspec-from-file`), so any number of them, with any
    /// names, fit; `--literal-pathspecs` takes every name as it is. Checked untracked files are
    /// added first: `--only` refuses paths git does not know.
    static func prepare(
        message: String, chosen: [GitFileChange], root: String, git: String, push: Bool,
        folder: String = CompareCopies.newFolder(),
        write: (Data, String) throws -> Void = { try $0.write(to: URL(fileURLWithPath: $1)) }
    ) -> Result<GitCommitPlan, GitFailure> {
        let (messageFile, pathsFile, newFiles) = (folder + "/message", folder + "/paths", folder + "/new")
        var steps: [Step] = []
        do {
            try FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
            try write(Data(message.utf8), messageFile)
            try write(pathList(paths(of: chosen) { isOnDisk($0, in: root) }), pathsFile)
            let untracked = chosen.filter(\.isUntracked).map(\.path)
            if !untracked.isEmpty {
                try write(pathList(untracked), newFiles)
                steps.append(Step(step: .add, arguments: [git, "--literal-pathspecs", "add",
                                                          "--pathspec-from-file=" + newFiles, "--pathspec-file-nul"]))
            }
        } catch {
            try? FileManager.default.removeItem(atPath: folder)
            return .failure(GitFailure(message: "The commit could not be prepared: " + error.localizedDescription))
        }
        steps.append(Step(step: .commit, arguments: [git, "--literal-pathspecs", "commit", "--file=" + messageFile,
                                                     "--pathspec-from-file=" + pathsFile, "--pathspec-file-nul"]))
        if push {
            steps.append(Step(step: .push, arguments: [git, "push"]))
        }
        return .success(GitCommitPlan(folder: folder, steps: steps))
    }

    /// Removes the plan's files, in the background.
    func discard() {
        let folder = folder
        Task.detached(priority: .utility) {
            try? FileManager.default.removeItem(atPath: folder)
        }
    }

    /// NUL after each path, as `--pathspec-file-nul` reads them.
    private static func pathList(_ paths: [String]) -> Data {
        Data(paths.map { $0 + "\0" }.joined().utf8)
    }
}
