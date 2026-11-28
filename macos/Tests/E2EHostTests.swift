import Foundation
import Testing

@testable import Latchkey

/// Runs only under `relay/cmd/e2e mac` (spec 015 FR-1501, research.md decision 4): the app's real
/// capabilities (the same tools, descriptions and handlers as the installed app,
/// `AppModel.makeCapabilities()`) served through the real `RelayConnection` to a private relay
/// on this Mac, driven through a control file. On GitHub's Mac runner, a throwaway machine; never
/// on anyone's own Mac by hand (it serves that Mac's real files and shell).
@Suite(.enabled(if: ProcessInfo.processInfo.environment["LATCHKEY_E2E_RELAY"] != nil))
struct E2EHostTests {
    /// On the main actor: the app makes its capabilities there.
    @MainActor @Test(.timeLimit(.minutes(20))) func serveRealCapabilities() async throws {
        let env = ProcessInfo.processInfo.environment
        let relay = try #require(env["LATCHKEY_E2E_RELAY"].flatMap(URL.init(string:)))
        let code = try #require(env["LATCHKEY_E2E_CODE"])
        let control = URL(fileURLWithPath: try #require(env["LATCHKEY_E2E_CONTROL"]))

        let identity = try await PairingFlow.exchange(relay: relay, code: code, macName: "E2E Mac", save: false)
        let log = LatchkeyLog.entry(
            source: nil, fallback: LatchkeyLog.memory(EventLog.shared), version: AppModel.version)
        let registry = Locked(
            CapabilityRegistry(
                capabilities: AppModel.makeCapabilities(), levels: CapabilityRegistry.defaultLevels, always: [log]))
        let statuses = Locked([ConnectionStatus]())
        let hooks = ConnectionHooks(
            state: { PowerReader.read().agentState(keepAwake: .on) },
            tools: { registry.value.tools },
            call: { call in await registry.value.call(tool: call.tool, arguments: call.arguments) },
            status: { s in statuses.mutate { $0.append(s) } },
            notice: { _ in })
        let connection = RelayConnection(identity: identity, hooks: hooks)
        await connection.start()

        // Commands, one per line: "off <capability>", "on <capability>", "done".
        var handled = Set<String>()
        let deadline = Date().addingTimeInterval(19 * 60)
        while Date() < deadline {
            let commands = (try? String(contentsOf: control, encoding: .utf8)) ?? ""
            for line in commands.split(separator: "\n").map(String.init) where !handled.contains(line) {
                handled.insert(line)
                let words = line.split(separator: " ").map(String.init)
                switch words.first {
                case "off" where words.count == 2:
                    registry.mutate { $0.setLevel(words[1], .off) }
                    await connection.sendTools()
                case "on" where words.count == 2:
                    registry.mutate { $0.setLevel(words[1], .readWrite) }
                    await connection.sendTools()
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

// The requirements this file's tests cite (docs/requirements/; script/process-check).
// Validates: FR-1501
