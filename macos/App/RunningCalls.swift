import CryptoKit
import Foundation

// MARK: calls cut off by the app stopping (spec 001 FR-666 to FR-668)

/// A call the Mac is running, with what its activity entry needs if the app stops before the
/// call ends. Relay-supplied names are already bounded (`AuditComparison.clip`).
struct CallMark: Codable, Equatable, Sendable {
    var callID: String
    var at: Date
    var tool: String
    var arguments: String
    var device: String?
    var client: String?

    /// The activity entry of a call that got no answer because the app stopped.
    func entry(_ text: String, durationMS: Int) -> Activity {
        Activity(
            at: at, tool: tool, arguments: arguments, result: ToolResult.text(text, isError: true).content.jsonText,
            isError: true, durationMS: durationMS, callID: callID, device: device, client: client)
    }
}

/// The marks of the calls running now, on disk: one file per call, sealed with the activity
/// log's key and bound to its call id, written before the call runs and removed once its entry
/// is written (FR-667). Whatever is left at a start was running when the app stopped without
/// quitting (a crash, or `kill -9`). Research: research.md "Calls cut off by the app stopping".
struct CallMarks: Sendable {
    let directory: URL
    let key: SymmetricKey

    static let folderName = "Running calls"

    /// The call id is checked before a call runs (`CallCheck`): letters, digits, and `_` only.
    private func file(_ callID: String) -> URL { directory.appending(path: callID + ".call") }

    func write(_ mark: CallMark) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let sealed = try AES.GCM.seal(
            try JSONEncoder().encode(mark), using: key, authenticating: Data(mark.callID.utf8))
        try sealed.combined!.write(to: file(mark.callID), options: [.atomic])
    }

    func remove(_ callID: String) { try? FileManager.default.removeItem(at: file(callID)) }

    /// The marks left, oldest first; one that can't be opened (another key, damaged) is counted
    /// and removed, never taken for a call.
    func leftovers() -> (marks: [CallMark], unreadable: Int) {
        let files =
            (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        var marks: [CallMark] = []
        var unreadable = 0
        for url in files where url.pathExtension == "call" {
            let id = url.deletingPathExtension().lastPathComponent
            if let data = try? Data(contentsOf: url), let box = try? AES.GCM.SealedBox(combined: data),
                let plain = try? AES.GCM.open(box, using: key, authenticating: Data(id.utf8)),
                let mark = try? JSONDecoder().decode(CallMark.self, from: plain), mark.callID == id
            {
                marks.append(mark)
            } else {
                unreadable += 1
                try? FileManager.default.removeItem(at: url)
            }
        }
        return (marks.sorted { $0.at < $1.at }, unreadable)
    }
}

/// The calls running now, so that each still gets its activity entry when the app quits
/// (FR-666) or stops without quitting (FR-667).
@MainActor
final class CallsInFlight {
    static let cutOffByQuit =
        "Latchkey quit while this was running, so it was stopped and Claude got no answer from the Mac. It may not have finished."
    static let endedByStop =
        "Latchkey stopped while this was running (it crashed or was forced to quit), so Claude got no answer from the Mac. It may not have finished."

    let marks: CallMarks?
    private var running: [String: CallMark] = [:]
    private var cutOff: Set<String> = []

    init(marks: CallMarks?) { self.marks = marks }

    /// Before the call runs: kept in memory, and its mark written.
    func begin(_ mark: CallMark) {
        running[mark.callID] = mark
        do {
            try marks?.write(mark)
        } catch {
            Diagnostics.activity.error(
                "Couldn't write the mark of a running call: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// The call ended. False when the quit already recorded it as cut off: then its result is
    /// not recorded again.
    func end(_ callID: String) -> Bool {
        running[callID] = nil
        return cutOff.remove(callID) == nil
    }

    /// The call's entry was written (or couldn't be): its mark goes, so a later start doesn't
    /// take it for a call the app stopped during.
    func recorded(_ callID: String) { marks?.remove(callID) }

    /// The "Quitting" event of this app. Never just "Quitting": that is what apps from before
    /// FR-666 recorded, and only their quits explain a call missing from the log (FR-668).
    var quitLine: String {
        switch running.count {
        case 0: "Quitting with no calls running"
        case 1: "Quitting with 1 call running; it is recorded as cut off by the quit"
        case let n: "Quitting with \(n) calls running; each is recorded as cut off by the quit"
        }
    }

    /// The app is quitting and can answer nothing more: records every call still running as cut
    /// off by the quit, removes their marks once recorded, and returns how many.
    @discardableResult
    func recordQuit(now: Date = Date(), record: ([Activity]) throws -> Void) -> Int {
        let calls = running.values.sorted { $0.at < $1.at }
        guard !calls.isEmpty else { return 0 }
        running = [:]
        cutOff.formUnion(calls.map(\.callID))
        do {
            try record(
                calls.map {
                    $0.entry(Self.cutOffByQuit, durationMS: max(0, Int(now.timeIntervalSince($0.at) * 1000)))
                })
        } catch {
            // The marks stay, so the next start records them.
            Diagnostics.activity.error(
                "Couldn't record the calls cut off by the quit: \(error.localizedDescription, privacy: .public)")
            return 0
        }
        for call in calls { marks?.remove(call.callID) }
        return calls.count
    }

    /// At start: records the calls the app was running when it last stopped without quitting,
    /// except any the log already has (its entry written just before the app stopped), and
    /// removes their marks once recorded. `logged` gives which of these ids the log has.
    static func recover(
        marks: CallMarks, logged: (Set<String>) throws -> Set<String>, record: ([Activity]) throws -> Void
    ) -> Int {
        let found = marks.leftovers()
        if found.unreadable > 0 {
            EventLog.shared.record(
                .activity, "\(found.unreadable) marks of running calls couldn't be read and were removed", error: true)
        }
        guard !found.marks.isEmpty, let have = try? logged(Set(found.marks.map(\.callID))) else { return 0 }
        let missing = found.marks.filter { !have.contains($0.callID) }
        do {
            try record(missing.map { $0.entry(endedByStop, durationMS: 0) })
        } catch {
            Diagnostics.activity.error(
                "Couldn't record the calls left running: \(error.localizedDescription, privacy: .public)")
            return 0
        }
        for mark in found.marks { marks.remove(mark.callID) }
        return missing.count
    }
}

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

/// Pause Claude's Access (spec 001 FR-602 to FR-604): every call is answered at once, and
/// whatever runs stops. Stored in user defaults, so it lasts until the Owner resumes.
enum Pause {
    static let key = "paused"

    static let refused = ToolResult.text(
        "The Mac's owner paused Latchkey on this Mac, so Claude can't use it right now. Nothing was done. They can resume it with Resume Claude's Access in the Latchkey menu.",
        isError: true)

    static let stopped =
        "The Mac's owner paused Latchkey on this Mac while this was running, so it was stopped. It may not have finished."

    static func isPaused(_ defaults: UserDefaults) -> Bool { defaults.bool(forKey: key) }
    static func set(_ paused: Bool, _ defaults: UserDefaults) { defaults.set(paused, forKey: key) }

    /// Stops every running call with `stopped`, then every shell command (FR-603). Calls first,
    /// as for a level change.
    static func stopWork(
        calls: @Sendable (@escaping @Sendable (String) -> String?) async -> Void, shell: ShellJobs
    ) async {
        await calls { _ in stopped }
        await shell.stopAll()
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
