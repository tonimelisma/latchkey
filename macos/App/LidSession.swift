import ApplicationServices
import CoreGraphics
import Foundation
import IOKit.pwr_mgt

/// Keeps the session usable with the lid closed (Toni, 2026-11-01: lid closed is the common case
/// and things must work there). With the lid closed and keep-awake on, macOS keeps drawing the
/// screen and the session unlocked only until a few minutes after the last activity, then locks,
/// and while locked Mail's window, the screen, and Safari's scripting stop working (checked live
/// 2026-11-01). So while the lid is closed Latchkey holds a display-sleep assertion, and the
/// session stays as it was when the lid closed; when the lid opens again, Latchkey locks the Mac
/// at once, so whoever opens it meets the lock screen, as after sleep.
enum LidSessionPolicy {
    struct Decision: Equatable {
        var hold: Bool
        var lockNow: Bool
    }

    /// `holding`: the assertion is held now. A session already locked when the lid closed gains
    /// nothing from it (Latchkey never unlocks), so it isn't taken then. `externalDisplay`: a
    /// monitor other than the built-in one is on: closed with a monitor, the Mac is in use at a
    /// desk (nothing to do), and a monitor that appears behind a lid kept unlocked locks it.
    static func decide(
        keepAwakeOn: Bool, lidClosed: Bool?, locked: Bool, holding: Bool, externalDisplay: Bool = false
    ) -> Decision {
        let closed = lidClosed == true
        let hold = keepAwakeOn && closed && !externalDisplay && (holding || !locked)
        // The lid opened, a monitor appeared, or keep-awake went off while the session was kept
        // unlocked behind the lid.
        let lockNow = holding && !hold && !locked
        return Decision(hold: hold, lockNow: lockNow)
    }
}

@MainActor
final class LidSession {
    private var assertion: IOPMAssertionID = 0
    var holding: Bool { assertion != 0 }
    private var keepAwakeOn = false
    /// While keep-awake is on or the session is held, the lid, the lock, and the monitors are read
    /// every second (security review 2026-11-01: power notifications don't come with a lid
    /// change, so the hold could start late and the lock could lag). Reading them is cheap.
    private var watch: Timer?
    /// Where what was done goes (the activity log).
    var report: (@MainActor (String, Bool) -> Void)?

    /// Applies the policy with keep-awake's latest decision.
    func update(keepAwakeOn: Bool, lidClosed: Bool?) {
        self.keepAwakeOn = keepAwakeOn
        check(lidClosed: lidClosed)
    }

    private func keepWatching() {
        if keepAwakeOn || holding {
            guard watch == nil else { return }
            watch = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { _ in
                MainActor.assumeIsolated { [weak self] in self?.check(lidClosed: PowerReader.lidClosed()) }
            }
        } else {
            watch?.invalidate()
            watch = nil
        }
    }

    private func check(lidClosed: Bool?) {
        defer { keepWatching() }
        // Holding is only safe when the lock can be sent (Accessibility).
        let canLock = AXIsProcessTrusted()
        let d = LidSessionPolicy.decide(
            keepAwakeOn: keepAwakeOn && canLock, lidClosed: lidClosed, locked: SystemScreen().isLocked(),
            holding: holding, externalDisplay: Self.externalDisplay())
        if d.hold, !holding {
            IOPMAssertionCreateWithName(
                kIOPMAssertionTypePreventUserIdleDisplaySleep as CFString, IOPMAssertionLevel(kIOPMAssertionLevelOn),
                "Latchkey keeps the Mac usable for Claude with the lid closed" as CFString, &assertion)
            report?("Lid closed: the session stays as it is (display-sleep assertion held)", false)
        } else if !d.hold, holding {
            stop()
            if d.lockNow { lock() } else { report?("Display-sleep assertion released", false) }
        }
    }

    private func stop() {
        watch?.invalidate()
        watch = nil
        IOPMAssertionRelease(assertion)
        assertion = 0
    }

    /// Locks, checks that the Mac is locked, and tries once more (security review 2026-11-01).
    private func lock() {
        Self.lockScreen()
        Task { @MainActor in
            for attempt in 1...2 {
                try? await Task.sleep(for: .seconds(1))
                if SystemScreen().isLocked() {
                    report?("Lid opened: the Mac was locked at once", false)
                    return
                }
                if attempt == 1 { Self.lockScreen() }
            }
            report?("Lid opened, but locking the Mac didn't take: it may be unlocked", true)
        }
    }

    /// Quit, Disconnect, uninstall: lets go, and locks a session kept unlocked behind the lid.
    func release() {
        keepAwakeOn = false
        watch?.invalidate()
        watch = nil
        guard holding else { return }
        let behindLid = PowerReader.lidClosed() == true && !SystemScreen().isLocked()
        stop()
        if behindLid { Self.lockScreen() }
    }

    static func externalDisplay() -> Bool {
        var count: UInt32 = 0
        CGGetActiveDisplayList(0, nil, &count)
        var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
        CGGetActiveDisplayList(count, &ids, &count)
        return ids.contains { CGDisplayIsBuiltin($0) == 0 }
    }

    /// Control-Command-Q, macOS's own Lock Screen shortcut (needs Accessibility, which setup asks for).
    static func lockScreen() {
        let source = CGEventSource(stateID: .hidSystemState)
        let q: CGKeyCode = 0x0C
        for down in [true, false] {
            let e = CGEvent(keyboardEventSource: source, virtualKey: q, keyDown: down)
            e?.flags = [.maskCommand, .maskControl]
            e?.post(tap: .cghidEventTap)
        }
    }
}
