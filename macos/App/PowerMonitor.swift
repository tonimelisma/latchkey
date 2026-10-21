import Foundation
import IOKit
import IOKit.ps

/// What the Mac's power hardware reports right now (plan D8).
struct PowerSnapshot: Equatable, Sendable {
    var hasBattery: Bool
    var batteryPercent: Int
    var powerSource: PowerSource
    var charging: Bool
    var timeRemainingMin: Int?
    var thermal: ThermalLevel
    var lowPowerMode: Bool
    var lidClosed: Bool?
    var timeZone: String?

    func agentState(keepAwake: KeepAwake, at date: Date = Date()) -> AgentState {
        AgentState(
            batteryPercent: batteryPercent, powerSource: powerSource, charging: charging,
            timeRemainingMin: timeRemainingMin, thermalState: thermal, lowPowerMode: lowPowerMode,
            lidClosed: lidClosed, timeZone: timeZone, keepAwake: keepAwake,
            observedAt: Date(timeIntervalSince1970: date.timeIntervalSince1970.rounded(.down)))
    }
}

enum PowerReader {
    static func read() -> PowerSnapshot {
        var s = PowerSnapshot(
            hasBattery: false, batteryPercent: 100, powerSource: .unknown, charging: false, timeRemainingMin: nil,
            thermal: thermal(), lowPowerMode: ProcessInfo.processInfo.isLowPowerModeEnabled,
            lidClosed: lidClosed(), timeZone: TimeZone.current.identifier)
        guard let blob = IOPSCopyPowerSourcesInfo()?.takeRetainedValue() else { return s }
        switch IOPSGetProvidingPowerSourceType(blob)?.takeUnretainedValue() as String? {
        case kIOPSACPowerValue: s.powerSource = .ac
        case kIOPSBatteryPowerValue: s.powerSource = .battery
        case "UPS Power": s.powerSource = .ups  // kIOPSUPSPowerValue, not exported to Swift
        default: s.powerSource = .unknown
        }
        let sources = IOPSCopyPowerSourcesList(blob)?.takeRetainedValue() as? [CFTypeRef] ?? []
        for ps in sources {
            guard let d = IOPSGetPowerSourceDescription(blob, ps)?.takeUnretainedValue() as? [String: Any],
                d[kIOPSTypeKey] as? String == kIOPSInternalBatteryType
            else { continue }
            s.hasBattery = true
            if let cur = d[kIOPSCurrentCapacityKey] as? Int, let max = d[kIOPSMaxCapacityKey] as? Int, max > 0 {
                s.batteryPercent = Int((Double(cur) / Double(max) * 100).rounded())
            }
            s.charging = d[kIOPSIsChargingKey] as? Bool ?? false
            if let mins = d[kIOPSTimeToEmptyKey] as? Int, mins > 0, s.powerSource == .battery {
                s.timeRemainingMin = mins
            }
        }
        return s
    }

    static func thermal() -> ThermalLevel {
        switch ProcessInfo.processInfo.thermalState {
        case .nominal: .nominal
        case .fair: .fair
        case .serious: .serious
        case .critical: .critical
        @unknown default: .nominal
        }
    }

    /// The kernel's SleepDisabled flag on IOPMrootDomain (what `pmset disablesleep` sets), read
    /// with a public, unprivileged IORegistry call. nil if unreadable.
    static func sleepDisabled() -> Bool? {
        let root = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOPMrootDomain"))
        guard root != 0 else { return nil }
        defer { IOObjectRelease(root) }
        let value = IORegistryEntryCreateCFProperty(root, "SleepDisabled" as CFString, kCFAllocatorDefault, 0)
        return value?.takeRetainedValue() as? Bool
    }

    /// AppleClamshellState on IOPMrootDomain: true when the lid is closed; nil on Macs without one.
    static func lidClosed() -> Bool? {
        let root = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOPMrootDomain"))
        guard root != 0 else { return nil }
        defer { IOObjectRelease(root) }
        let value = IORegistryEntryCreateCFProperty(root, "AppleClamshellState" as CFString, kCFAllocatorDefault, 0)
        return value?.takeRetainedValue() as? Bool
    }
}

/// Calls back on the main thread whenever power, thermal, or Low Power Mode state may have
/// changed (FR-031, FR-036).
@MainActor
final class PowerMonitor {
    private let onChange: @MainActor () -> Void
    private var source: CFRunLoopSource?
    private var observers: [NSObjectProtocol] = []

    init(onChange: @escaping @MainActor () -> Void) {
        self.onChange = onChange
        let context = Unmanaged.passUnretained(self).toOpaque()
        if let src = IOPSNotificationCreateRunLoopSource(
            { ctx in
                guard let ctx else { return }
                let monitor = Unmanaged<PowerMonitor>.fromOpaque(ctx).takeUnretainedValue()
                MainActor.assumeIsolated { monitor.onChange() }
            }, context)?.takeRetainedValue()
        {
            CFRunLoopAddSource(CFRunLoopGetMain(), src, .defaultMode)
            source = src
        }
        let nc = NotificationCenter.default
        for name in [ProcessInfo.thermalStateDidChangeNotification, Notification.Name.NSProcessInfoPowerStateDidChange]
        {
            observers.append(
                nc.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                    MainActor.assumeIsolated { self?.onChange() }
                })
        }
    }

    isolated deinit {
        if let source { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .defaultMode) }
        observers.forEach(NotificationCenter.default.removeObserver)
    }
}
