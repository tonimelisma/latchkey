import AppKit
import ApplicationServices

/// Bringing an app forward for a step that works only while the app is in front, without getting
/// in the Owner's way (spec 002 FR-179): only after a pause in their typing and mouse, stopped as
/// soon as they type or click, the front given back to the app that had it. Notes' window
/// editing and Messages' group naming use it.
enum Foreground {
    enum Outcome: Equatable {
        /// The work ran in front and succeeded.
        case done
        /// The work ran in front and didn't succeed.
        case failed
        /// The Owner kept typing or using the mouse; nothing was brought forward.
        case ownerBusy
        /// The app couldn't be brought forward.
        case notForward
        /// The Owner typed or clicked while the app was in front: the work was stopped.
        case ownerActed
    }

    /// Runs `work` with `target` in front. `work` gets a check that answers whether the Owner has
    /// used the Mac since the app came forward, to stop between its own steps. The front goes
    /// back to the app that had it, unless the Owner went to another app meanwhile.
    static func run(
        _ target: NSRunningApplication, log: @escaping @Sendable (String, Bool) -> Void,
        _ work: (_ ownerActed: () -> Bool) async -> Bool
    ) async -> Outcome {
        guard await ownerQuiet() else {
            log("the Owner kept using the Mac; \(target.bundleIdentifier ?? "the app") wasn't brought forward", false)
            return .ownerBusy
        }
        let previous = frontApp()
        let since = ContinuousClock.now
        let acted = { idleSeconds() < seconds(ContinuousClock.now - since) }
        var outcome = Outcome.notForward
        var forward = previous?.processIdentifier == target.processIdentifier
        if !forward { forward = await bringForward(target, log: log) }
        if forward {
            outcome = await work(acted) ? .done : .failed
        }
        if acted() {
            log("the Owner used the Mac while \(target.bundleIdentifier ?? "the app") was in front", true)
            outcome = .ownerActed
        }
        if let previous, previous.processIdentifier != target.processIdentifier,
            frontApp()?.processIdentifier == target.processIdentifier
        {
            _ = await bringForward(previous, log: log)
        }
        return outcome
    }

    /// Waits up to 5 s for a 1.5-second pause in the Owner's typing and mouse.
    static func ownerQuiet() async -> Bool {
        for _ in 0..<50 {
            if idleSeconds() >= 1.5 { return true }
            try? await Task.sleep(for: .milliseconds(100))
        }
        return false
    }

    static func seconds(_ d: Duration) -> Double {
        Double(d.components.seconds) + Double(d.components.attoseconds) / 1e18
    }

    /// Seconds since the Owner last typed, clicked, scrolled, or moved the mouse. Latchkey's
    /// own steps (Accessibility, activating apps, key presses sent to one app) aren't counted:
    /// events posted to a process don't reach the session's input state.
    static func idleSeconds() -> Double {
        let kinds: [CGEventType] = [
            .keyDown, .flagsChanged, .leftMouseDown, .rightMouseDown, .otherMouseDown, .mouseMoved,
            .leftMouseDragged, .scrollWheel,
        ]
        return kinds.map { CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: $0) }.min()
            ?? .infinity
    }

    /// Brings an app to the front and answers whether it is there. macOS may refuse a plain
    /// activate from a menu bar app in the background (the installed app's was, 2026-11-06);
    /// opening the app through LaunchServices is the fallback. Whether it's in front is asked of
    /// the app itself and of the screen: NSWorkspace's frontmost app reads stale (2026-11-05).
    static func bringForward(_ target: NSRunningApplication, log: @Sendable (String, Bool) -> Void) async -> Bool {
        let app = AXUIElementCreateApplication(target.processIdentifier)
        func isFront() async -> Bool {
            // Up to 2 s. Both the app and the system must agree: Claude's app said it was in
            // front while Notes still was (2026-11-06).
            for _ in 0..<40 {
                var v: AnyObject?
                if AXUIElementCopyAttributeValue(app, kAXFrontmostAttribute as CFString, &v) == .success,
                    (v as? NSNumber)?.boolValue == true,
                    frontApp()?.processIdentifier == target.processIdentifier
                {
                    return true
                }
                try? await Task.sleep(for: .milliseconds(50))
            }
            return false
        }
        let name = target.bundleIdentifier ?? "an app"
        target.activate()
        if await isFront() {
            log("brought \(name) forward with activate", false)
            return true
        }
        // `open -b`, as computer_act's open_app does: a program of its own asks LaunchServices,
        // which brought Notes forward when the installed app's activate and its
        // NSWorkspace.openApplication were both refused (2026-11-06).
        if let id = target.bundleIdentifier {
            await openByID(id)
            if await isFront() {
                log("brought \(name) forward with open -b", false)
                return true
            }
        }
        log("couldn't bring \(name) forward", true)
        return false
    }

    /// The app in front: the owner of the topmost normal window on screen, which is what the
    /// Owner sees. Accessibility's focused app failed (-25204) while Claude's app was in front,
    /// and the fallback, NSWorkspace, reads stale in the installed app, so Notes taking the
    /// front again went unseen and stayed (2026-11-06). Window owners need no permission.
    static func frontApp() -> NSRunningApplication? {
        if let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
            as? [[String: Any]],
            let top = list.first(where: {
                ($0[kCGWindowLayer as String] as? Int) == 0 && (($0[kCGWindowAlpha as String] as? Double) ?? 1) > 0
            }),
            let pid = top[kCGWindowOwnerPID as String] as? pid_t,
            let app = NSRunningApplication(processIdentifier: pid)
        {
            return app
        }
        var v: AnyObject?
        guard
            AXUIElementCopyAttributeValue(
                AXUIElementCreateSystemWide(), kAXFocusedApplicationAttribute as CFString, &v) == .success,
            let v, CFGetTypeID(v) == AXUIElementGetTypeID()
        else { return NSWorkspace.shared.frontmostApplication }
        var pid: pid_t = 0
        AXUIElementGetPid(v as! AXUIElement, &pid)
        return NSRunningApplication(processIdentifier: pid) ?? NSWorkspace.shared.frontmostApplication
    }

    /// Runs `/usr/bin/open -b <id>` and waits up to 5 s for it, without blocking a thread.
    static func openByID(_ id: String) async {
        let p = Process()
        p.executableURL = URL(filePath: "/usr/bin/open")
        p.arguments = ["-b", id]
        await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
            let once = OnceFlag()
            p.terminationHandler = { _ in if once.claim() { done.resume() } }
            do { try p.run() } catch {
                if once.claim() { done.resume() }
                return
            }
            DispatchQueue.global().asyncAfter(deadline: .now() + 5) {
                if once.claim() {
                    p.terminate()
                    done.resume()
                }
            }
        }
    }

    /// Lets exactly one of several callbacks go on.
    final class OnceFlag: @unchecked Sendable {
        private let lock = NSLock()
        private var claimed = false
        func claim() -> Bool {
            lock.lock()
            defer { lock.unlock() }
            if claimed { return false }
            claimed = true
            return true
        }
    }
}
