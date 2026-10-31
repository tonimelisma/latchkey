import Foundation
import Testing

@testable import Latchkey

@Suite struct ReconnectPolicyTests {
    @Test func backoffDoublesFromOneSecondToThirty() {
        let middle = ReconnectPolicy(jitter: { 1.0 })
        #expect(middle.delay(attempt: 0) == 1)
        #expect(middle.delay(attempt: 1) == 2)
        #expect(middle.delay(attempt: 2) == 4)
        #expect(middle.delay(attempt: 4) == 16)
        #expect(middle.delay(attempt: 5) == 30)
        #expect(middle.delay(attempt: 50) == 30, "capped")
    }

    @Test func jitterStaysWithinBounds() {
        let low = ReconnectPolicy(jitter: { 0.8 })
        let high = ReconnectPolicy(jitter: { 1.2 })
        #expect(low.delay(attempt: 3) == 6.4)
        #expect(high.delay(attempt: 3) == 9.6)
        #expect(high.delay(attempt: 10) == 30, "the cap includes jitter")
        let real = ReconnectPolicy()
        for attempt in 0..<10 {
            let d = real.delay(attempt: attempt)
            #expect(d >= 0.8 && d <= 30)
        }
    }

    @Test func closeCodes() {
        #expect(ReconnectPolicy.action(forClose: 1000) == .reconnect)
        #expect(ReconnectPolicy.action(forClose: 4001) == .signInAgain)
        #expect(ReconnectPolicy.action(forClose: 4002) == .revoked)
        #expect(ReconnectPolicy.action(forClose: 4003) == .replaced)
        #expect(ReconnectPolicy.action(forClose: 4004) == .updateRequired)
        #expect(ReconnectPolicy.action(forClose: 4005) == .reconnect)
        #expect(ReconnectPolicy.action(forClose: 4006) == .reconnect)
        #expect(ReconnectPolicy.action(forClose: 1006) == .reconnect, "abnormal closure")
    }

    /// FR-204: 4001 with the relay's reason "account suspended" is not a failed sign-in.
    @Test func aSuspensionIsToldFromAFailedSignIn() {
        #expect(ReconnectPolicy.action(forClose: 4001, reason: "account suspended") == .suspended)
        #expect(ReconnectPolicy.action(forClose: 4001, reason: "authentication failed") == .signInAgain)
        #expect(ReconnectPolicy.action(forClose: 4001, reason: nil) == .signInAgain, "any other 4001 is as before")
        #expect(ReconnectPolicy.action(forClose: 4001, reason: "") == .signInAgain)
        #expect(ReconnectPolicy.action(forClose: 4001, reason: "Account Suspended") == .signInAgain, "the exact text")
        #expect(ReconnectPolicy.action(forClose: 4002, reason: "account suspended") == .revoked, "only with 4001")
        #expect(ReconnectPolicy.action(forClose: 1000, reason: "account suspended") == .reconnect)
    }

    /// Close code and reason in; what the app shows and when it tries again out.
    @Test func whatACloseShowsAndWhenItRetries() {
        let policy = ReconnectPolicy(jitter: { 1.0 })
        typealias Next = ReconnectPolicy.Next
        let suspended = policy.next(afterClose: 4001, reason: "account suspended", attempt: 0)
        #expect(suspended == Next(show: .suspended, retryAfter: 300), "every 5 minutes")
        #expect(
            policy.next(afterClose: 4001, reason: "account suspended", attempt: 40) == suspended,
            "never faster or slower, however long it lasts")
        #expect(
            ReconnectPolicy(jitter: { 1.2 }).next(afterClose: 4001, reason: "account suspended", attempt: 3)
                == suspended)

        // FR-206 (Toni, 2026-10-31): never stop trying while paired.
        #expect(
            policy.next(afterClose: 4001, reason: "authentication failed", attempt: 0)
                == Next(show: .signInAgain, retryAfter: 300), "tries again every 5 minutes")
        #expect(policy.next(afterClose: 4001, reason: nil, attempt: 9) == Next(show: .signInAgain, retryAfter: 300))
        #expect(
            policy.next(afterClose: 4002, reason: nil, attempt: 0) == Next(show: .revoked, retryAfter: nil),
            "the key is deleted: nothing to connect with")
        #expect(policy.next(afterClose: 4003, reason: nil, attempt: 0) == Next(show: .replaced, retryAfter: 30))
        #expect(policy.next(afterClose: 4003, reason: nil, attempt: 20) == Next(show: .replaced, retryAfter: 30))
        #expect(policy.next(afterClose: 4004, reason: nil, attempt: 0) == Next(show: .updateRequired, retryAfter: 300))
        #expect(policy.next(afterClose: 1006, reason: nil, attempt: 2) == Next(show: nil, retryAfter: 4), "backoff")
        #expect(policy.next(afterClose: 4005, reason: nil, attempt: 0) == Next(show: nil, retryAfter: 1))
    }

    /// What the menu says. A suspended account is not asked to sign in again: that can't help.
    @Test func whatTheMenuSays() {
        #expect(ConnectionStatus.suspended.title() == "This account is suspended on the relay")
        #expect(
            ConnectionStatus.suspended.advice
                == "Contact the relay’s operator. Latchkey reconnects by itself when the suspension ends.")
        #expect(ConnectionStatus.signInAgain.title() == "Sign in again: the relay didn't accept this Mac")
        #expect(ConnectionStatus.signInAgain.advice == "Latchkey tries again every 5 minutes.")
        #expect(ConnectionStatus.replaced.advice == "Latchkey tries again in 30 seconds.")
        #expect(ConnectionStatus.connected.title() == "Connected")
        #expect(ConnectionStatus.connected.advice == nil)
        let now = Date()
        #expect(ConnectionStatus.waiting(until: now.addingTimeInterval(4)).title(now: now) == "Reconnecting in 4 s")
    }
}
