import Foundation
import Testing

@testable import Latchkey

/// Runs only under relay/cmd/maccheck, which starts a relay, pairs through headless Chrome, and
/// drives this test through a control file: the real app connection code against a real relay.
@Suite(.enabled(if: ProcessInfo.processInfo.environment["LATCHKEY_LIVE_RELAY"] != nil))
struct LiveRelayTests {
    /// A test-only capability: the live battery reading, compared with pmset by relay/cmd/maccheck.
    static let testBattery = Capability(
        id: "test", title: "Test", summary: "",
        readTools: [
            ToolEntry(
                tool: Tool.make("battery_status", title: "Battery", description: "Live battery.", readOnly: true),
                handler: { _ in
                    let p = PowerReader.read()
                    return .data(
                        .object([
                            "battery_percent": .number(Double(p.batteryPercent)), "charging": .bool(p.charging),
                            "power_source": .string(p.powerSource.rawValue),
                        ]))
                })
        ], writeTools: [])

    @Test(.timeLimit(.minutes(5))) func liveRelay() async throws {
        let env = ProcessInfo.processInfo.environment
        let relay = try #require(env["LATCHKEY_LIVE_RELAY"].flatMap(URL.init(string:)))
        let code = try #require(env["LATCHKEY_LIVE_CODE"])
        let control = URL(fileURLWithPath: try #require(env["LATCHKEY_LIVE_CONTROL"]))

        let email = try await PairingFlow.preview(relay: relay, code: code)
        #expect(email.contains("@"), "the relay names the code's account without using the code (FR-054)")
        let identity = try await PairingFlow.exchange(relay: relay, code: code, macName: "Live Test Mac", save: false)
        let registry = Locked(
            CapabilityRegistry(capabilities: [Self.testBattery], levels: ["test": .readOnly]))
        let statuses = Locked([ConnectionStatus]())
        let hooks = ConnectionHooks(
            state: { PowerReader.read().agentState(keepAwake: .on) },
            tools: { registry.value.tools },
            call: { call in await registry.value.call(tool: call.tool, arguments: call.arguments) },
            status: { s in statuses.mutate { $0.append(s) } },
            notice: { _ in })
        let connection = RelayConnection(identity: identity, hooks: hooks)
        await connection.start()

        var handled = Set<String>()
        let deadline = Date().addingTimeInterval(280)
        while Date() < deadline {
            let commands = (try? String(contentsOf: control, encoding: .utf8)) ?? ""
            for line in commands.split(separator: "\n").map(String.init) where !handled.contains(line) {
                handled.insert(line)
                switch line {
                case "tools-off":
                    registry.mutate { $0.setLevel("test", .off) }
                    await connection.sendTools()
                case "reconnect-now", "wake", "wake-again":
                    await connection.reconnectNow()
                case "expect-suspended":
                    // FR-204: the relay's 4001 "account suspended" as URLSession reports it.
                    #expect(statuses.value.last == .suspended, "shown as suspended: \(statuses.value.suffix(3))")
                    #expect(!statuses.value.contains(.signInAgain), "never as a failed sign-in")
                case "done":
                    await connection.stop(goodbye: .userQuit)
                    #expect(statuses.value.contains(.connected))
                    return
                default:
                    break
                }
            }
            try await Task.sleep(for: .milliseconds(100))
        }
        Issue.record("the orchestrator never finished")
    }
}
