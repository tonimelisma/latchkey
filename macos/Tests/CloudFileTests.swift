import Foundation
import Testing

@testable import Latchkey

/// Downloading cloud-only files before reading them (spec 003 edge cases, plan D2).
struct CloudFileTests {
    /// A pretend cloud file: here once `arrive` has run.
    final class Pretend: @unchecked Sendable {
        private let lock = NSLock()
        private var here = false
        private var log: [String] = []
        var steps: [String] { lock.withLock { log } }
        var isHere: Bool { lock.withLock { here } }
        func arrive() { lock.withLock { here = true } }
        func note(_ s: String) { lock.withLock { log.append(s) } }
    }

    static func denied() -> NSError {
        NSError(
            domain: NSCocoaErrorDomain, code: 257,
            userInfo: [NSUnderlyingErrorKey: NSError(domain: NSPOSIXErrorDomain, code: Int(EPERM))])
    }

    func steps(
        _ p: Pretend, coordinate: @escaping @Sendable (Pretend) -> Error?,
        request: @escaping @Sendable (Pretend) throws -> Void
    )
        -> CloudFile.Steps
    {
        CloudFile.Steps(
            isCloudOnly: { _ in !p.isHere },
            coordinate: { _, _ in
                p.note("coordinate")
                return coordinate(p)
            },
            request: { _ in
                p.note("request")
                try request(p)
            },
            pause: .milliseconds(10))
    }

    let url = URL(filePath: "/tmp/somewhere/file.jpg")

    @Test func aFileAlreadyHereIsLeftAlone() async {
        let p = Pretend()
        p.arrive()
        let why = await CloudFile.download(url, steps: steps(p, coordinate: { _ in nil }, request: { _ in }))
        #expect(why == nil)
        #expect(p.steps.isEmpty)
    }

    @Test func coordinationDownloadsIt() async {
        let p = Pretend()
        let why = await CloudFile.download(
            url,
            steps: steps(
                p,
                coordinate: {
                    $0.arrive()
                    return nil
                }, request: { _ in }))
        #expect(why == nil)
        #expect(p.steps == ["coordinate"])
    }

    /// The bug of 2026-11-04: the download request was refused and nothing else was tried.
    @Test func aRefusedCoordinationFallsBackToTheRequest() async {
        let p = Pretend()
        let why = await CloudFile.download(
            url, steps: steps(p, coordinate: { _ in Self.denied() }, request: { $0.arrive() }))
        #expect(why == nil)
        #expect(p.steps == ["coordinate", "request"])
    }

    @Test func whenEverythingFailsTheCodesSayWhy() async {
        let p = Pretend()
        let why = await CloudFile.download(
            url, steps: steps(p, coordinate: { _ in Self.denied() }, request: { _ in throw Self.denied() }))
        #expect(
            why
                == "coordination: NSCocoaErrorDomain 257 < NSPOSIXErrorDomain 1; download request: NSCocoaErrorDomain 257 < NSPOSIXErrorDomain 1"
        )
        #expect(!(why ?? "").contains("file.jpg"))
    }

    @Test func aStuckCoordinationEndsAtTheDeadlineAndIsCancelled() async {
        let p = Pretend()
        let s = CloudFile.Steps(
            isCloudOnly: { _ in true },
            coordinate: { _, coordinator in
                // Stands in for File Provider: waits until cancelled, as a real coordination does.
                let start = Date()
                while Date().timeIntervalSince(start) < 10 {
                    if p.steps.contains("cancelled") { return CocoaError(.userCancelled) }
                    Thread.sleep(forTimeInterval: 0.01)
                }
                return nil
            },
            request: { _ in p.note("request") }, pause: .milliseconds(10),
            cancel: { _ in p.note("cancelled") })
        let clock = ContinuousClock()
        let start = clock.now
        let why = await CloudFile.download(url, within: .milliseconds(300), steps: s)
        #expect(clock.now - start < .seconds(8))  // 0.3 s alone; the whole suite in parallel is slower
        #expect(why?.hasPrefix("it didn't download within") == true)
        #expect(!p.steps.contains("request"))
        let waitStart = Date()
        while !p.steps.contains("cancelled"), Date().timeIntervalSince(waitStart) < 8 {
            try? await Task.sleep(for: .milliseconds(10))
        }
        #expect(p.steps.contains("cancelled"))
    }

    @Test func anOrdinaryFileIsNotCloudOnly() throws {
        let file = FileManager.default.temporaryDirectory.appending(path: "cloud-\(UUID().uuidString).txt")
        try "here".write(to: file, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: file) }
        #expect(!CloudFile.isCloudOnly(file))
    }
}
