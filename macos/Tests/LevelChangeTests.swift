import Foundation
import Testing

@testable import Latchkey

/// Turning a capability off or down stops its running work at once (spec 001 FR-066, spec 004
/// FR-310; Toni, 2026-10-25).
@Suite(.serialized) struct LevelChangeTests {
    /// The answers the relay would get, by call id.
    typealias Answers = Locked<[String: ToolResult]>

    /// A tool that runs until released (or cancelled) and says which.
    static func slow(_ name: String, readOnly: Bool, _ release: AsyncStream<Void>) -> ToolEntry {
        ToolEntry(
            tool: .make(name, title: name, description: "", readOnly: readOnly),
            handler: { _ in
                for await _ in release { return .text("\(name) finished") }
                return .text("\(name) was cancelled", isError: true)
            })
    }

    static func call(_ id: String, _ tool: String, _ args: [String: JSONValue] = [:]) -> Call {
        Call(id: id, tool: tool, arguments: .object(args), deadlineMS: 45_000)
    }

    static func until(_ limit: Duration = .seconds(5), _ done: () async -> Bool) async -> Bool {
        let deadline = ContinuousClock.now + limit
        while ContinuousClock.now < deadline {
            if await done() { return true }
            try? await Task.sleep(for: .milliseconds(20))
        }
        return await done()
    }

    /// Applies a level change the way the app does.
    static func apply(_ registry: CapabilityRegistry, _ calls: RunningCalls, _ answers: Answers, shell: ShellJobs)
        async
    {
        await LevelChange.stopWork(
            registry,
            calls: { reason in await calls.stop(reason) { id, r in answers.mutate { $0[id] = r } } },
            shell: shell)
    }

    @Test func aWriteIsStoppedAndAReadKeepsRunningWhenFilesGoesReadOnly() async {
        let (readGate, releaseRead) = AsyncStream.makeStream(of: Void.self)
        let (writeGate, _) = AsyncStream.makeStream(of: Void.self)
        let files = Capability(
            id: CapabilityRegistry.files, title: "Files", summary: "",
            readTools: [Self.slow("files_read", readOnly: true, readGate)],
            writeTools: [Self.slow("files_change", readOnly: false, writeGate)])
        var registry = CapabilityRegistry(capabilities: [files], levels: [CapabilityRegistry.files: .readWrite])
        let before = registry
        let calls = RunningCalls()
        let answers = Answers([:])
        for c in [Self.call("r1", "files_read"), Self.call("w1", "files_change")] {
            await calls.start(
                c, run: { await before.call(tool: $0.tool, arguments: $0.arguments) },
                answer: { id, r in answers.mutate { $0[id] = r } })
        }

        registry.setLevel(CapabilityRegistry.files, .readOnly)
        let start = ContinuousClock.now
        await Self.apply(registry, calls, answers, shell: ShellJobs())

        #expect(ContinuousClock.now - start < .seconds(1), "at once")
        let write = answers.value["w1"]
        #expect(write?.isError == true)
        #expect(
            write?.content.jsonText.contains("The Mac's owner set Files to Read Only in the Latchkey app") == true,
            "\(write?.content.jsonText ?? "no answer")")
        #expect(answers.value["r1"] == nil, "the read is still running")
        #expect(await calls.tools == ["files_read"])
        releaseRead.yield()
        #expect(await Self.until { answers.value["r1"] != nil })
        #expect(answers.value["r1"]?.content.jsonText.contains("files_read finished") == true)
        #expect(answers.value["r1"]?.isError == false)
        // The stopped write's own late result never replaces the answer Claude got.
        try? await Task.sleep(for: .milliseconds(100))
        #expect(answers.value["w1"] == write)
        #expect(await calls.tools.isEmpty)
    }

    @Test func nothingIsStoppedWhenALevelIsRaised() async {
        let (readGate, releaseRead) = AsyncStream.makeStream(of: Void.self)
        let (writeGate, _) = AsyncStream.makeStream(of: Void.self)
        let files = Capability(
            id: CapabilityRegistry.files, title: "Files", summary: "",
            readTools: [Self.slow("files_read", readOnly: true, readGate)],
            writeTools: [Self.slow("files_change", readOnly: false, writeGate)])
        var registry = CapabilityRegistry(
            capabilities: [files],
            levels: [CapabilityRegistry.files: .readOnly, CapabilityRegistry.shell: .readWrite])
        let before = registry
        let calls = RunningCalls()
        let answers = Answers([:])
        await calls.start(
            Self.call("r1", "files_read"), run: { await before.call(tool: $0.tool, arguments: $0.arguments) },
            answer: { id, r in answers.mutate { $0[id] = r } })
        let jobs = ShellJobs()
        let job = try? await jobs.run("sleep 300", folder: nil, wait: .milliseconds(100))

        registry.setLevel(CapabilityRegistry.files, .readWrite)
        await Self.apply(registry, calls, answers, shell: jobs)

        #expect(answers.value.isEmpty, "nothing answered for the Owner")
        #expect(await calls.tools == ["files_read"])
        #expect(await jobs.list().first?.finished == false, "Shell is on: its jobs run on")
        releaseRead.yield()
        #expect(await Self.until { answers.value["r1"]?.isError == false })
        if let job { _ = try? await jobs.stop(job.job) }
    }

    @Test func shellGoingOffStopsItsJobsAndTheCallWaitingOnOne() async throws {
        let jobs = ShellJobs()
        let shell = Capability(
            id: CapabilityRegistry.shell, title: "Shell", summary: "", readTools: [],
            writeTools: ShellCapability.tools(jobs: jobs), levels: [.off, .readWrite], onTitle: "On")
        var registry = CapabilityRegistry(capabilities: [shell], levels: [CapabilityRegistry.shell: .readWrite])
        let before = registry
        // A job left running in the background, with a process of its own that ignores Ctrl-C.
        let background = try await jobs.run(ShellJobTests.stubborn, folder: nil, wait: .milliseconds(600))
        let child = try ShellJobTests.pid(in: background.output)
        defer { kill(child, SIGKILL) }
        // And a command Claude is waiting on right now.
        let calls = RunningCalls()
        let answers = Answers([:])
        await calls.start(
            Self.call("s1", "shell_run", ["command": .string("sleep 300"), "wait": .number(30)]),
            run: { await before.call(tool: $0.tool, arguments: $0.arguments) },
            answer: { id, r in answers.mutate { $0[id] = r } })
        #expect(await Self.until { await jobs.list().count == 2 })

        registry.setLevel(CapabilityRegistry.shell, .off)
        let start = ContinuousClock.now
        await Self.apply(registry, calls, answers, shell: jobs)

        #expect(ContinuousClock.now - start < .seconds(5))
        let answer = answers.value["s1"]
        #expect(answer?.isError == true)
        #expect(
            answer?.content.jsonText.contains("The Mac's owner turned Shell off in the Latchkey app") == true,
            "\(answer?.content.jsonText ?? "no answer")")
        let list = await jobs.list()
        #expect(list.count == 2)
        #expect(list.allSatisfy { $0.finished }, "every job stopped")
        #expect(await ShellJobTests.gone(child), "with everything it started")
        #expect(await calls.tools.isEmpty)
    }

    @MainActor @Test func theReasonNamesTheCapabilityAndItsNewLevel() {
        let registry = CapabilityRegistry(
            capabilities: AppModel.makeCapabilities(),
            levels: [
                CapabilityRegistry.files: .readOnly, CapabilityRegistry.shell: .off,
                CapabilityRegistry.notes: .readWrite,
            ])
        #expect(registry.stopReason(tool: "files_read") == nil, "still allowed")
        #expect(registry.stopReason(tool: "notes_change") == nil)
        #expect(
            registry.stopReason(tool: "files_change")
                == "The Mac's owner set Files to Read Only in the Latchkey app while this was running, so it was stopped. It may not have finished."
        )
        #expect(
            registry.stopReason(tool: "shell_check")
                == "The Mac's owner turned Shell off in the Latchkey app while this was running, so it was stopped. It may not have finished."
        )
        #expect(registry.stopReason(tool: "no_such_tool") == nil)
    }

    /// The activity log records what Claude was told.
    @Test func theLogRecordsTheStopForACallThatWasRunning() {
        let cap = CapabilityTests.registry(.readWrite)
        var lowered = cap
        lowered.setLevel("demo", .readOnly)
        let done = ToolResult.text("wrote")
        #expect(LevelChange.recorded(done, tool: "demo_write", before: cap, now: cap) == done)
        let stopped = LevelChange.recorded(done, tool: "demo_write", before: cap, now: lowered)
        #expect(stopped.isError)
        #expect(stopped.content.jsonText.contains("set Demo to Read Only"))
        #expect(LevelChange.recorded(.text("read"), tool: "demo_read", before: cap, now: lowered) == .text("read"))
        // A call for a tool that was already off keeps its own "turned off" error.
        let off = ToolResult.text("The tool demo_write is turned off.", isError: true)
        #expect(LevelChange.recorded(off, tool: "demo_write", before: lowered, now: lowered) == off)
    }

    /// Stopping a call ends the program it was waiting on (AppleScript, Spotlight), instead of
    /// letting it run to its own deadline.
    @Test func cancellingACallEndsItsProgram() async throws {
        let start = ContinuousClock.now
        let task = Task { try await ProcessCommands.launch("/bin/sleep", ["8"], timeout: .seconds(20)) }
        try await Task.sleep(for: .milliseconds(300))
        task.cancel()
        _ = try await task.value
        #expect(ContinuousClock.now - start < .seconds(3))
    }

    /// A cancelled wait on a job returns at once instead of spinning until the wait is over.
    @Test func aCancelledWaitOnAJobReturnsAtOnce() async throws {
        let jobs = ShellJobs()
        let start = ContinuousClock.now
        let task = Task { try await jobs.run("sleep 300", folder: nil, wait: .seconds(30)) }
        try await Task.sleep(for: .milliseconds(400))
        task.cancel()
        let snapshot = try await task.value
        #expect(ContinuousClock.now - start < .seconds(3))
        _ = try await jobs.stop(snapshot.job)
    }
}
