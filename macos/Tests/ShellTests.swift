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

    @Test func outputOverTheKeptMegabyteIsRead() async throws {
        // Past 1 MB the oldest output is dropped; reading after that crashed the app (scan 2026-10-24).
        let r = try await jobs.run(
            "head -c 2500000 /dev/zero | tr '\\0' a; sleep 1; echo; echo END", folder: nil, wait: .milliseconds(700))
        // Nothing yet is fine while other suites run (2026-10-29); the read past the dropped
        // megabyte is the one below.
        #expect(r.output.isEmpty || r.output.hasSuffix("a") || r.output.contains("END"))
        let later = try await jobs.check(r.job, wait: .seconds(10))
        #expect(later.finished)
        #expect(later.output.contains("END"))
        let again = try await jobs.check(r.job, wait: .zero)
        #expect(again.output.isEmpty, "nothing new")
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

    /// Reads "PID:<n>" from a job's output.
    static func pid(in output: String) throws -> pid_t {
        let match = try #require(output.firstMatch(of: /PID:(\d+)/), "no PID in the output: \(output)")
        return try #require(pid_t(match.output.1))
    }

    static func alive(_ pid: pid_t) -> Bool { kill(pid, 0) == 0 }

    /// True once the process is gone. A killed process stays visible for a moment, until the
    /// system has cleared it away, so this looks for up to 5 s (1 s wasn't enough while suites
    /// run side by side, 2026-10-29); it returns as soon as the process is gone.
    static func gone(_ pid: pid_t) async -> Bool {
        for _ in 0..<250 where alive(pid) { try? await Task.sleep(for: .milliseconds(20)) }
        return !alive(pid)
    }

    /// Starts `stubborn` and returns once its background process has printed its id, however
    /// busy the Mac (up to 5 s; a fixed 0.6 s wait failed while suites ran side by side).
    static func startStubborn(_ jobs: ShellJobs) async throws -> (job: String, child: pid_t) {
        let r = try await jobs.run(stubborn, folder: nil, wait: .milliseconds(200))
        var out = r.output
        let deadline = ContinuousClock.now + .seconds(5)
        while out.firstMatch(of: /PID:(\d+)/) == nil, ContinuousClock.now < deadline {
            out += try await jobs.check(r.job, wait: .milliseconds(200)).output
        }
        return (r.job, try pid(in: out))
    }

    /// A command that leaves a process in the background that ignores Ctrl-C, hangup and
    /// terminate, and then waits: only stopping the whole terminal session ends it.
    static let stubborn = LeftoversTests.leaver + "; sleep 300"

    @Test func stoppingAJobStopsEverythingItStarted() async throws {
        let (job, child) = try await Self.startStubborn(jobs)
        defer { kill(child, SIGKILL) }
        #expect(Self.alive(child))
        let stopped = try await jobs.stop(job)
        #expect(stopped.finished)
        #expect(await Self.gone(child), "a process the command left in the background survived")
    }

    /// FR-309, FR-310: quitting, or turning Shell off, stops every running command with all it
    /// started.
    @Test func stopAllStopsJobsAndEverythingTheyStarted() async throws {
        let (job, child) = try await Self.startStubborn(jobs)
        let other = try await jobs.run("sleep 300", folder: nil, wait: .milliseconds(100))
        defer { kill(child, SIGKILL) }
        let start = Date()
        await jobs.stopAll()
        #expect(Date().timeIntervalSince(start) < 5)
        #expect(await Self.gone(child))
        let list = await jobs.list()
        #expect(list.first { $0.job == job }?.finished == true)
        #expect(list.first { $0.job == other.job }?.finished == true)
    }

    /// Finding 6: running commands are capped, so Claude can't pile them up without end.
    @Test func runningJobsAreCapped() async throws {
        let few = ShellJobs(maxRunning: 2)
        let a = try await few.run("sleep 300", folder: nil, wait: .milliseconds(100))
        _ = try await few.run("sleep 300", folder: nil, wait: .milliseconds(100))
        do {
            _ = try await few.run("echo third", folder: nil, wait: .seconds(5))
            Issue.record("a third command ran")
        } catch let f as ShellJobs.Failure {
            #expect(f.message.contains("2 commands are already running"), "\(f.message)")
            #expect(f.message.contains("stop"), "says what to do")
        }
        _ = try await few.stop(a.job)
        let again = try await few.run("echo fourth", folder: nil, wait: .seconds(10))
        #expect(again.output.contains("fourth"), "room again after one stopped")
        await few.stopAll()
        #expect(ShellJobs.maxRunning == 32)
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
