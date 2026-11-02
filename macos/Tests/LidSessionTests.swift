import Testing

@testable import Latchkey

@Suite struct LidSessionTests {
    typealias D = LidSessionPolicy.Decision

    @Test func holdsWhileTheLidIsClosedAndTheSessionUnlocked() {
        #expect(
            LidSessionPolicy.decide(keepAwakeOn: true, lidClosed: true, locked: false, holding: false)
                == D(hold: true, lockNow: false))
        #expect(
            LidSessionPolicy.decide(keepAwakeOn: true, lidClosed: true, locked: false, holding: true)
                == D(hold: true, lockNow: false))
    }

    @Test func nothingWithTheLidOpenOrWithoutALid() {
        #expect(
            LidSessionPolicy.decide(keepAwakeOn: true, lidClosed: false, locked: false, holding: false)
                == D(hold: false, lockNow: false))
        #expect(
            LidSessionPolicy.decide(keepAwakeOn: true, lidClosed: nil, locked: false, holding: false)
                == D(hold: false, lockNow: false), "a desktop Mac")
    }

    @Test func aSessionAlreadyLockedIsLeftAlone() {
        #expect(
            LidSessionPolicy.decide(keepAwakeOn: true, lidClosed: true, locked: true, holding: false)
                == D(hold: false, lockNow: false))
    }

    @Test func openingTheLidLocksTheMacAtOnce() {
        #expect(
            LidSessionPolicy.decide(keepAwakeOn: true, lidClosed: false, locked: false, holding: true)
                == D(hold: false, lockNow: true))
        #expect(
            LidSessionPolicy.decide(keepAwakeOn: true, lidClosed: false, locked: true, holding: true)
                == D(hold: false, lockNow: false), "already locked")
    }

    @Test func aMonitorMeansTheMacIsInUseAtADesk() {
        #expect(
            LidSessionPolicy.decide(
                keepAwakeOn: true, lidClosed: true, locked: false, holding: false, externalDisplay: true)
                == D(hold: false, lockNow: false))
        #expect(
            LidSessionPolicy.decide(
                keepAwakeOn: true, lidClosed: false, locked: false, holding: false, externalDisplay: true)
                == D(hold: false, lockNow: false), "opening the lid at the desk doesn't lock")
        #expect(
            LidSessionPolicy.decide(
                keepAwakeOn: true, lidClosed: true, locked: false, holding: true, externalDisplay: true)
                == D(hold: false, lockNow: true), "a monitor plugged into a Mac kept unlocked behind its lid")
    }

    @Test func keepAwakeGoingOffBehindAClosedLidLocksToo() {
        // Low battery, too hot, or Latchkey paused: macOS's own sleep takes over, locked.
        #expect(
            LidSessionPolicy.decide(keepAwakeOn: false, lidClosed: true, locked: false, holding: true)
                == D(hold: false, lockNow: true))
        #expect(
            LidSessionPolicy.decide(keepAwakeOn: false, lidClosed: true, locked: false, holding: false)
                == D(hold: false, lockNow: false))
    }
}
