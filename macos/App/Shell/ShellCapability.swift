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
                        "Runs a command in the Mac owner's login shell (zsh), as them, never as administrator. Waits up to wait seconds (default and most 30); a longer command keeps running as a job: check it with shell_check, answer its questions with shell_send, stop it with shell_stop. \(writesRule)",
                    input: runInput, required: ["command"], readOnly: false, destructive: true, openWorld: true,
                    deadlineMS: 45_000),
                handler: { args in
                    await run {
                        guard let command = args["command"]?.stringValue, !command.isEmpty else {
                            throw ShellJobs.Failure(message: "Give a command.")
                        }
                        let s = try await jobs.run(
                            command, folder: args["folder"]?.stringValue, wait: try wait(args),
                            writes: try writes(args),
                            why: args["why"]?.stringValue,
                            keepMinutes: Int(try args.number("keep_minutes", in: 0...1440) ?? 0),
                            uses: try uses(args))
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
                        return result(try await jobs.check(job, wait: try wait(args, default: 10)))
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
                            var state = j.finished ? "finished, exit status \(j.exitCode ?? -1)" : "running"
                            if let until = j.keptUntil {
                                state += "; leftovers kept until \(until.formatted(Leftovers.clock))"
                            }
                            return "- \(j.job): \(j.command) (\(state), started \(j.started.formatted(.iso8601)))"
                        }.joined(separator: "\n"))
                }),
        ]
    }

    /// What shell_run tells Claude about the fence, the scratch folder, and leases (spec 004
    /// FR-314 to FR-318).
    static let writesRule =
        "A command writes only to its own scratch folder ($LATCHKEY_SCRATCH, also $TMPDIR; moved to the Trash when it finishes), the folder it runs in (unless that is the home folder), Downloads, and package caches; anything else fails unless declared in writes (with why), and so does changing settings (defaults write: declare ~/Library/Preferences/<domain>.plist). Opening apps, files, or links through macOS (open) fails unless declared in uses; scripting other apps (osascript) and starting background services (launchctl, brew services) aren't possible. Whatever it leaves running is stopped when it finishes, unless keep_minutes asks to keep it (checking the job keeps it longer; 24 hours at most)."

    static let runInput: [String: JSONValue] = [
        "command": .stringParam("The command line"),
        "folder": .stringParam("Run in this folder (default: home)"),
        "wait": .integerParam("Seconds to wait for it to finish (1 to 30, default 30)"),
        "writes": .object([
            "type": .string("array"), "items": .object(["type": .string("string")]),
            "description": .string(
                "Folders or files outside the allowed places the command will write (full paths or ~/…); results meant to stay"
            ),
        ]),
        "why": .stringParam("With writes: what the command writes there, for the owner's list"),
        "uses": .object([
            "type": .string("array"),
            "items": .object([
                "type": .string("string"), "enum": .array(Fence.Use.allCases.map { .string($0.rawValue) }),
            ]),
            "description": .string(
                "What the command does beyond the fence, only when the owner's task needs it: open (apps, files, links through macOS). What it starts runs outside the fence and keeps running."
            ),
        ]),
        "keep_minutes": .integerParam(
            "Keep what the command leaves running (a server, a watcher) and its scratch folder this many minutes after it finishes (0 to 1440, default 0)"
        ),
    ]

    private static func writes(_ args: JSONValue) throws -> [String] {
        guard let value = args["writes"] else { return [] }
        if case .array(let items) = value {
            return try items.map {
                guard let s = $0.stringValue else { throw ShellJobs.Failure(message: "writes is a list of paths.") }
                return s
            }
        }
        if let s = value.stringValue { return [s] }
        throw ShellJobs.Failure(message: "writes is a list of paths.")
    }

    private static func uses(_ args: JSONValue) throws -> Set<Fence.Use> {
        guard let value = args["uses"] else { return [] }
        let names: [String]
        if case .array(let items) = value {
            names = try items.map {
                guard let s = $0.stringValue else { throw ShellJobs.Failure(message: "uses is a list of names.") }
                return s
            }
        } else if let s = value.stringValue {
            names = [s]
        } else {
            throw ShellJobs.Failure(message: "uses is a list of names.")
        }
        return Set(
            try names.map { name in
                guard let use = Fence.Use(rawValue: name) else {
                    throw ShellJobs.Failure(
                        message:
                            "uses takes \(Fence.Use.allCases.map(\.rawValue).joined(separator: " and ")), not \(name).")
                }
                return use
            })
    }

    private static func wait(_ args: JSONValue, default standard: Double = 30) throws -> Duration {
        .milliseconds(Int(min(try args.number("wait", in: 0...Double.greatestFiniteMagnitude) ?? standard, 30) * 1000))
    }

    private static func result(_ s: ShellJobs.Snapshot) -> ToolResult {
        var text = s.dropped > 0 ? "(\(s.dropped) earlier characters left out)\n" : ""
        text += s.output.isEmpty ? "(no new output)" : s.output
        if s.refusedWrite {
            text += "\n" + Fence.hint
            // "Operation not permitted" is also macOS's privacy protection refusing a read (FR-625).
            if !Permissions.hasFullDiskAccess { text += "\n" + Fence.privacyHint }
        }
        if s.refusedHandoff { text += "\n" + Fence.handoffHint }
        if s.refusedSettings { text += "\n" + Fence.settingsHint }
        if let warning = s.fenceWarning { text += "\n" + warning }
        if s.finished {
            text += "\n[\(s.job) finished, exit status \(s.exitCode ?? -1)]"
            if let left = s.left { text += "\n" + left }
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
        } catch let a as ArgumentError {
            return .text(a.message, isError: true)
        } catch {
            return .text("The command couldn't run: \(error.localizedDescription)", isError: true)
        }
    }
}
