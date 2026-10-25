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
    var timeout: Duration = .seconds(25)

    func run(_ script: String, _ args: [String]) async throws -> String {
        let lines = script.split(separator: "\n", omittingEmptySubsequences: false).flatMap { ["-e", String($0)] }
        let r: ProcessResult
        do { r = try await ProcessCommands.launch("/usr/bin/osascript", lines + ["--"] + args, timeout: timeout) } catch
        {
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
