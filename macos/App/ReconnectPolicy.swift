import Foundation

/// When to reconnect, and what a close code means (plan D1, agent-protocol.md close codes).
struct ReconnectPolicy: Sendable {
    enum Action: Equatable, Sendable {
        case reconnect  // with backoff
        case signInAgain  // 4001 (any reason but "account suspended"): credential rejected; try again slowly
        case revoked  // 4002: delete the local key, show "Disconnected from account"
        case replaced  // 4003: a newer connection replaced this one; try again soon
        case updateRequired  // 4004: try again slowly
        /// 4001 with the reason "account suspended": keep the pairing, try again slowly (FR-204).
        case suspended
    }

    /// What follows a closed connection: what the app shows instead of "Reconnecting…" (nil:
    /// the usual countdown), and how long until the next attempt (nil: none by itself).
    struct Next: Equatable, Sendable {
        var show: ConnectionStatus?
        var retryAfter: TimeInterval?
    }

    /// The close reason the relay gives a suspended account's Mac (agent-protocol.md).
    static let suspendedReason = "account suspended"
    /// How often a suspended Mac tries again; a wake or a network change tries at once. Also
    /// for a refused sign-in and an app too old: the app never stops trying while it is paired
    /// (Toni, 2026-10-31, FR-206).
    static let suspendedRetry: TimeInterval = 300
    /// After another connection of this Mac replaced this one (4003). Only one copy of the app
    /// runs (FR-207), so the other is gone or about to be.
    static let replacedRetry: TimeInterval = 30

    var jitter: @Sendable () -> Double = { Double.random(in: 0.8...1.2) }

    /// Seconds to wait before attempt n (0-based): 1, 2, 4, … capped at 30, with jitter.
    func delay(attempt: Int) -> TimeInterval {
        let base = pow(2, Double(min(attempt, 10)))
        return min(base * jitter(), 30)
    }

    static func action(forClose code: Int, reason: String? = nil) -> Action {
        switch code {
        case 4001: reason == suspendedReason ? .suspended : .signInAgain
        case 4002: .revoked
        case 4003: .replaced
        case 4004: .updateRequired
        default: .reconnect
        }
    }

    func next(afterClose code: Int, reason: String?, attempt: Int) -> Next {
        switch Self.action(forClose: code, reason: reason) {
        case .reconnect: Next(show: nil, retryAfter: delay(attempt: attempt))
        case .suspended: Next(show: .suspended, retryAfter: Self.suspendedRetry)
        case .signInAgain: Next(show: .signInAgain, retryAfter: Self.suspendedRetry)
        // The pairing's key is deleted: there is nothing left to connect with.
        case .revoked: Next(show: .revoked, retryAfter: nil)
        case .replaced: Next(show: .replaced, retryAfter: Self.replacedRetry)
        case .updateRequired: Next(show: .updateRequired, retryAfter: Self.suspendedRetry)
        }
    }
}

extension ConnectionStatus {
    /// The menu's first line.
    func title(now: Date = Date()) -> String {
        switch self {
        case .notPaired: "Not connected to a relay"
        case .connecting: "Connecting…"
        case .connected: "Connected"
        case .waiting(let until):
            "Reconnecting in \(max(1, Int(until.timeIntervalSince(now).rounded()))) s"
        case .signInAgain: "Sign in again: the relay didn't accept this Mac"
        case .revoked: "Disconnected from your account"
        case .replaced: "Replaced by another connection from this Mac"
        case .updateRequired: "Update Latchkey to connect"
        case .suspended: "This account is suspended on the relay"
        }
    }

    /// A second line saying what to do, where there is something to say.
    var advice: String? {
        switch self {
        case .suspended: "Contact the relay’s operator. Latchkey reconnects by itself when the suspension ends."
        case .replaced: "Latchkey tries again in 30 seconds."
        case .signInAgain, .updateRequired: "Latchkey tries again every 5 minutes."
        default: nil
        }
    }
}
