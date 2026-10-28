import Foundation
import IOKit.pwr_mgt
import ServiceManagement

/// Talks to the privileged helper over XPC (plan D7).
@MainActor
final class HelperClient {
    private let service = SMAppService.daemon(plistName: AppIdentity.current.helperPlistName)
    private var connection: NSXPCConnection?
    /// Called when the helper went away (it restarts with normal sleep), so keep-awake is re-applied.
    var onInterrupted: (@MainActor () -> Void)?

    var status: SMAppService.Status { service.status }

    /// Registers the helper with launchd; macOS then asks the Owner to approve it once in
    /// System Settings → General → Login Items.
    func registerIfNeeded() {
        guard service.status == .notRegistered || service.status == .notFound else { return }
        do { try service.register() } catch {
            EventLog.shared.record(.helper, "Couldn't register the helper: \(error.localizedDescription)", error: true)
        }
    }

    func openApprovalSettings() { SMAppService.openSystemSettingsLoginItems() }

    private func proxy(onError: @escaping @Sendable (Error) -> Void) -> HelperProtocol? {
        if connection == nil {
            guard
                let c = Self.makeConnection(
                    requirement: CodeSigning.requirement(identifier: AppIdentity.current.helperBundleID))
            else { return nil }
            // XPC calls these on its own queue: @Sendable keeps them free of main-actor isolation.
            c.invalidationHandler = { @Sendable [weak self] in Task { @MainActor in self?.connection = nil } }
            c.interruptionHandler = { @Sendable [weak self] in
                Task { @MainActor in
                    self?.connection = nil
                    self?.onInterrupted?()
                }
            }
            c.resume()
            connection = c
        }
        return connection?.remoteObjectProxyWithErrorHandler(onError) as? HelperProtocol
    }

    /// A connection that only the genuine helper can answer. Without a code-signing requirement
    /// (a build with no team) there is no connection at all: keep-awake reports the helper as
    /// unavailable rather than trusting whatever answers on the service name.
    nonisolated static func makeConnection(requirement: String?) -> NSXPCConnection? {
        guard let requirement else { return nil }
        let c = NSXPCConnection(machServiceName: AppIdentity.current.machService, options: .privileged)
        c.remoteObjectInterface = NSXPCInterface(with: HelperProtocol.self)
        c.setCodeSigningRequirement(requirement)
        return c
    }

    /// Sets SleepDisabled and returns the value read back, or nil if the helper didn't answer
    /// within 5 seconds.
    func setSleepDisabled(_ on: Bool) async -> Bool? {
        await withCheckedContinuation { (c: CheckedContinuation<Bool?, Never>) in
            let once = Once(c)
            guard let p = proxy(onError: { _ in once.resume(nil) }) else { once.resume(nil); return }
            p.setSleepDisabled(on) { now, _ in once.resume(now) }
            Task {
                try? await Task.sleep(for: .seconds(5)); once.resume(nil)
            }
        }
    }

    func readSleepDisabled() async -> Bool? {
        await withCheckedContinuation { (c: CheckedContinuation<Bool?, Never>) in
            let once = Once(c)
            guard let p = proxy(onError: { _ in once.resume(nil) }) else { once.resume(nil); return }
            p.readSleepDisabled { once.resume($0) }
            Task {
                try? await Task.sleep(for: .seconds(5)); once.resume(nil)
            }
        }
    }
}

/// Resumes a continuation at most once (XPC reply, error, or timeout, whichever comes first).
final class Once<T: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<T, Never>?
    init(_ c: CheckedContinuation<T, Never>) { continuation = c }
    func resume(_ value: T) {
        lock.lock()
        let c = continuation
        continuation = nil
        lock.unlock()
        c?.resume(returning: value)
    }
}

/// Keeps the Mac awake: a power assertion for the lid-open case, and the helper's
/// SleepDisabled for the lid-closed case. Applies and verifies on every call (FR-031).
@MainActor
final class KeepAwakeController {
    let helper = HelperClient()
    private var assertion: IOPMAssertionID = 0
    private(set) var verified = false

    var helperApproved: Bool { helper.status == .enabled }

    /// The problems of the last `apply`, so each is an event once until it goes away (FR-633);
    /// macOS's log gets every one (FR-620).
    private var problems: [String] = []
    private var lastProblems: [String] = []

    private func problem(_ text: String) {
        Diagnostics.keepAwake.error("\(text, privacy: .public)")
        problems.append(text)
    }

    private func recordProblems() {
        defer {
            lastProblems = problems
            problems = []
        }
        guard problems != lastProblems else { return }
        for p in problems where !lastProblems.contains(p) {
            EventLog.shared.record(.helper, p, error: true, systemLog: false)
        }
    }

    /// Applies the decision; returns whether the system setting now matches it.
    @discardableResult
    func apply(_ decision: KeepAwake) async -> Bool {
        let ok = await applyOnce(decision)
        recordProblems()
        return ok
    }

    private func applyOnce(_ decision: KeepAwake) async -> Bool {
        let on = decision == .on
        if on, assertion == 0 {
            IOPMAssertionCreateWithName(
                kIOPMAssertionTypePreventUserIdleSystemSleep as CFString, IOPMAssertionLevel(kIOPMAssertionLevelOn),
                "Latchkey keeps this Mac reachable for Claude" as CFString, &assertion)
        } else if !on, assertion != 0 {
            IOPMAssertionRelease(assertion)
            assertion = 0
        }
        guard helperApproved else {
            if on {
                problem("Helper not approved (\(String(describing: helper.status)))")
            }
            verified = !on
            return verified
        }
        // No answer: an old helper may have just ended itself after an install, and launchd
        // starts the new one on the next connection, so try once more.
        if await helper.setSleepDisabled(on) == nil {
            problem("Helper didn't answer setting sleep disabled to \(on); trying once more")
            try? await Task.sleep(for: .seconds(1))
            if await helper.setSleepDisabled(on) == nil {
                problem("Helper didn't answer the second time either")
            }
        }
        // Verify from the kernel itself rather than trusting the reply (FR-031).
        let now = PowerReader.sleepDisabled()
        verified = now == on
        if !verified {
            problem("SleepDisabled is \(now.map { "\($0)" } ?? "unknown"), wanted \(on)")
        }
        return verified
    }

    /// Restores normal sleep (quit, Disconnect).
    func restore() async { await apply(.offUser) }
}
