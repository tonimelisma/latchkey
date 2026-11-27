import Foundation
import Testing

@testable import Latchkey

/// A Mac without a battery says so to the relay (spec 001 FR-065a). Found by the sandbox Mac
/// (2026-11-26): a virtual Mac, like a desktop, was reported to Claude as "100% battery".
@Suite struct PowerSnapshotTests {
    func snapshot(hasBattery: Bool) -> PowerSnapshot {
        PowerSnapshot(
            hasBattery: hasBattery, batteryPercent: 100, powerSource: .ac, charging: false, timeRemainingMin: nil,
            thermal: .nominal, lowPowerMode: false, lidClosed: nil, timeZone: nil)
    }

    @Test func aMacWithoutABatterySaysSo() throws {
        let state = snapshot(hasBattery: false).agentState(keepAwake: .on)
        #expect(state.hasBattery == false)
        let json = try #require(String(data: JSONEncoder().encode(state), encoding: .utf8))
        #expect(json.contains("\"has_battery\":false"), "\(json)")
    }

    @Test func aMacWithABatteryLeavesItOut() throws {
        let state = snapshot(hasBattery: true).agentState(keepAwake: .on)
        #expect(state.hasBattery == nil)
        let json = try #require(String(data: JSONEncoder().encode(state), encoding: .utf8))
        #expect(!json.contains("has_battery"), "\(json)")
    }
}
