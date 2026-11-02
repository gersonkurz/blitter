@testable import BlitterCore
import Foundation
import Testing

/// Tools' command lines as jobs (#30): real processes in a temporary folder.
@MainActor
@Suite(.serialized)
struct CommandTests {
    @Test func aCommandRunsInTheFolderWithItsArgumentsAsGiven() async throws {
        let fixture = try OperationFixture()
        // No shell between: "a b.txt" arrives as one argument, the ";" as a plain character.
        let job = try await fixture.run(.command(["touch", "a b.txt", "x;y"], folder: fixture.source))
        #expect(job.errors.isEmpty && job.state == .finished)
        #expect(fixture.names("source") == ["a b.txt", "x;y"])
    }

    @Test func aFailureReportsTheExitCodeAndWhatItSaid() async throws {
        let fixture = try OperationFixture()
        let job = try await fixture.run(.command(["sh", "-c", "echo broken >&2; exit 3"], folder: fixture.source))
        let message = try #require(job.errors.first?.message)
        #expect(job.errors.count == 1 && job.errors.first?.path == fixture.source)
        #expect(message.contains("exit code 3") && message.contains("broken"))
    }

    /// #43: a command's output, stdout and stderr together in the order they came, is the job's,
    /// for a dialog to show; bounded to its last 64 KB. git never waits for a password.
    @Test func theOutputIsTheJobsAndGitIsToldNotToPrompt() async throws {
        let fixture = try OperationFixture()
        let script = "echo first; echo second >&2; echo prompt=$GIT_TERMINAL_PROMPT"
        let job = try await fixture.run(.command(["sh", "-c", script], folder: fixture.source))
        #expect(job.errors.isEmpty)
        #expect(job.progress.output == "first\nsecond\nprompt=0\n")

        let long = try await fixture.run(.command(["sh", "-c", "head -c 200000 /dev/zero | tr '\\0' 'x'; echo END"],
                                                  folder: fixture.source))
        #expect(long.progress.outputBytes.count == JobProgress.outputLimit)
        #expect(long.progress.output.hasSuffix("xxxEND\n")) // the end is kept
    }

    @Test func aMissingProgramIsReported() async throws {
        let fixture = try OperationFixture()
        let job = try await fixture.run(.command(["no-such-program-7f3c"], folder: fixture.source))
        #expect(job.errors.first?.message.contains("was not found") == true)
    }

    @Test func aCancelledCommandIsStopped() async throws {
        let fixture = try OperationFixture()
        let id = fixture.queue.start(.command(["sleep", "30"], folder: fixture.source))
        try await Task.sleep(for: .milliseconds(200))
        let start = Date()
        fixture.queue.cancel(id)
        for _ in 0 ..< 300 where fixture.queue.jobs.first(where: { $0.id == id })?.isDone != true {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(fixture.queue.jobs.first { $0.id == id }?.state == .cancelled)
        // TERM ends it at once: the child gets default signal handling, whatever the test runner
        // (or Blitter) inherited, so the 2 s grace is not waited out.
        #expect(Date().timeIntervalSince(start) < 1.5)
    }

    /// #30 review: a program that leaves something running which keeps stderr open is done when
    /// it exits; the job does not wait for the pipe.
    @Test func aProgramIsDoneWhenItExitsWhateverItLeftRunning() async throws {
        let fixture = try OperationFixture()
        let start = Date()
        let job = try await fixture.run(.command(["sh", "-c", "sleep 5 & exit 0"], folder: fixture.source))
        #expect(job.errors.isEmpty && job.state == .finished)
        #expect(Date().timeIntervalSince(start) < 3)
    }

    /// #30 review: Cancel stops what the program started too, even if it ignores TERM: after the
    /// 2 s grace, the whole group is killed.
    @Test func cancelStopsTheWholeGroup() async throws {
        let fixture = try OperationFixture()
        let script = "trap '' TERM; (sleep 4; touch survived) & wait"
        let id = fixture.queue.start(.command(["sh", "-c", script], folder: fixture.source))
        try await Task.sleep(for: .milliseconds(300))
        fixture.queue.cancel(id)
        for _ in 0 ..< 500 where fixture.queue.jobs.first(where: { $0.id == id })?.isDone != true {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(fixture.queue.jobs.first { $0.id == id }?.state == .cancelled)
        try await Task.sleep(for: .milliseconds(2500)) // the subshell would have touched it by now
        #expect(!fixture.exists("source/survived"))
    }

    /// #30 review: only the end of stderr is kept, however much a command writes.
    @Test func onlyTheEndOfALongErrorOutputIsKept() async throws {
        let fixture = try OperationFixture()
        let script = "head -c 2000000 /dev/zero | tr '\\0' x >&2; echo THE-END >&2; exit 1"
        let job = try await fixture.run(.command(["sh", "-c", script], folder: fixture.source))
        let message = try #require(job.errors.first?.message)
        #expect(message.hasSuffix("THE-END") && message.count < 400)
        #expect(FileOperations.errorTailLimit == 4096)
    }

    /// #30 review: the kept end can start inside a character; the message must survive that.
    @Test func aCutInsideACharacterKeepsTheMessage() async throws {
        let euros = Data(String(repeating: "€", count: 2000).utf8) // 3 bytes each
        let tail = Data((euros + Data("THE-END\n".utf8)).suffix(FileOperations.errorTailLimit))
        #expect(tail.first.map { $0 & 0xC0 == 0x80 } == true) // starts inside a "€"
        let text = FileOperations.text(of: tail)
        #expect(text.hasSuffix("THE-END\n") && text.hasPrefix("€") && !text.contains("\u{FFFD}"))
        #expect(FileOperations.text(of: Data([0x41, 0xFF, 0x42])) == "A\u{FFFD}B") // not UTF-8: replaced

        // The same through a real command.
        let fixture = try OperationFixture()
        let script = "i=0; while [ $i -lt 2000 ]; do printf '€' >&2; i=$((i+1)); done; echo THE-END >&2; exit 2"
        let job = try await fixture.run(.command(["sh", "-c", script], folder: fixture.source))
        let message = try #require(job.errors.first?.message)
        #expect(message.contains("exit code 2") && message.hasSuffix("THE-END"))
    }

    /// #30 review: "./tool" means the side's folder, not Blitter's working directory.
    @Test func aRelativeProgramPathIsTheSidesFolder() async throws {
        let fixture = try OperationFixture()
        let tool = fixture.source + "/tool.sh"
        try "#!/bin/sh\ntouch made-by-the-tool\n".write(toFile: tool, atomically: true, encoding: .utf8)
        chmod(tool, 0o755)
        #expect(FileManager.default.currentDirectoryPath != fixture.source)
        let job = try await fixture.run(.command(["./tool.sh"], folder: fixture.source))
        #expect(job.errors.isEmpty)
        #expect(fixture.exists("source/made-by-the-tool"))
        #expect(FileOperations.executable("./tool.sh", in: fixture.source) == (tool as NSString).standardizingPath)
        #expect(FileOperations.executable("./tool.sh", in: fixture.destination) == nil)
    }

    @Test func programsAreFoundOnASearchPathWithHomebrew() {
        #expect(FileOperations.executable("sh", searching: ["/nowhere", "/bin"]) == "/bin/sh")
        #expect(FileOperations.executable("/bin/sh") == "/bin/sh")
        #expect(FileOperations.executable("/bin/no-such-7f3c") == nil)
        #expect(FileOperations.executable("no-such-7f3c") == nil)
        let path = FileOperations.searchPath(home: "/Users/someone")
        #expect(path.first == "/opt/homebrew/bin" && path.contains("/usr/local/bin") && path.contains("/usr/bin"))
    }
}
