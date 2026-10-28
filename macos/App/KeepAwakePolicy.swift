import Foundation

struct KeepAwakeInputs: Equatable, Sendable {
    var powerSource: PowerSource
    var batteryPercent: Int
    var thermal: ThermalLevel
    var userEnabled: Bool
    var helperAvailable: Bool
}

/// Decides whether the Mac should be kept awake (FR-030 to FR-034). Stateless, so keep-awake
/// comes back by itself when conditions return to normal.
enum KeepAwakePolicy {
    static let lowBatteryThreshold = 15  // FR-032, fixed

    /// What the app reports when it first connects, before it has applied anything: the state it
    /// is about to apply, not a default "off" that flips a second later (2026-10-27).
    static func atStart(_ i: KeepAwakeInputs) -> KeepAwake { decide(i) }

    static func decide(_ i: KeepAwakeInputs) -> KeepAwake {
        if !i.userEnabled { return .offUser }
        if i.thermal == .serious || i.thermal == .critical { return .offTooHot }
        if i.powerSource == .battery && i.batteryPercent <= lowBatteryThreshold { return .offLowBattery }
        if !i.helperAvailable { return .offHelperUnavailable }
        return .on
    }

    /// The goodbye reason to send when macOS announces sleep.
    static func sleepReason(_ k: KeepAwake) -> GoodbyeReason {
        switch k {
        case .offLowBattery: .lowBattery
        case .offTooHot: .tooHot
        default: .systemSleep
        }
    }
}
