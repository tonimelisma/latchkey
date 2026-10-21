import Foundation
import Testing

@testable import Latchkey

@Suite struct CapabilityTests {
    let snapshot = PowerSnapshot(
        hasBattery: true, batteryPercent: 67, powerSource: .battery, charging: false, timeRemainingMin: 245,
        thermal: .nominal, lowPowerMode: false, lidClosed: true, timeZone: "Europe/Helsinki")

    @Test func batteryStatusMatchesContract() throws {
        let tool = SystemInfoCapability.batteryStatusTool
        #expect(tool.name == "battery_status")
        #expect(tool.deadlineMS == 5000)
        #expect(tool.annotations?.readOnlyHint == true)
        let result = SystemInfoCapability.batteryStatus(snapshot)
        #expect(result.isError == false)
        let structured = try #require(result.structuredContent)
        #expect(
            structured
                == .object([
                    "battery_percent": .number(67), "charging": .bool(false), "power_source": .string("battery"),
                    "time_remaining_min": .number(245),
                ]))
        guard case .array(let content) = result.content, case .object(let first) = content.first,
            case .string(let text) = first["text"]
        else { Issue.record("no text content"); return }
        #expect(text.contains("\"battery_percent\":67"))
    }

    @Test func noBatteryIsAnError() {
        var desktop = snapshot
        desktop.hasBattery = false
        let result = SystemInfoCapability.batteryStatus(desktop)
        #expect(result.isError)
    }

    @Test func disabledCapabilityHasNoTools() {
        var registry = CapabilityRegistry(enabled: [])
        #expect(registry.tools.isEmpty, "Constitution III")
        registry.setEnabled(SystemInfoCapability.id, true)
        #expect(registry.tools.map(\.name) == ["battery_status"])
        registry.setEnabled(SystemInfoCapability.id, false)
        #expect(registry.tools.isEmpty)
    }

    @Test func callingADisabledToolFails() async {
        let registry = CapabilityRegistry(enabled: [])
        let result = await registry.call(tool: "battery_status", arguments: .object([:]), power: { snapshot })
        #expect(result.isError)
    }

    @Test func callingAnEnabledTool() async {
        let registry = CapabilityRegistry(enabled: [SystemInfoCapability.id])
        let result = await registry.call(tool: "battery_status", arguments: .object([:]), power: { snapshot })
        #expect(!result.isError)
    }

    @Test func systemInfoIsOnByDefault() {
        #expect(CapabilityRegistry.defaultEnabled == [SystemInfoCapability.id], "FR-064")
    }
}
