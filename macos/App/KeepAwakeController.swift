import Foundation
import IOKit.pwr_mgt
import ServiceManagement

/// Talks to the privileged helper over XPC (plan D7).
@MainActor
final class HelperClient {
    private let service = SMAppService.daemon(plistName: HelperIdentity.plistName)
    private var connection: NSXPCConnection?
    /// Called when the helper went away (it restarts with normal sleep), so keep-awake is re-applied.
    var onInterrupted: (@MainActor () -> Void)?

    var status: SMAppService.Status { service.status }

    /// Registers the helper with launchd; macOS then asks the Owner to approve it once in
    /// System Settings → General → Login Items.
    func registerIfNeeded() {
        guard service.status == .notRegistered || service.status == .notFound else { return }
        do { try service.register() } catch { NSLog("Latchkey: helper registration: \(error)") }
    }

    func openApprovalSettings() { SMAppService.openSystemSettingsLoginItems() }

    private func proxy(onError: @escaping @Sendable (Error) -> Void) -> HelperProtocol? {
        if connection == nil {
            let c = NSXPCConnection(machServiceName: HelperIdentity.machService, options: .privileged)
            c.remoteObjectInterface = NSXPCInterface(with: HelperProtocol.self)
            if let req = CodeSigning.requirement(identifier: HelperIdentity.helperBundleID) {
                c.setCodeSigningRequirement(req)
            }
            c.invalidationHandler = { [weak self] in Task { @MainActor in self?.connection = nil } }
            c.interruptionHandler = { [weak self] in
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

    /// Applies the decision; returns whether the system setting now matches it.
    @discardableResult
    func apply(_ decision: KeepAwake) async -> Bool {
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
            verified = !on
            return verified
        }
        _ = await helper.setSleepDisabled(on)
        // Verify from the kernel itself rather than trusting the reply (FR-031).
        verified = PowerReader.sleepDisabled() == on
        return verified
    }

    /// Restores normal sleep (quit, Disconnect).
    func restore() async { await apply(.offUser) }
}
