import Foundation
import Testing

@testable import Latchkey

/// A blocking Apple call that never answers must not hold a script past its limit (2026-11-17:
/// the Automation check kept a locked tab list past the relay's 30 s).
struct DeadlineTests {
    @Test func aQuickAnswerComesBack() async {
        let answer = await Deadline.first(within: .seconds(5)) { () async -> Int? in 7 }
        #expect(answer == 7)
    }

    @Test func workThatNeverAnswersEndsAtTheLimit() async {
        let clock = ContinuousClock()
        let start = clock.now
        // Like the Automation check: a GCD call behind a continuation that ignores cancellation.
        let answer = await Deadline.first(within: .milliseconds(300)) { () async -> Int? in
            await withCheckedContinuation { done in
                DispatchQueue.global().asyncAfter(deadline: .now() + 3) { done.resume(returning: 1) }
            }
        }
        #expect(answer == nil)
        // Well before the work's 3 s, with room for a loaded machine (the full suite side by
        // side took 2.2 s on 2026-11-22).
        #expect(clock.now - start < .milliseconds(2_800))
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
