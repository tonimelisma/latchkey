import AppKit

/// Only one copy of the app runs (FR-207, plan D24). A second copy, started by hand or by another
/// program, took over the relay connection on 2026-10-31 and then quit, leaving the Mac offline.
enum SingleCopy {
    /// Other running copies of this app (same bundle identifier), by process id.
    static func others() -> [pid_t] {
        guard let id = Bundle.main.bundleIdentifier else { return [] }
        return NSRunningApplication.runningApplications(withBundleIdentifier: id)
            .filter { $0.processIdentifier != getpid() && !$0.isTerminated }
            .map(\.processIdentifier)
    }

    /// True when another copy is still running after `wait`. A copy handing over to this one (an
    /// update replacing the app) quits within it.
    static func anotherStays(wait: Duration = .seconds(10), others: () -> [pid_t] = others) async -> Bool {
        let deadline = ContinuousClock.now + wait
        while !others().isEmpty {
            if ContinuousClock.now >= deadline { return true }
            try? await Task.sleep(for: .milliseconds(100))
        }
        return false
    }
}
