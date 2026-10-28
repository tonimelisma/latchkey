import Testing

@testable import Latchkey

@Suite struct KeepAwakePolicyTests {
    func inputs(
        power: PowerSource = .battery, percent: Int = 80, thermal: ThermalLevel = .nominal,
        enabled: Bool = true, helper: Bool = true
    ) -> KeepAwakeInputs {
        KeepAwakeInputs(
            powerSource: power, batteryPercent: percent, thermal: thermal, userEnabled: enabled, helperAvailable: helper
        )
    }

    /// The state the app reports when it first connects is what it's about to apply, not the
    /// default "off": until 0.8.24 every start sent "off" for a second, and the relay recorded
    /// two needless keep-awake changes (2026-10-27).
    @MainActor @Test func startsWithTheStateItIsAboutToApply() {
        let i = KeepAwakeInputs(
            powerSource: .ac, batteryPercent: 80, thermal: .nominal, userEnabled: true, helperAvailable: true)
        #expect(KeepAwakePolicy.atStart(i) == .on)
        let off = KeepAwakeInputs(
            powerSource: .ac, batteryPercent: 80, thermal: .nominal, userEnabled: false, helperAvailable: true)
        #expect(KeepAwakePolicy.atStart(off) == .offUser)
    }

    @Test func onWhenEverythingIsFine() {
        #expect(KeepAwakePolicy.decide(inputs()) == .on)
        #expect(KeepAwakePolicy.decide(inputs(power: .ac, percent: 5)) == .on, "plugged in, any level")
    }

    @Test func lowBatteryAtOrBelow15OnBattery() {
        #expect(KeepAwakePolicy.decide(inputs(percent: 16)) == .on)
        #expect(KeepAwakePolicy.decide(inputs(percent: 15)) == .offLowBattery, "FR-032")
        #expect(KeepAwakePolicy.decide(inputs(percent: 3)) == .offLowBattery)
        #expect(KeepAwakePolicy.decide(inputs(power: .ups, percent: 10)) == .on, "only on battery power")
    }

    @Test func tooHot() {
        #expect(KeepAwakePolicy.decide(inputs(thermal: .fair)) == .on)
        #expect(KeepAwakePolicy.decide(inputs(thermal: .serious)) == .offTooHot, "FR-033")
        #expect(KeepAwakePolicy.decide(inputs(thermal: .critical)) == .offTooHot)
    }

    @Test func userChoiceWins() {
        #expect(KeepAwakePolicy.decide(inputs(enabled: false)) == .offUser)
        #expect(KeepAwakePolicy.decide(inputs(thermal: .critical, enabled: false)) == .offUser)
    }

    @Test func helperUnavailable() {
        #expect(KeepAwakePolicy.decide(inputs(helper: false)) == .offHelperUnavailable)
    }

    @Test func comesBackWhenConditionsReturn() {
        // FR-034: re-enables by itself, without the user.
        #expect(KeepAwakePolicy.decide(inputs(percent: 12)) == .offLowBattery)
        #expect(KeepAwakePolicy.decide(inputs(power: .ac, percent: 12)) == .on, "charger connected")
        #expect(KeepAwakePolicy.decide(inputs(thermal: .serious)) == .offTooHot)
        #expect(KeepAwakePolicy.decide(inputs(thermal: .fair)) == .on)
    }

    @Test func sleepReasons() {
        #expect(KeepAwakePolicy.sleepReason(.offLowBattery) == .lowBattery)
        #expect(KeepAwakePolicy.sleepReason(.offTooHot) == .tooHot)
        #expect(KeepAwakePolicy.sleepReason(.on) == .systemSleep)
        #expect(KeepAwakePolicy.sleepReason(.offUser) == .systemSleep)
    }
}
