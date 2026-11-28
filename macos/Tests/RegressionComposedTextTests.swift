import Foundation
import Testing

@testable import Latchkey

/// 2026-11-26, live on 0.8.246 (the maintainer's Mac, unlocked, a Safari tab of Claude's): typing "hé"
/// gave the page "h", "e", U+0301: the text reached Safari decomposed, as a file name is, so a
/// site comparing what was typed ("Café") saw something else. Latchkey's own browser got U+00E9.
/// Every program Latchkey starts (osascript for Safari, Messages, Notes, Reminders) gets the
/// text exactly as it was given.
@Suite struct RegressionComposedTextTests {
    static let composed = "Café ä ö Å 한"

    /// The bytes a started program sees in its arguments are the text's own (UTF-8, composed).
    @Test func aProgramGetsItsArgumentsAsGiven() async throws {
        let r = try await ProcessCommands.launch("/usr/bin/printf", ["%s", Self.composed], timeout: .seconds(10))
        #expect(r.status == 0)
        #expect(
            Array(r.output) == Array(Self.composed.utf8),
            "got \(r.output.map { String(format: "%02x", $0) }.joined(separator: " "))")
    }

    /// AppleScript sees the same characters (each one's Unicode number), as Safari's
    /// do JavaScript and Messages' send get them.
    @Test func anAppleScriptGetsTheTextAsGiven() async throws {
        let script = """
            on run argv
            set out to {}
            repeat with c in (id of (item 1 of argv) as list)
            set end of out to (c as text)
            end repeat
            set AppleScript's text item delimiters to ","
            return out as text
            end run
            """
        let got = try await OSAScriptRunner().run(script, [Self.composed])
        let want = Self.composed.unicodeScalars.map { String($0.value) }.joined(separator: ",")
        #expect(got.trimmingCharacters(in: .whitespacesAndNewlines) == want)
    }

    /// The shell runs the command's own text: what it prints is what was written.
    @Test func aShellCommandsTextIsAsGiven() async throws {
        let jobs = ShellJobs()
        let r = try await jobs.run("printf '%s' '\(Self.composed)'", folder: nil, wait: .seconds(20))
        #expect(r.exitCode == 0, "\(r.output)")
        #expect(
            Array(r.output.trimmingCharacters(in: .whitespacesAndNewlines).unicodeScalars)
                == Array(Self.composed.unicodeScalars),
            "\(r.output.unicodeScalars.map { String($0.value, radix: 16) })")
    }

    /// A folder with accents in its name is the command's own: it writes there, and sees the
    /// name as it is.
    @Test func aCommandWritesInAFolderWithAccents() async throws {
        let dir = FileManager.default.temporaryDirectory.appending(path: "Työ é \(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let jobs = ShellJobs()
        let r = try await jobs.run("echo hi > made.txt && pwd", folder: dir.path, wait: .seconds(20))
        #expect(r.exitCode == 0, "\(r.output)")
        #expect(FileManager.default.fileExists(atPath: dir.appending(path: "made.txt").path), "\(r.output)")
    }

    /// Security review 2026-11-26: a program started from a dispatch thread still ends at its
    /// deadline by the SIGTERM it is sent (it starts with no signal blocked), and the answer
    /// comes in time.
    @Test func aProgramPastItsDeadlineIsEndedBySIGTERM() async throws {
        let start = ContinuousClock.now
        let r = try await ProcessCommands.launch("/bin/sleep", ["60"], timeout: .seconds(1))
        #expect(r.timedOut)
        #expect(r.status == SIGTERM, "ended by signal \(r.status)")
        #expect(ContinuousClock.now - start < .seconds(15))
    }
}
