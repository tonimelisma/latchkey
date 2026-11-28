import Foundation

/// A clock that moves only when a test moves it (spec 016 FR-1602): a test of a time limit waits
/// for the limit's sleep, advances the clock past it and checks what happened, never how long it
/// took, so a busy runner can't decide it and no test waits out a limit in real time.
final class ManualClock: Clock, @unchecked Sendable {
    typealias Duration = Swift.Duration

    struct Instant: InstantProtocol {
        typealias Duration = Swift.Duration
        var offset: Swift.Duration

        func advanced(by duration: Swift.Duration) -> Instant { Instant(offset: offset + duration) }
        func duration(to other: Instant) -> Swift.Duration { other.offset - offset }
        static func < (a: Instant, b: Instant) -> Bool { a.offset < b.offset }
    }

    private struct Sleeper {
        let id: UInt64
        let until: Instant
        let wake: CheckedContinuation<Void, any Error>
    }

    private let lock = NSLock()
    private var current = Instant(offset: .zero)
    private var waiting: [Sleeper] = []
    private var nextID: UInt64 = 0

    var now: Instant { lock.withLock { self.current } }
    var minimumResolution: Swift.Duration { .zero }

    /// How many sleeps wait on this clock now.
    var sleeping: Int { lock.withLock { self.waiting.count } }

    func sleep(until deadline: Instant, tolerance: Swift.Duration?) async throws {
        let id: UInt64 = lock.withLock {
            self.nextID += 1
            return self.nextID
        }
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (wake: CheckedContinuation<Void, any Error>) in
                let ready: Bool? = self.lock.withLock {
                    if Task.isCancelled { return nil }
                    if deadline <= self.current { return true }
                    self.waiting.append(Sleeper(id: id, until: deadline, wake: wake))
                    return false
                }
                switch ready {
                case nil: wake.resume(throwing: CancellationError())
                case true?: wake.resume()
                case false?: break
                }
            }
        } onCancel: {
            let cancelled: Sleeper? = self.lock.withLock {
                guard let i = self.waiting.firstIndex(where: { $0.id == id }) else { return nil }
                return self.waiting.remove(at: i)
            }
            cancelled?.wake.resume(throwing: CancellationError())
        }
    }

    /// Moves the clock on by `duration` and wakes every sleep whose deadline has come.
    func advance(by duration: Swift.Duration) {
        let due: [Sleeper] = lock.withLock {
            self.current = self.current.advanced(by: duration)
            let now = self.current
            let ready = self.waiting.filter { $0.until <= now }
            self.waiting.removeAll { $0.until <= now }
            return ready
        }
        for sleeper in due { sleeper.wake.resume() }
    }

    /// Waits until `count` sleeps wait on this clock, so an advance can't come before the sleep it
    /// is meant to end; false if they don't within 10 s of real time.
    func waitForSleepers(_ count: Int = 1) async -> Bool {
        let giveUp = ContinuousClock.now + .seconds(10)
        while ContinuousClock.now < giveUp {
            if sleeping >= count { return true }
            try? await Task.sleep(for: .milliseconds(1))
        }
        return sleeping >= count
    }
}

// The requirements this file's tests cite (docs/requirements/; script/process-check).
// Validates: FR-1602
