import Foundation
import Network

/// macOS's Local Network approval (FR-623). Commands Claude runs count as Latchkey's own, so a
/// command that reaches a printer or router would otherwise make macOS ask during use. macOS has
/// no call that reads the approval; a Bonjour search shows it: the search runs when it's
/// allowed and waits with "policy denied" when it isn't. Starting one is also what makes macOS ask.
enum LocalNetwork {
    /// Declared in Info.plist's NSBonjourServices; nothing ever advertises it.
    static let serviceType = "_latchkey-check._tcp"
    /// The last answer, kept in user defaults by `AppModel.checkLocalNetwork`.
    static let defaultsKey = "localNetworkAllowed"
    /// Known not allowed at the last look.
    static var refused: Bool { UserDefaults.standard.object(forKey: defaultsKey) as? Bool == false }

    /// Added to a Shell answer whose output shows a device it couldn't reach (spec 001 FR-625).
    static let hint =
        "[macOS doesn't allow Latchkey to reach devices on the local network (printers, routers, other computers), which is likely why. The Mac's owner can allow Local Network in Latchkey's Settings → Permissions.]"

    /// Output that looks like macOS's Local Network refusal ("No route to host" for a device nearby).
    static func looksRefused(_ output: String) -> Bool {
        let text = output.lowercased()
        return text.contains("no route to host") || text.contains("local network")
    }

    /// True when allowed, false when not (or not asked yet). Waits up to `wait` for an answer,
    /// which covers the Owner answering macOS's question when `wait` is long.
    static func check(wait: Duration = .seconds(2)) async -> Bool {
        // Never from the test host: it's its own app to macOS, and the question lands on the screen.
        guard ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil else { return false }
        let browser = NWBrowser(for: .bonjour(type: serviceType, domain: "local."), using: .tcp)
        let answer = Answer()
        browser.stateUpdateHandler = { @Sendable state in
            switch state {
            case .ready: answer.set(true)
            case .waiting(let error) where denied(error): answer.set(false)
            case .failed: answer.set(false)
            default: break
            }
        }
        browser.start(queue: .global(qos: .utility))
        defer { browser.cancel() }
        let deadline = ContinuousClock.now + wait
        var last: Bool?
        while ContinuousClock.now < deadline {
            last = answer.value ?? last
            if last == true { return true }
            try? await Task.sleep(for: .milliseconds(100))
        }
        return answer.value ?? last ?? false
    }

    /// DNS-SD's "policy denied" (kDNSServiceErr_PolicyDenied): Local Network isn't allowed.
    static func denied(_ error: NWError) -> Bool {
        if case .dns(let code) = error { return code == -65570 }
        return false
    }

    private final class Answer: @unchecked Sendable {
        private let lock = NSLock()
        private var stored: Bool?
        var value: Bool? { lock.withLock { stored } }
        func set(_ v: Bool) { lock.withLock { stored = v } }
    }
}
