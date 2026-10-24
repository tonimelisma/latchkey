import Foundation
import Testing

@testable import Latchkey

@Suite struct TerminalTextTests {
    @Test func removesControlCodes() {
        #expect(TerminalText.clean("\u{1B}[1;32mgreen\u{1B}[0m plain\r\n") == "green plain\n")
        #expect(TerminalText.clean("\u{1B}]0;title\u{07}text") == "text")
        #expect(TerminalText.clean("10%\r50%\r100%\ndone") == "100%\ndone", "progress redraws keep the last")
    }

    @Test func keepsTheEndOfLongOutput() {
        let (text, dropped) = TerminalText.tail(String(repeating: "x", count: 60_000) + "END", limit: 50_000)
        #expect(text.hasSuffix("END"))
        #expect(text.count == 50_000)
        #expect(dropped == 10_003)
    }
}

@Suite(.serialized) struct ShellJobTests {
    let jobs = ShellJobs()

    @Test func runsACommand() async throws {
        let r = try await jobs.run("echo hello; echo oops >&2", folder: nil, wait: .seconds(10))
        #expect(r.finished)
        #expect(r.exitCode == 0)
        #expect(r.output.contains("hello"))
        #expect(r.output.contains("oops"), "errors are shown too")
    }

    @Test func aCommandStartingWithADashIsTheCommand() async throws {
        // Without "--", zsh would read "-v; echo hi" as its own options and run nothing.
        let r = try await jobs.run("-v; echo hi", folder: nil, wait: .seconds(10))
        #expect(r.output.contains("hi"), "\(r.output)")
    }

    @Test func reportsFailure() async throws {
        let r = try await jobs.run("exit 3", folder: nil, wait: .seconds(10))
        #expect(r.exitCode == 3)
    }

    @Test func usesTheFolderAndLoginPath() async throws {
        let dir = FileManager.default.temporaryDirectory.appending(path: "shell-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let r = try await jobs.run("pwd; echo $PATH; echo $TERM", folder: dir.path, wait: .seconds(10))
        #expect(r.output.contains(dir.lastPathComponent))
        #expect(r.output.contains("/usr/bin"))
        #expect(r.output.contains("dumb"))
    }

    @Test func longCommandsBecomeJobs() async throws {
        let r = try await jobs.run("sleep 1.5; echo done", folder: nil, wait: .milliseconds(300))
        #expect(!r.finished)
        let later = try await jobs.check(r.job, wait: .seconds(10))
        #expect(later.finished)
        #expect(later.output.contains("done"))
        #expect(later.exitCode == 0)
    }

    @Test func answersPrompts() async throws {
        let r = try await jobs.run(
            "printf 'Name? '; read -r name; echo \"got $name\"", folder: nil, wait: .milliseconds(800))
        #expect(!r.finished)
        #expect(r.output.contains("Name?"))
        try await jobs.send(r.job, text: "Toni", enter: true)
        let after = try await jobs.check(r.job, wait: .seconds(10))
        #expect(after.output.contains("got Toni"))
        #expect(after.finished)
    }

    @Test func stopsAStuckCommand() async throws {
        let r = try await jobs.run("sleep 100", folder: nil, wait: .milliseconds(300))
        let start = Date()
        let stopped = try await jobs.stop(r.job)
        #expect(stopped.finished)
        #expect(Date().timeIntervalSince(start) < 8)
        #expect(await jobs.list().first { $0.job == r.job }?.finished == true)
    }

    @Test func unknownJobIsAnError() async {
        await #expect(throws: ShellJobs.Failure.self) { try await jobs.check("nope", wait: .zero) }
    }
}

@Suite struct ShellToolTests {
    @Test func toolsAndHints() {
        let t = Dictionary(
            uniqueKeysWithValues: ShellCapability.operations(jobs: ShellJobs()).map { ($0.tool.name, $0.tool) })
        #expect(Set(t.keys) == ["shell_run", "shell_check", "shell_send", "shell_stop", "shell_jobs"])
        #expect(t["shell_run"]?.annotations?.destructiveHint == true)
        #expect(t["shell_run"]?.annotations?.openWorldHint == true)
        #expect(t["shell_check"]?.annotations?.readOnlyHint == true)
        #expect(t["shell_jobs"]?.annotations?.readOnlyHint == true)
    }

    @Test func runToolReportsAndNotifies() async {
        let run = ShellCapability.operations(jobs: ShellJobs()).first { $0.tool.name == "shell_run" }!
        let r = await run.handler(.object(["command": .string("echo hi")]))
        #expect(!r.isError)
        #expect(r.content.jsonText.contains("hi"))
        #expect(r.content.jsonText.contains("exit status 0"))
        #expect(r.activity == "Claude ran: echo hi")
    }

    @Test func shellIsOnOrOff() {
        let cap = ShellCapability.make()
        #expect(cap.levels == [.off, .readWrite])
        #expect(cap.title(for: .readWrite) == "On")
        #expect(cap.entries(at: .readOnly).isEmpty)
    }
}
