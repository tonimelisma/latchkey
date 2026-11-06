import Foundation
import Testing

@testable import Latchkey

/// What the app sends stays well inside the relay's limits on a Mac's connection (256 tools,
/// 512 KiB of tool list, about 5 frames a second with bursts of 60; security review 2026-10-25).
@Suite struct StateFramesTests {
    static func state(_ percent: Int, observed: TimeInterval = 0) -> AgentState {
        AgentState(
            batteryPercent: percent, powerSource: .battery, charging: false, timeRemainingMin: nil,
            thermalState: .nominal, lowPowerMode: false, lidClosed: false, timeZone: "UTC", keepAwake: .on,
            observedAt: Date(timeIntervalSince1970: observed))
    }

    @Test func aBurstOfChangesBecomesOneFrameASecond() {
        var frames = StateFrames()
        let t0 = ContinuousClock.now
        #expect(frames.decide(Self.state(80), at: t0) == .send, "the first change goes at once")
        frames.sent(Self.state(80), at: t0)
        #expect(
            frames.decide(Self.state(80, observed: 5), at: t0 + .seconds(30)) == .skip,
            "the same state read again later is not a change")
        #expect(
            frames.decide(Self.state(79), at: t0 + .milliseconds(200)) == .later(.milliseconds(800)),
            "a change right after another waits out the second")
        #expect(frames.decide(Self.state(79), at: t0 + .seconds(1)) == .send)
        frames.sent(Self.state(79), at: t0 + .seconds(1))
        #expect(frames.decide(Self.state(80), at: t0 + .seconds(3)) == .send, "changing back is a change")
        frames.reset()
        #expect(frames.decide(Self.state(79), at: t0 + .seconds(1)) == .send, "a new connection starts fresh")
    }

    /// Sixty changes in a second would use up the relay's whole burst allowance; the app sends
    /// one of them now and the latest a second later.
    @Test func sixtyChangesInASecondSendOneFrame() {
        var frames = StateFrames()
        let t0 = ContinuousClock.now
        var sent = 0
        for i in 0..<60 {
            let now = t0 + .milliseconds(i * 16)
            if frames.decide(Self.state(i), at: now) == .send {
                frames.sent(Self.state(i), at: now)
                sent += 1
            }
        }
        #expect(sent == 1)
    }

    @MainActor @Test func theToolListIsFarInsideTheRelaysLimits() throws {
        let registry = CapabilityRegistry(
            capabilities: AppModel.makeCapabilities(), levels: CapabilityRegistry.defaultLevels)
        let frame = try AgentMessage.tools(ToolsUpdate(tools: registry.tools)).encode()
        #expect(registry.tools.count <= 33, "the relay allows 256")
        #expect(frame.count < 64 * 1024, "the relay allows 512 KiB; this is \(frame.count) bytes")
    }
}
