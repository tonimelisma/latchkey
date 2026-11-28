import Foundation
import Testing

@testable import Latchkey

/// A blocking Apple call that never answers must not hold a script past its limit (2026-11-17:
/// the Automation check kept a locked tab list past the relay's 30 s).
struct DeadlineTests {
    @Test func aQuickAnswerComesBack() async {
        // A clock that never moves: only the answer can end it.
        let answer = await Deadline.first(within: .seconds(5), clock: ManualClock()) { () async -> Int? in 7 }
        #expect(answer == 7)
    }

    /// On a clock the test moves (spec 016 FR-1602): nothing ends before the limit, the limit ends
    /// it whatever the work does, and the work's late answer is dropped.
    @Test func workThatNeverAnswersEndsAtTheLimit() async {
        let clock = ManualClock()
        // Like the Automation check: a call behind a continuation that ignores cancellation, held
        // until the test lets it answer.
        let held = HeldAnswer()
        let answer = Task {
            await Deadline.first(within: .milliseconds(300), clock: clock) { () async -> Int? in await held.answer() }
        }
        #expect(await clock.waitForSleepers(1), "the limit's sleep started")
        clock.advance(by: .milliseconds(299))
        #expect(clock.sleeping == 1, "not before the limit")
        clock.advance(by: .milliseconds(1))
        #expect(await answer.value == nil)
        held.release()
    }
}

/// Work that answers 1 only once the test releases it, whatever cancellation says.
private final class HeldAnswer: @unchecked Sendable {
    private let lock = NSLock()
    private var waiting: CheckedContinuation<Int?, Never>?
    private var released = false

    func answer() async -> Int? {
        await withCheckedContinuation { (c: CheckedContinuation<Int?, Never>) in
            let now: Bool = self.lock.withLock {
                if self.released { return true }
                self.waiting = c
                return false
            }
            if now { c.resume(returning: 1) }
        }
    }

    func release() {
        let c: CheckedContinuation<Int?, Never>? = lock.withLock {
            self.released = true
            let parked = self.waiting
            self.waiting = nil
            return parked
        }
        c?.resume(returning: 1)
    }
}

/// Calls naming the owner's Safari tabs take turns (2026-11-19: another chat's pick came between
/// a pick and its click), and a turn that doesn't come within its limit is given up.
struct TakingTurnsTests {
    @Test func aSecondCallerWaitsForTheFirstToLeave() async {
        let gate = TakingTurns()
        #expect(await gate.enter(within: .seconds(5)))
        let second = Task { await gate.enter(within: .seconds(5)) }
        try? await Task.sleep(for: .milliseconds(100))
        await gate.leave()
        #expect(await second.value, "its turn came once the first left")
        await gate.leave()
        #expect(await gate.enter(within: .milliseconds(10)), "free again")
    }

    @Test func aTurnThatDoesntComeIsGivenUp() async {
        let gate = TakingTurns()
        #expect(await gate.enter(within: .seconds(1)))
        #expect(!(await gate.enter(within: .milliseconds(100))))
        await gate.leave()
        #expect(await gate.enter(within: .milliseconds(100)), "the one that gave up holds nothing")
    }
}

// The requirements this file's tests cite (docs/requirements/; script/process-check).
// Validates: FR-1602
