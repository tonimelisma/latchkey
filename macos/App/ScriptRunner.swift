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
/// arguments, never inside the script.
struct OSAScriptRunner: ScriptRunner {
    var timeout: Duration = .seconds(25)

    func run(_ script: String, _ args: [String]) async throws -> String {
        let timeout = timeout
        return try await withCheckedThrowingContinuation { cont in
            DispatchQueue.global().async {
                let p = Process()
                p.executableURL = URL(filePath: "/usr/bin/osascript")
                p.arguments =
                    script.split(separator: "\n", omittingEmptySubsequences: false).flatMap { ["-e", String($0)] }
                    + args
                let out = Pipe()
                let err = Pipe()
                p.standardOutput = out
                p.standardError = err
                p.standardInput = FileHandle.nullDevice
                do { try p.run() } catch {
                    cont.resume(throwing: ScriptError.failed(error.localizedDescription))
                    return
                }
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
                if timedOut.isSet { return cont.resume(throwing: ScriptError.timedOut) }
                guard p.terminationStatus == 0 else {
                    let message = String(decoding: errData.data, as: UTF8.self)
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                    return cont.resume(
                        throwing: message.contains("-1743")
                            ? ScriptError.notAllowed : message.contains("-1712") ? .timedOut : .failed(message))
                }
                var text = String(decoding: outData, as: UTF8.self)
                if text.hasSuffix("\n") { text.removeLast() }
                cont.resume(returning: text)
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
