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
