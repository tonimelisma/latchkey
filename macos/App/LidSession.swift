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

    /// Applies the policy; returns what was done, for the log, or nil when nothing changed.
    func update(keepAwakeOn: Bool, lidClosed: Bool?) -> String? {
        let d = LidSessionPolicy.decide(
            keepAwakeOn: keepAwakeOn, lidClosed: lidClosed, locked: SystemScreen().isLocked(), holding: holding,
            externalDisplay: Self.externalDisplay())
        if d.hold, !holding {
            IOPMAssertionCreateWithName(
                kIOPMAssertionTypePreventUserIdleDisplaySleep as CFString, IOPMAssertionLevel(kIOPMAssertionLevelOn),
                "Latchkey keeps the Mac usable for Claude with the lid closed" as CFString, &assertion)
            return "Lid closed: the session stays as it is (display-sleep assertion held)"
        }
        if !d.hold, holding {
            IOPMAssertionRelease(assertion)
            assertion = 0
            if d.lockNow {
                Self.lockScreen()
                return "Lid opened: the Mac was locked at once"
            }
            return "Display-sleep assertion released"
        }
        return nil
    }

    /// Releases the assertion without locking (quit, Disconnect: macOS's own rules take over).
    func release() {
        guard holding else { return }
        IOPMAssertionRelease(assertion)
        assertion = 0
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
