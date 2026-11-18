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
        #expect(clock.now - start < .seconds(2))
    }
}
