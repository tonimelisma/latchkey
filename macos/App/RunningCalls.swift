import Foundation

/// The calls the Mac is running for the relay. Each gets exactly one answer, or none when the
/// relay cancelled it or the connection ended.
actor RunningCalls {
    typealias Answer = @Sendable (_ id: String, _ result: ToolResult) async -> Void

    private struct Entry {
        var tool: String
        var token: UUID
        var task: Task<Void, Never>
    }

    private var running: [String: Entry] = [:]

    /// The tools of the calls running now.
    var tools: [String] { running.values.map(\.tool) }

    func start(_ call: Call, run: @escaping @Sendable (Call) async -> ToolResult, answer: @escaping Answer) {
        let token = UUID()
        let task = Task {
            let result = await run(call)
            // Cancelled, or already answered by `stop`: the late result is dropped.
            guard self.finish(call.id, token) else { return }
            await answer(call.id, result)
        }
        running[call.id] = Entry(tool: call.tool, token: token, task: task)
    }

    private func finish(_ id: String, _ token: UUID) -> Bool {
        guard running[id]?.token == token else { return false }
        running[id] = nil
        return true
    }

    /// The relay gave up on a call (its deadline passed): stop it, no answer.
    func cancel(_ id: String) { running.removeValue(forKey: id)?.task.cancel() }

    /// The connection ended: nothing can be answered.
    func cancelAll() {
        running.values.forEach { $0.task.cancel() }
        running = [:]
    }

    /// Stops every running call whose tool `reason` gives a reason for, and answers each with
    /// that reason as a tool error (spec 001 FR-066). Calls it gives no reason for keep running.
    func stop(_ reason: @Sendable (_ tool: String) -> String?, answer: Answer) async {
        var stopped: [(id: String, reason: String)] = []
        for (id, entry) in running {
            guard let why = reason(entry.tool) else { continue }
            entry.task.cancel()
            running[id] = nil
            stopped.append((id, why))
        }
        for call in stopped { await answer(call.id, .text(call.reason, isError: true)) }
    }
}

/// What happens to running work when the Owner changes a capability's level (spec 001 FR-066,
/// spec 004 FR-310).
enum LevelChange {
    /// Stops the calls the levels in `registry` no longer allow, then Shell's jobs if Shell is off.
    /// Calls first, so a command Claude is waiting on is answered with the reason, not with the
    /// output of a killed command.
    static func stopWork(
        _ registry: CapabilityRegistry, calls: @Sendable (@escaping @Sendable (String) -> String?) async -> Void,
        shell: ShellJobs
    ) async {
        await calls { registry.stopReason(tool: $0) }
        if registry.level(CapabilityRegistry.shell) == .off { await shell.stopAll() }
    }

    /// The answer recorded for a call that started under `before` and ended under `now`: the
    /// stop reason when its tool was turned off meanwhile, else its own result.
    static func recorded(_ result: ToolResult, tool: String, before: CapabilityRegistry, now: CapabilityRegistry)
        -> ToolResult
    {
        guard before.stopReason(tool: tool) == nil, let reason = now.stopReason(tool: tool) else { return result }
        return .text(reason, isError: true)
    }
}
