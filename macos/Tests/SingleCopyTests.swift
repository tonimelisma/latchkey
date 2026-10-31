import Foundation
import Testing

@testable import Latchkey

/// Only one copy of the app runs (FR-207): a second one started by hand or by another program
/// took over the connection on 2026-10-31, then quit, and left the Mac offline.
struct SingleCopyTests {
    final class Others: @unchecked Sendable {
        private let lock = NSLock()
        private var running: [pid_t]
        init(_ running: [pid_t]) { self.running = running }
        func now() -> [pid_t] { lock.withLock { running } }
        func quit() { lock.withLock { running = [] } }
    }

    @Test func aloneStartsAtOnce() async {
        let start = ContinuousClock.now
        #expect(await !SingleCopy.anotherStays(wait: .seconds(5), others: { [] }))
        #expect(ContinuousClock.now - start < .seconds(1))
    }

    @Test func anotherThatStaysMakesThisOneQuit() async {
        #expect(await SingleCopy.anotherStays(wait: .milliseconds(300), others: { [42] }))
    }

    /// An update: the old copy starts the new one, then quits.
    @Test func aCopyHandingOverIsWaitedFor() async {
        let others = Others([42])
        Task {
            try? await Task.sleep(for: .milliseconds(200))
            others.quit()
        }
        #expect(await !SingleCopy.anotherStays(wait: .seconds(5), others: others.now))
    }
}
