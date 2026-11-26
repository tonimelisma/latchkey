import Foundation
import Testing

@testable import Latchkey

/// Shell regression cases (docs/regression-coverage.md, "regressions-shell"), checked
/// through the tools Claude calls, with a Shell of the test's own (its own home and scratch).
@Suite(.serialized) struct RegressionShellATests {
    let jobs = ShellJobs(setup: .testing())

    /// The tools Claude sees (shell_run with job and input or stop, shell_check).
    func tool(_ name: String) throws -> ToolEntry {
        try #require(ShellCapability.tools(jobs: jobs).first { $0.tool.name == name })
    }

    /// Runs `command` through shell_run and checks it until it finishes; the answers' text joined.
    func finished(_ command: String) async throws -> String {
        let run = try tool("shell_run")
        let check = try tool("shell_check")
        var r = await run.handler(.object(["command": .string(command), "wait": .number(30)]))
        var text = r.plainText
        let job = try #require(r.structuredContent?["job"]?.stringValue, "\(text)")
        for _ in 0..<10 where r.structuredContent?["finished"] != .bool(true) {
            r = await check.handler(.object(["job": .string(job), "wait": .number(30)]))
            text += "\n" + r.plainText
        }
        #expect(r.structuredContent?["finished"] == .bool(true), "still running: \(text)")
        return text
    }

    /// regressions.shell_unified_log_readable_or_said (2026-11-03, 2026-11-16): macOS's system
    /// log refused inside the fence ("log: Cannot run while sandboxed"), and Claude was left
    /// guessing. Whenever the output says so, the answer points to Latchkey's own log.
    @Test func aRefusedSystemLogInTheOutputPointsToLatchkeysOwn() async throws {
        let text = try await finished("echo 'log: Cannot run while sandboxed.'")
        #expect(text.contains("Cannot run while sandboxed"), "\(text)")
        #expect(text.contains("latchkey_log"), "the answer names Latchkey's own log: \(text)")
    }

    /// The case's own command: `log show` inside the fence either prints log lines, or the
    /// answer says plainly that it can't run there; silent empty output is the failure.
    @Test func logShowPrintsLinesOrTheAnswerSaysWhyNot() async throws {
        let text = try await finished("/usr/bin/log show --last 1m --style compact | head -3; echo rc=$?")
        #expect(text.contains("rc="), "\(text)")
        let lines = text.split(separator: "\n").map(String.init)
        let logLines = lines.contains { $0.range(of: #"^\d{4}-\d{2}-\d{2} "#, options: .regularExpression) != nil }
        #expect(logLines || text.contains("latchkey_log"), "neither log lines nor why not: \(text)")
    }

    /// regressions.shell_job_found_while_running (lid-closed run, 2026-11-02): checking, typing
    /// into, and stopping running jobs answered "There's no job N" while the same answer listed
    /// them running. With several jobs running, each is found by every call, and stop stops it.
    @Test func aRunningJobIsFoundByCheckInputAndStop() async throws {
        let run = try tool("shell_run")
        let check = try tool("shell_check")
        var ids: [String] = []
        for _ in 0..<3 {
            let r = await run.handler(.object(["command": .string("sleep 120; echo done"), "wait": .number(2)]))
            #expect(!r.isError, "\(r.plainText)")
            #expect(r.structuredContent?["finished"] == .bool(false), "\(r.plainText)")
            ids.append(try #require(r.structuredContent?["job"]?.stringValue, "\(r.plainText)"))
        }
        for id in ids {
            let checked = await check.handler(.object(["job": .string(id), "wait": .number(5)]))
            #expect(checked.plainText.contains("\(id) is still running"), "\(checked.plainText)")
            let typed = await run.handler(.object(["job": .string(id), "input": .string("x")]))
            let stopped = await run.handler(.object(["job": .string(id), "stop": .bool(true)]))
            for answer in [checked, typed, stopped] {
                #expect(!answer.isError, "\(id): \(answer.plainText)")
                #expect(!answer.plainText.contains("There's no job"), "\(id): \(answer.plainText)")
            }
            #expect(stopped.plainText.contains("[\(id) finished"), "the stop says it stopped: \(stopped.plainText)")
        }
        let list = await check.handler(.object([:]))
        #expect(!list.plainText.contains("(running"), "nothing left running: \(list.plainText)")
        await jobs.stopAll()
    }
}
