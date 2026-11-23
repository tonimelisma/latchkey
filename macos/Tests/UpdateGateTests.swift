import Foundation
import Testing

@testable import Latchkey

/// Signed updates install only while Latchkey is idle (spec 001 FR-072b): no call running and
/// none started or ended for the quiet time, read from the running-call marks (FR-667).
struct UpdateGateTests {
    private func folder() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appending(path: "UpdateGate-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func age(_ url: URL, by seconds: TimeInterval) throws {
        try FileManager.default.setAttributes(
            [.modificationDate: Date().addingTimeInterval(-seconds)], ofItemAtPath: url.path)
    }

    @Test func idleWhenNoCallRanSinceTheQuietTime() throws {
        let marks = try folder()
        defer { try? FileManager.default.removeItem(at: marks) }
        try age(marks, by: 11 * 60)
        #expect(UpdateGate.isIdle(marks: marks, now: Date(), quiet: 10 * 60))
    }

    @Test func notIdleWhileACallRuns() throws {
        let marks = try folder()
        defer { try? FileManager.default.removeItem(at: marks) }
        try Data("x".utf8).write(to: marks.appending(path: "call_1.call"))
        try age(marks, by: 60 * 60)
        #expect(!UpdateGate.isIdle(marks: marks, now: Date(), quiet: 10 * 60))
    }

    @Test func notIdleRightAfterACallEnded() throws {
        let marks = try folder()
        defer { try? FileManager.default.removeItem(at: marks) }
        try age(marks, by: 2 * 60)
        #expect(!UpdateGate.isIdle(marks: marks, now: Date(), quiet: 10 * 60))
    }

    @Test func otherFilesDontCountAsCalls() throws {
        let marks = try folder()
        defer { try? FileManager.default.removeItem(at: marks) }
        try Data("x".utf8).write(to: marks.appending(path: ".DS_Store"))
        try age(marks, by: 11 * 60)
        #expect(UpdateGate.isIdle(marks: marks, now: Date(), quiet: 10 * 60))
    }

    @Test func idleWhenNoCallEverRan() {
        let missing = FileManager.default.temporaryDirectory.appending(path: "UpdateGate-none-\(UUID().uuidString)")
        #expect(UpdateGate.isIdle(marks: missing, now: Date(), quiet: 10 * 60))
    }

    @Test func buildNumberGrowsWithTheReleaseNumber() {
        #expect(UpdateGate.buildNumber("0.8.231") == 8231)
        #expect(UpdateGate.buildNumber("1.0.0") == 1_000_000)
        #expect(UpdateGate.buildNumber("0.9.0")! > UpdateGate.buildNumber("0.8.999")!)
        #expect(UpdateGate.buildNumber("0.8.1000") == nil)
        #expect(UpdateGate.buildNumber("0.8") == nil)
    }
}
