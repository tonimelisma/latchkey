import Foundation

/// Runs AppleScript to drive other apps (spec 002 plan D3). A protocol so tests can stand in.
protocol ScriptRunner: Sendable {
    /// Runs `script`, whose `on run argv` handler receives `args`; returns what it returns.
    func run(_ script: String, _ args: [String]) async throws -> String
}

enum ScriptError: Error, Equatable {
    case timedOut
    /// The Owner hasn't allowed Latchkey to control the app (Automation, error -1743).
    case notAllowed
    case failed(String)
}

/// Runs scripts in `osascript`, so a stuck app can be abandoned at the deadline (an in-process
/// NSAppleScript can't be stopped and must stay on the main thread). The user's text travels as
/// arguments, never inside the script, after "--" so that none of it is read as an option (an
/// argument "-e" would otherwise add a line of AppleScript; security scan 2026-10-24).
struct OSAScriptRunner: ScriptRunner {
    /// The app the scripts control; when macOS hasn't asked about it yet, a script would raise
    /// its question during use, so it isn't run (FR-623).
    var app: String?
    var timeout: Duration = .seconds(25)

    func run(_ script: String, _ args: [String]) async throws -> String {
        let clock = ContinuousClock()
        let start = clock.now
        var left = timeout
        if let app {
            // The permission check asks macOS, which may wait on the app itself: while the Mac is
            // locked a napping Safari held it past the relay's 30 s before the script's own limit
            // began (2026-11-17). So it shares the script's limit.
            // An unknown answer (nil) still runs the script, as before; only no answer stops it.
            guard
                let answer = await Deadline.first(
                    within: timeout,
                    { () async -> Permissions.Automation?? in .some(await Permissions.automationOpening(app)) })
            else {
                EventLog.shared.record(
                    .permissions,
                    "The Automation check for \(app) didn't answer within \(timeout); the script didn't run",
                    error: true)
                throw ScriptError.timedOut
            }
            if answer == .notAsked { throw ScriptError.notAllowed }
            let spent = clock.now - start
            if spent > .seconds(3) {
                EventLog.shared.record(.permissions, "The Automation check for \(app) took \(spent)")
            }
            left = max(timeout - spent, .seconds(2))
        }
        let lines = script.split(separator: "\n", omittingEmptySubsequences: false).flatMap { ["-e", String($0)] }
        let r: ProcessResult
        do { r = try await ProcessCommands.launch("/usr/bin/osascript", lines + ["--"] + args, timeout: left) } catch {
            throw ScriptError.failed(error.localizedDescription)
        }
        if r.timedOut { throw ScriptError.timedOut }
        guard r.status == 0 else {
            let message = r.errorText
            throw message.contains("-1743")
                ? ScriptError.notAllowed : message.contains("-1712") ? .timedOut : .failed(message)
        }
        return r.outputText
    }
}

/// The answer of work that may never come back (a blocking Apple call behind a continuation),
/// or nil once `limit` passes. After that the work is cancelled and its late answer dropped.
enum Deadline {
    static func first<T: Sendable>(within limit: Duration, _ work: @escaping @Sendable () async -> T?) async -> T? {
        let once = Once<T>()
        return await withCheckedContinuation { (done: CheckedContinuation<T?, Never>) in
            once.set(done)
            let worker = Task { once.finish(await work()) }
            Task {
                try? await Task.sleep(for: limit)
                once.finish(nil)
                worker.cancel()
            }
        }
    }

    /// Resumes the continuation once: with the first answer, or nil at the limit.
    private final class Once<T: Sendable>: @unchecked Sendable {
        private let lock = NSLock()
        private var done: CheckedContinuation<T?, Never>?

        func set(_ c: CheckedContinuation<T?, Never>) { lock.withLock { done = c } }

        func finish(_ value: T?) {
            let c = lock.withLock {
                let c = done
                done = nil
                return c
            }
            c?.resume(returning: value)
        }
    }
}

/// Runs a helper program (mdfind and the like). A protocol so tests can stand in.
protocol CommandRunner: Sendable {
    /// Runs the program and returns its output; throws if it fails or passes the deadline.
    func run(_ executable: String, _ args: [String], timeout: Duration) async throws -> String
}

struct ProcessResult: Sendable {
    var status: Int32
    var output: Data
    var error: Data
    var timedOut: Bool

    /// Output as text, without the final line break.
    var outputText: String {
        var text = String(decoding: output, as: UTF8.self)
        if text.hasSuffix("\n") { text.removeLast() }
        return text
    }

    var errorText: String {
        String(decoding: error, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

enum CommandError: Error, Equatable {
    case timedOut
    case failed(String)
}

struct ProcessCommands: CommandRunner {
    func run(_ executable: String, _ args: [String], timeout: Duration) async throws -> String {
        let r = try await Self.launch(executable, args, timeout: timeout)
        if r.timedOut { throw CommandError.timedOut }
        guard r.status == 0 else { throw CommandError.failed(r.errorText) }
        return r.outputText
    }

    /// Runs a program off the main thread, reading its output as it comes so a large output
    /// can't stall it, and ends it at the deadline, or at once when the call it serves is
    /// cancelled (the relay gave up, or the Owner turned the capability off: FR-066).
    static func launch(_ executable: String, _ args: [String], timeout: Duration) async throws -> ProcessResult {
        let running = Running()
        return try await withTaskCancellationHandler {
            try await launch(executable, args, timeout: timeout, running: running)
        } onCancel: {
            running.cancel()
        }
    }

    /// The program of one launch, so a cancellation can end it whether it comes before or after
    /// the program starts.
    private final class Running: @unchecked Sendable {
        private let lock = NSLock()
        private var process: Process?
        private var cancelled = false

        func started(_ p: Process) {
            lock.withLock {
                process = p
                if cancelled { p.terminate() }
            }
        }

        func cancel() {
            lock.withLock {
                cancelled = true
                if let process, process.isRunning { process.terminate() }
            }
        }
    }

    private static func launch(_ executable: String, _ args: [String], timeout: Duration, running: Running)
        async throws -> ProcessResult
    {
        try await withCheckedThrowingContinuation { cont in
            DispatchQueue.global().async {
                let p = Process()
                p.executableURL = URL(filePath: executable)
                p.arguments = args
                let out = Pipe()
                let err = Pipe()
                p.standardOutput = out
                p.standardError = err
                p.standardInput = FileHandle.nullDevice
                do { try p.run() } catch {
                    cont.resume(throwing: error)
                    return
                }
                running.started(p)
                let timedOut = Flag()
                let timer = DispatchWorkItem {
                    timedOut.set()
                    p.terminate()
                }
                let c = timeout.components
                DispatchQueue.global().asyncAfter(
                    deadline: .now() + Double(c.seconds) + Double(c.attoseconds) / 1e18, execute: timer)
                let errData = Box()
                let group = DispatchGroup()
                group.enter()
                DispatchQueue.global().async {
                    errData.data = err.fileHandleForReading.readDataToEndOfFile()
                    group.leave()
                }
                let outData = out.fileHandleForReading.readDataToEndOfFile()
                group.wait()
                p.waitUntilExit()
                timer.cancel()
                cont.resume(
                    returning: ProcessResult(
                        status: p.terminationStatus, output: outData, error: errData.data, timedOut: timedOut.isSet))
            }
        }
    }

    private final class Flag: @unchecked Sendable {
        private let lock = NSLock()
        private var value = false
        func set() { lock.withLock { value = true } }
        var isSet: Bool { lock.withLock { value } }
    }

    private final class Box: @unchecked Sendable {
        var data = Data()
    }
}

/// One caller at a time, in order, each waiting at most a limit for its turn (Constitution II):
/// two chats picking the owner's Safari tabs at once must not interleave a pick and an action
/// (a click meant for an E*TRADE tab landed on another chat's Target checkout, 2026-11-19).
actor OneAtATime {
    private var busy = false
    private var waiting: [(id: UInt64, turn: CheckedContinuation<Bool, Never>)] = []
    private var nextID: UInt64 = 0

    /// Waits for its turn up to `limit`; false when it didn't come (then nothing is held).
    func enter(within limit: Duration) async -> Bool {
        if !busy {
            busy = true
            return true
        }
        nextID += 1
        let id = nextID
        return await withCheckedContinuation { (turn: CheckedContinuation<Bool, Never>) in
            waiting.append((id, turn))
            Task {
                try? await Task.sleep(for: limit)
                await self.giveUp(id)
            }
        }
    }

    private func giveUp(_ id: UInt64) {
        guard let i = waiting.firstIndex(where: { $0.id == id }) else { return }
        waiting.remove(at: i).turn.resume(returning: false)
    }

    /// Ends the turn: the next caller's starts.
    func leave() {
        if waiting.isEmpty { busy = false } else { waiting.removeFirst().turn.resume(returning: true) }
    }
}
