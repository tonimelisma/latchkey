import Foundation

/// Decides when a change of the Mac's state goes to the relay, so a burst of changes (a charger
/// flapping, a storm of power notifications) can't flood it: an unchanged state isn't sent again,
/// and changes go out at most once per `minInterval`, the last one after the wait. Heartbeats
/// are sent regardless (agent-protocol.md "state").
struct StateFrames {
    static let minInterval: Duration = .seconds(1)

    enum Decision: Equatable {
        case send
        case skip
        case later(Duration)
    }

    private var last: (state: AgentState, at: ContinuousClock.Instant)?

    func decide(_ state: AgentState, at now: ContinuousClock.Instant) -> Decision {
        guard let last else { return .send }
        var same = state
        same.observedAt = last.state.observedAt  // when it was read is not a change
        if same == last.state { return .skip }
        let wait = Self.minInterval - (now - last.at)
        return wait > .zero ? .later(wait) : .send
    }

    mutating func sent(_ state: AgentState, at now: ContinuousClock.Instant) { last = (state, now) }

    /// A new connection starts fresh: its hello carried the state.
    mutating func reset() { last = nil }
}
