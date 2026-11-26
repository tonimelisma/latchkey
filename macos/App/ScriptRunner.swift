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
    /// macOS's Automation answer for `app` (a stand-in in tests).
    var automation: @Sendable (String) async -> Permissions.Automation? = { await Permissions.automationOpening($0) }

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
                    { [automation] () async -> Permissions.Automation?? in .some(await automation(app)) })
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
        await first(within: limit, clock: ContinuousClock(), work)
    }

    /// The same, with the limit measured on `clock`: tests pass one they move by hand, so no test
    /// waits out a limit or measures one in real time (spec 016 FR-1602).
    static func first<T: Sendable>(
        within limit: Duration, clock: any Clock<Duration>, _ work: @escaping @Sendable () async -> T?
    ) async -> T? {
        let once = Once<T>()
        return await withCheckedContinuation { (done: CheckedContinuation<T?, Never>) in
            once.set(done)
            let worker = Task { once.finish(await work()) }
            Task {
                try? await clock.sleep(for: limit)
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
        private var pid: pid_t?
        private var ended = false
        private var cancelled = false

        func started(_ p: pid_t) {
            lock.withLock {
                pid = p
                if cancelled { Darwin.kill(p, SIGTERM) }
            }
        }

        /// The program ended and was reaped: its number may belong to another program now.
        func exited() { lock.withLock { ended = true } }

        /// Ends the program (SIGTERM, as Process.terminate) unless it already ended.
        func terminate() {
            lock.withLock {
                if let pid, !ended { Darwin.kill(pid, SIGTERM) }
            }
        }

        /// Ends the program for certain (SIGKILL), unless it already ended.
        func kill() {
            lock.withLock {
                if let pid, !ended { Darwin.kill(pid, SIGKILL) }
            }
        }

        func cancel() {
            lock.withLock { cancelled = true }
            terminate()
        }
    }

    private static func launch(_ executable: String, _ args: [String], timeout: Duration, running: Running)
        async throws -> ProcessResult
    {
        try await withCheckedThrowingContinuation { cont in
            DispatchQueue.global().async {
                let started: Spawn.Started
                do { started = try Spawn.start(executable, args) } catch {
                    cont.resume(throwing: error)
                    return
                }
                running.started(started.pid)
                let timedOut = Flag()
                let timer = DispatchWorkItem {
                    timedOut.set()
                    running.terminate()
                    // A program that ignores SIGTERM (or a child of it holding the output open)
                    // still ends (Constitution II).
                    DispatchQueue.global().asyncAfter(deadline: .now() + 3) { running.kill() }
                }
                let c = timeout.components
                DispatchQueue.global().asyncAfter(
                    deadline: .now() + Double(c.seconds) + Double(c.attoseconds) / 1e18, execute: timer)
                let errData = Box()
                let group = DispatchGroup()
                group.enter()
                DispatchQueue.global().async {
                    errData.data = started.error.readDataToEndOfFile()
                    group.leave()
                }
                let outData = started.output.readDataToEndOfFile()
                group.wait()
                let status = Spawn.wait(started.pid) { running.exited() }
                timer.cancel()
                cont.resume(
                    returning: ProcessResult(
                        status: status, output: outData, error: errData.data, timedOut: timedOut.isSet))
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
actor TakingTurns {
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

/// Starts a program with its arguments exactly as given. Foundation's Process hands arguments
/// over as file-system names, which macOS decomposes: "é" reached Safari as "e" and U+0301, so a
/// site comparing what was typed saw other text (0.8.246, 2026-11-26; Messages, Notes and
/// Reminders got their text the same way). posix_spawn takes the UTF-8 bytes as they are.
enum Spawn {
    struct Started {
        let pid: pid_t
        let output: FileHandle
        let error: FileHandle
    }

    struct Failed: Error, LocalizedError {
        let code: Int32
        let executable: String
        var errorDescription: String? { "Couldn't start \(executable): \(String(cString: strerror(code)))" }
    }

    /// Starts `executable` with `args`, Latchkey's environment, input from /dev/null, and its
    /// output and errors in pipes. Every other descriptor stays closed in the program.
    static func start(_ executable: String, _ args: [String]) throws -> Started {
        var out: [Int32] = [-1, -1]
        var err: [Int32] = [-1, -1]
        guard pipe(&out) == 0 else { throw Failed(code: errno, executable: executable) }
        guard pipe(&err) == 0 else {
            let code = errno
            close(out[0])
            close(out[1])
            throw Failed(code: code, executable: executable)
        }
        var actions: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&actions)
        defer { posix_spawn_file_actions_destroy(&actions) }
        posix_spawn_file_actions_addopen(&actions, 0, "/dev/null", O_RDONLY, 0)
        posix_spawn_file_actions_adddup2(&actions, out[1], 1)
        posix_spawn_file_actions_adddup2(&actions, err[1], 2)
        var attributes: posix_spawnattr_t?
        posix_spawnattr_init(&attributes)
        defer { posix_spawnattr_destroy(&attributes) }
        // Only the three descriptors above reach the program, and it starts with no signal
        // blocked or ignored, as Process starts one: a dispatch thread's blocked signals would
        // otherwise pass on, and the deadline's SIGTERM would not end it (security review
        // 2026-11-26).
        var noSignals = sigset_t()
        sigemptyset(&noSignals)
        var allSignals = sigset_t()
        sigfillset(&allSignals)
        posix_spawnattr_setsigmask(&attributes, &noSignals)
        posix_spawnattr_setsigdefault(&attributes, &allSignals)
        posix_spawnattr_setflags(
            &attributes, Int16(POSIX_SPAWN_CLOEXEC_DEFAULT | POSIX_SPAWN_SETSIGMASK | POSIX_SPAWN_SETSIGDEF))
        let argv: [UnsafeMutablePointer<CChar>?] = ([executable] + args).map { strdup($0) } + [nil]
        defer { for a in argv { free(a) } }
        // Latchkey's own environment, as Process passes it.
        let envp: [UnsafeMutablePointer<CChar>?] =
            ProcessInfo.processInfo.environment.map { strdup("\($0.key)=\($0.value)") } + [nil]
        defer { for e in envp { free(e) } }
        var pid: pid_t = 0
        let code = posix_spawn(&pid, executable, &actions, &attributes, argv, envp)
        close(out[1])
        close(err[1])
        guard code == 0 else {
            close(out[0])
            close(err[0])
            throw Failed(code: code, executable: executable)
        }
        return Started(
            pid: pid, output: FileHandle(fileDescriptor: out[0], closeOnDealloc: true),
            error: FileHandle(fileDescriptor: err[0], closeOnDealloc: true))
    }

    /// Waits for the program to end and reaps it; answers its exit status, or the signal that
    /// ended it (as Process's terminationStatus). `ended` runs once it has ended but before it is
    /// reaped, while its number still can't be another program's (security review 2026-11-26).
    static func wait(_ pid: pid_t, ended: () -> Void = {}) -> Int32 {
        var info = siginfo_t()
        while waitid(P_PID, id_t(pid), &info, WEXITED | WNOWAIT) == -1, errno == EINTR {}
        ended()
        var status: Int32 = 0
        while waitpid(pid, &status, 0) == -1, errno == EINTR {}
        let signal = status & 0x7f
        return signal == 0 ? (status >> 8) & 0xff : signal
    }
}
