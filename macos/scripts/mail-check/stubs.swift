// The three helpers the compose files use from the rest of the app, copied so the harness
// compiles without the whole Mail capability (MailWrite.bare, MailStore.bareSubject,
// MailCapability.mailApp; keep them the same as there).
import Foundation

enum MailWrite {
    static func bare(_ a: String) -> String {
        guard let open = a.lastIndex(of: "<"), let close = a.lastIndex(of: ">"), open < close else {
            return a.trimmingCharacters(in: .whitespaces)
        }
        return String(a[a.index(after: open)..<close])
    }
}

enum MailStore {
    static func bareSubject(_ s: String) -> String {
        var t = s.trimmingCharacters(in: .whitespaces)
        while let r = t.range(of: #"^(re|fwd?|aw|sv|vs)\s*:\s*"#, options: [.regularExpression, .caseInsensitive]) {
            t.removeSubrange(r)
        }
        return t.lowercased()
    }
}

enum MailCapability {
    static let mailApp = "com.apple.mail"
}

/// Latchkey's script runner, reduced to osascript (the app's also checks its Automation permission).
protocol ScriptRunner: Sendable {
    func run(_ script: String, _ args: [String]) async throws -> String
}

struct HarnessScripts: ScriptRunner {
    func run(_ script: String, _ args: [String]) async throws -> String {
        let p = Process()
        p.executableURL = URL(filePath: "/usr/bin/osascript")
        p.arguments =
            script.split(separator: "\n", omittingEmptySubsequences: false).flatMap { ["-e", String($0)] }
            + ["--"] + args
        let out = Pipe()
        let err = Pipe()
        p.standardOutput = out
        p.standardError = err
        try p.run()
        let data = out.fileHandleForReading.readDataToEndOfFile()
        let problem = String(decoding: err.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        p.waitUntilExit()
        if p.terminationStatus != 0 {
            print("script failed: \(problem)")
            throw ComposeFailure(message: problem)
        }
        return String(decoding: data, as: UTF8.self)
    }
}
