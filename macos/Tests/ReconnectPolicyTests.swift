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
        #expect(ReconnectPolicy.action(forClose: 4003) == .stop)
        #expect(ReconnectPolicy.action(forClose: 4004) == .updateRequired)
        #expect(ReconnectPolicy.action(forClose: 4005) == .reconnect)
        #expect(ReconnectPolicy.action(forClose: 4006) == .reconnect)
        #expect(ReconnectPolicy.action(forClose: 1006) == .reconnect, "abnormal closure")
    }
}
