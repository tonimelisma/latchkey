import Foundation

/// The Shell tools Claude sees: run and check (consolidated 2026-10-23).
extension ShellCapability {
    static func tools(jobs: ShellJobs) -> [ToolEntry] {
        let ops = Operations(operations(jobs: jobs))
        return [
            ToolEntry(
                tool: .make(
                    "shell_run", title: "Run a Command",
                    description: """
                        Runs a command in the Mac owner's login shell (zsh), as them, never as administrator. \
                        Waits up to wait seconds (default and most 30); a longer command keeps running as a job \
                        (check it with shell_check). With job and input: types input into that job (then Enter \
                        unless enter is false). With job and stop: stops it (Ctrl-C, then forcibly). \
                        \(writesRule)
                        """,
                    input: runInput.merging([
                        "job": .stringParam("A running job's id, to type into or stop"),
                        "input": .stringParam("With job: what to type"),
                        "enter": .boolParam("With input: press Enter after (default true)"),
                        "stop": .boolParam("With job: stop it"),
                    ]) { a, _ in a }, readOnly: false, destructive: true, openWorld: true, deadlineMS: 45_000),
                handler: { args in
                    if args.hasAny("job") {
                        if args["stop"] == .bool(true) { return await ops.call("shell_stop", args) }
                        if args["input"]?.stringValue != nil {
                            return await ops.call("shell_send", args.with(["text": args["input"]]))
                        }
                        return .text("With job, give input to type or stop: true.", isError: true)
                    }
                    return await ops.call("shell_run", args)
                }),
            ToolEntry(
                tool: .make(
                    "shell_check", title: "Check Commands",
                    description:
                        "With job: shows that job's new output since the last check and whether it has finished, waiting up to wait seconds; for a job whose leftovers are kept, checking keeps them longer. Without: lists running jobs, those whose leftovers are kept, and those finished in the last 10 minutes.",
                    input: [
                        "job": .stringParam("The job id from shell_run"),
                        "wait": .integerParam("Seconds to wait for more output or the end (0 to 30, default 10)"),
                    ], readOnly: true, deadlineMS: 45_000),
                handler: { args in
                    args.hasAny("job") ? await ops.call("shell_check", args) : await ops.call("shell_jobs", args)
                }),
        ]
    }
}
