import Foundation

/// Commands in the Owner's shell (spec 004): Off or On.
enum ShellCapability {
    static let jobs = ShellJobs()

    static func make() -> Capability {
        Capability(
            id: CapabilityRegistry.shell, title: "Shell", summary: "Run commands in Terminal as you",
            readTools: [], writeTools: tools(jobs: jobs), levels: [.off, .readWrite], onTitle: "On")
    }

    static func operations(jobs: ShellJobs) -> [ToolEntry] {
        [
            ToolEntry(
                tool: .make(
                    "shell_run", title: "Run a Command",
                    description:
                        "Runs a command in the Mac owner's login shell (zsh), as them, never as administrator. Waits up to wait seconds (default and most 30); a longer command keeps running as a job: check it with shell_check, answer its questions with shell_send, stop it with shell_stop.",
                    input: [
                        "command": .stringParam("The command line"),
                        "folder": .stringParam("Run in this folder (default: home)"),
                        "wait": .integerParam("Seconds to wait for it to finish (1 to 30, default 30)"),
                    ], required: ["command"], readOnly: false, destructive: true, openWorld: true, deadlineMS: 45_000),
                handler: { args in
                    await run {
                        guard let command = args["command"]?.stringValue, !command.isEmpty else {
                            throw ShellJobs.Failure(message: "Give a command.")
                        }
                        let s = try await jobs.run(command, folder: args["folder"]?.stringValue, wait: wait(args))
                        var r = result(s)
                        r.activity = "Claude ran: \(command.count > 80 ? String(command.prefix(79)) + "…" : command)"
                        return r
                    }
                }),
            ToolEntry(
                tool: .make(
                    "shell_check", title: "Check a Command",
                    description:
                        "Shows a job's new output since the last check and whether it has finished, waiting up to wait seconds.",
                    input: [
                        "job": .stringParam("The job id from shell_run"),
                        "wait": .integerParam("Seconds to wait for more output or the end (0 to 30, default 10)"),
                    ], required: ["job"], readOnly: true, deadlineMS: 45_000),
                handler: { args in
                    await run {
                        guard let job = args["job"]?.stringValue else {
                            throw ShellJobs.Failure(message: "Give the job id.")
                        }
                        return result(try await jobs.check(job, wait: wait(args, default: 10)))
                    }
                }),
            ToolEntry(
                tool: .make(
                    "shell_send", title: "Type into a Command",
                    description:
                        "Types text into a running job, then Enter unless enter is false, and shows what it printed next.",
                    input: [
                        "job": .stringParam("The job id"), "text": .stringParam("What to type"),
                        "enter": .object([
                            "type": .string("boolean"), "description": .string("Press Enter after (default true)"),
                        ]),
                    ], required: ["job", "text"], readOnly: false, destructive: true, openWorld: true,
                    deadlineMS: 20_000),
                handler: { args in
                    await run {
                        guard let job = args["job"]?.stringValue, let text = args["text"]?.stringValue else {
                            throw ShellJobs.Failure(message: "Give the job id and the text.")
                        }
                        try await jobs.send(job, text: text, enter: args["enter"] != .bool(false))
                        return result(try await jobs.check(job, wait: .seconds(2)))
                    }
                }),
            ToolEntry(
                tool: .make(
                    "shell_stop", title: "Stop a Command",
                    description: "Stops a running job (Ctrl-C first, then forcibly).",
                    input: ["job": .stringParam("The job id")], required: ["job"], readOnly: false, destructive: true,
                    deadlineMS: 20_000),
                handler: { args in
                    await run {
                        guard let job = args["job"]?.stringValue else {
                            throw ShellJobs.Failure(message: "Give the job id.")
                        }
                        return result(try await jobs.stop(job))
                    }
                }),
            ToolEntry(
                tool: .make(
                    "shell_jobs", title: "List Commands",
                    description: "Lists running jobs and those finished in the last 10 minutes.", readOnly: true),
                handler: { _ in
                    let list = await jobs.list()
                    guard !list.isEmpty else { return .text("No jobs.") }
                    return .text(
                        list.map { j in
                            let state = j.finished ? "finished, exit status \(j.exitCode ?? -1)" : "running"
                            return "- \(j.job): \(j.command) (\(state), started \(j.started.formatted(.iso8601)))"
                        }.joined(separator: "\n"))
                }),
        ]
    }

    private static func wait(_ args: JSONValue, default standard: Double = 30) -> Duration {
        .milliseconds(Int(min(max(args["wait"]?.numberValue ?? standard, 0), 30) * 1000))
    }

    private static func result(_ s: ShellJobs.Snapshot) -> ToolResult {
        var text = s.dropped > 0 ? "(\(s.dropped) earlier characters left out)\n" : ""
        text += s.output.isEmpty ? "(no new output)" : s.output
        if s.finished {
            text += "\n[\(s.job) finished, exit status \(s.exitCode ?? -1)]"
        } else {
            text +=
                "\n[\(s.job) is still running. If it's waiting for input, answer with shell_run (job and input); check again with shell_check; stop with shell_run (job and stop).]"
        }
        var structured: [String: JSONValue] = ["job": .string(s.job), "finished": .bool(s.finished)]
        if let code = s.exitCode { structured["exitCode"] = .number(Double(code)) }
        return .data(.object(structured), text: text)
    }

    private static func run(_ body: () async throws -> ToolResult) async -> ToolResult {
        do { return try await body() } catch let f as ShellJobs.Failure {
            return .text(f.message, isError: true)
        } catch {
            return .text("The command couldn't run: \(error.localizedDescription)", isError: true)
        }
    }
}
