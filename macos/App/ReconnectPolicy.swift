import Foundation

/// When to reconnect, and what a close code means (plan D1, agent-protocol.md close codes).
struct ReconnectPolicy: Sendable {
    enum Action: Equatable, Sendable {
        case reconnect  // with backoff
        case signInAgain  // 4001: credential rejected; don't retry automatically
        case revoked  // 4002: delete the local key, show "Disconnected from account"
        case stop  // 4003: a newer connection replaced this one
        case updateRequired  // 4004
    }

    var jitter: @Sendable () -> Double = { Double.random(in: 0.8...1.2) }

    /// Seconds to wait before attempt n (0-based): 1, 2, 4, … capped at 30, with jitter.
    func delay(attempt: Int) -> TimeInterval {
        let base = pow(2, Double(min(attempt, 10)))
        return min(base * jitter(), 30)
    }

    static func action(forClose code: Int) -> Action {
        switch code {
        case 4001: .signInAgain
        case 4002: .revoked
        case 4003: .stop
        case 4004: .updateRequired
        default: .reconnect
        }
    }
}
