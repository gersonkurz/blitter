@testable import BlitterCore
import Foundation
import Testing

/// The diff tool (#40): its command line, finding an installed one, and starting it detached.
struct DiffToolTests {
    private func executable(_ path: String) throws {
        try FileManager.default.createDirectory(atPath: (path as NSString).deletingLastPathComponent,
                                                withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: path, contents: Data("#!/bin/sh\n".utf8))
        chmod(path, 0o755)
    }

    @Test func thePlaceholdersBecomeThePaths() {
        let tool = DiffTool(["bcomp", "{left}", "--title={right}", "{right}"])
        #expect(tool.command(left: "/a b/x", right: "/c;d") == ["bcomp", "/a b/x", "--title=/c;d", "/c;d"])
        // #40 review: a placeholder's text in a path is the path's, never filled in again.
        let template = DiffTool(["t", "{left}", "--pair={left}:{right}", "{right}", "{lef", "x{right}y{left}"])
        #expect(template.command(left: "/a/{right}.txt", right: "/b/{left}") == [
            "t", "/a/{right}.txt", "--pair=/a/{right}.txt:/b/{left}", "/b/{left}", "{lef", "x/b/{left}y/a/{right}.txt",
        ])
    }

    @Test func beyondCompareIsFoundOnThePathOrInsideTheAppElseFileMerge() throws {
        let folder = try TemporaryFolder()
        let apps = folder.path + "/Applications"
        let opendiff = folder.path + "/bin/opendiff"
        try executable(opendiff)
        try FileManager.default.createDirectory(atPath: apps + "/Xcode-beta.app/Contents/Applications/FileMerge.app",
                                                withIntermediateDirectories: true)
        // Only Xcode: FileMerge through opendiff, told which Xcode.
        #expect(DiffTool.detect(applications: [apps], searchPath: [], opendiff: opendiff) == DiffTool(
            [opendiff, "{left}", "{right}"], environment: ["DEVELOPER_DIR": apps + "/Xcode-beta.app/Contents/Developer"]
        ))
        // Beyond Compare inside its app (any name starting so) wins over FileMerge.
        let inApp = apps + "/Beyond Compare-2.app/Contents/MacOS/bcomp"
        try executable(inApp)
        #expect(DiffTool.detect(applications: [apps], searchPath: [], opendiff: opendiff)
            == DiffTool([inApp, "{left}", "{right}"]))
        // On the search path it wins over everything.
        let onPath = folder.path + "/bin/bcomp"
        try executable(onPath)
        #expect(DiffTool.detect(applications: [apps], searchPath: [folder.path + "/bin"], opendiff: opendiff)
            == DiffTool([onPath, "{left}", "{right}"]))
        // Nothing at all.
        #expect(DiffTool.detect(applications: [folder.path + "/none"], searchPath: [], opendiff: "/nonexistent") == nil)
        // opendiff without an Xcode that has FileMerge: never used (it would ask to install tools).
        #expect(DiffTool.detect(applications: [folder.path + "/none"], searchPath: [], opendiff: opendiff) == nil)
    }

    @Test func aLaunchedProgramRunsOnItsOwnAndIsCollectedWhenItEnds() async throws {
        let folder = try TemporaryFolder()
        let pidFile = folder.path + "/pid"
        // It writes its pid, then exits with a code a diff tool would use for "different".
        try Launcher.launch(["sh", "-c", "echo $$ > \"$1\"; echo noise >&2; exit 13", "sh", pidFile],
                            environment: ["BLITTER_PROBE": "1"])
        var pid: pid_t = 0
        for _ in 0 ..< 200 {
            if let text = try? String(contentsOfFile: pidFile, encoding: .utf8),
               let value = pid_t(text.trimmingCharacters(in: .whitespacesAndNewlines))
            {
                pid = value
                break
            }
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(pid > 0)
        // Collected: a zombie would still answer kill(pid, 0); a reaped process is gone.
        var gone = false
        for _ in 0 ..< 200 where !gone {
            gone = kill(pid, 0) == -1 && errno == ESRCH
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(gone)

        #expect(throws: Launcher.Failure.notFound("no-such-diff-tool")) {
            try Launcher.launch(["no-such-diff-tool", "a", "b"])
        }
        #expect(throws: Launcher.Failure.empty) {
            try Launcher.launch([])
        }
    }
}
