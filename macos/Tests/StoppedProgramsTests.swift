import Foundation
import Testing

@testable import Latchkey

/// A program a command started that macOS stopped (bug report 2026-11-03: headless Chrome
/// aborted inside the fence, the command still said exit status 0, and only the crash dialog on
/// the owner's screen told).
@Suite struct StoppedProgramsTests {
    let dir = FileManager.default.temporaryDirectory.appending(path: "crashes-\(UUID().uuidString)")

    init() throws { try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true) }

    /// A report as macOS writes it: a one-line header, then the body.
    func write(
        _ name: String, proc: String = "Google Chrome",
        path: String = "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome", signal: String = "SIGABRT",
        responsiblePid: Int = 4242, captured: String = "2026-11-03 19:53:57.8874 -0800",
        asi: String = #"{"libsystem_c.dylib":["abort() called"]}"#
    ) throws {
        let header = #"{"app_name":"\#(proc)","timestamp":"2026-11-03 19:54:02.00 -0800","bug_type":"309"}"#
        let body = """
            {
              "uptime" : 100,
              "captureTime" : "\(captured)",
              "pid" : 91351,
              "procName" : "\(proc)",
              "procPath" : "\(path.replacingOccurrences(of: "/", with: "\\/"))",
              "parentPid" : 91323,
              "coalitionName" : "net.melisma.latchkey",
              "responsiblePid" : \(responsiblePid),
              "responsibleProc" : "Latchkey",
              "exception" : {"codes":"0x0, 0x0","rawCodes":[0,0],"type":"EXC_CRASH","signal":"\(signal)"},
              "asi" : \(asi)
            }
            """
        try (header + "\n" + body).write(to: dir.appending(path: name), atomically: true, encoding: .utf8)
    }

    let from = ISO8601DateFormatter().date(from: "2026-11-04T03:53:49Z")!
    let to = ISO8601DateFormatter().date(from: "2026-11-04T03:54:10Z")!

    @Test func findsTheProgramItsSignalAndWhy() throws {
        try write("Google Chrome-2026-11-03-195402.ips")
        let found = StoppedPrograms.find(in: dir, from: from, to: to, responsible: 4242)
        #expect(found.count == 1)
        #expect(found.first?.program == "Google Chrome")
        #expect(found.first?.signal == "SIGABRT")
        #expect(found.first?.reason == "abort() called")
        #expect(found.first?.isApp == true)
    }

    @Test func onlyThoseLatchkeyStartedInTheJobsTime() throws {
        try write("other.ips", responsiblePid: 1)
        try write("early.ips", captured: "2026-11-03 19:50:00.0000 -0800")
        try write("late.ips", captured: "2026-11-03 19:55:00.0000 -0800")
        try "not a report".write(to: dir.appending(path: "junk.ips"), atomically: true, encoding: .utf8)
        try write("not-a-report.txt")
        #expect(StoppedPrograms.find(in: dir, from: from, to: to, responsible: 4242).isEmpty)
    }

    @Test func theNoteSaysWhatToDoForAnApp() throws {
        try write("a.ips")
        let found = StoppedPrograms.find(in: dir, from: from, to: to, responsible: 4242)
        let note = StoppedPrograms.note(found, job: nil, usesOpen: false)
        #expect(note.contains("Google Chrome"))
        #expect(note.contains("SIGABRT"))
        #expect(note.contains(#"uses ["open"]"#))
        let declared = StoppedPrograms.note(found, job: nil, usesOpen: true)
        #expect(!declared.contains(#"declare uses"#))
        #expect(declared.contains("--no-sandbox"))
    }

    @Test func aCommandLineProgramGetsNoAppAdvice() throws {
        try write("tool.ips", proc: "mytool", path: "/usr/local/bin/mytool", signal: "SIGSEGV", asi: "null")
        let found = StoppedPrograms.find(in: dir, from: from, to: to, responsible: 4242)
        let note = StoppedPrograms.note(found, job: "job2", usesOpen: false)
        #expect(note.contains("mytool (SIGSEGV)"))
        #expect(note.contains("job2"))
        #expect(!note.contains("uses"))
    }

    @Test func severalOfOneProgramAreNamedOnce() throws {
        try write("a.ips")
        try write("b.ips")
        let found = StoppedPrograms.find(in: dir, from: from, to: to, responsible: 4242)
        #expect(found.count == 2)
        let note = StoppedPrograms.note(found, job: nil, usesOpen: false)
        #expect(note.components(separatedBy: "Google Chrome").count == 2, "\(note)")
        #expect(note.contains("2 times"))
    }
}
