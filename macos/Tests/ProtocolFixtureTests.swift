import Foundation
import Testing

@testable import Latchkey

/// The shared fixtures in specs/001-core/contracts/fixtures: the Go relay reads the same files.
enum Fixtures {
    static let dir = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .appendingPathComponent("../../specs/001-core/contracts/fixtures")
        .standardizedFileURL

    static func files(_ kind: String) throws -> [URL] {
        try FileManager.default.contentsOfDirectory(
            at: dir.appendingPathComponent(kind), includingPropertiesForKeys: nil
        )
        .filter { $0.pathExtension == "json" }
        .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }
}

func jsonObject(_ data: Data) throws -> NSObject {
    try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]) as! NSObject
}

@Suite struct ProtocolFixtureTests {
    @Test(arguments: try Fixtures.files("valid"))
    func validFixturesRoundTrip(_ file: URL) throws {
        let data = try Data(contentsOf: file)
        let message = try AgentMessage.decode(data)
        let encoded = try message.encode()
        #expect(try jsonObject(encoded) == jsonObject(data), "\(file.lastPathComponent)")
    }

    @Test func everyMessageTypeHasAFixture() throws {
        var seen = Set<String>()
        for file in try Fixtures.files("valid") {
            seen.insert(try AgentMessage.decode(Data(contentsOf: file)).type)
        }
        #expect(seen == Set(AgentMessage.allTypes))
    }

    @Test(arguments: try Fixtures.files("tolerated"))
    func toleratedFixturesDecode(_ file: URL) throws {
        _ = try AgentMessage.decode(Data(contentsOf: file))
    }

    @Test(arguments: try Fixtures.files("invalid"))
    func invalidFixturesAreRejected(_ file: URL) throws {
        #expect(throws: ProtocolError.self) { try AgentMessage.decode(Data(contentsOf: file)) }
    }

    @Test func helloFieldsDecode() throws {
        let message = try AgentMessage.decode(Data(contentsOf: Fixtures.dir.appendingPathComponent("valid/hello.json")))
        guard case .hello(let hello) = message else { Issue.record("not hello"); return }
        #expect(hello.deviceID == "dev_8f3kq2m7xz")
        #expect(hello.state.batteryPercent == 82)
        #expect(hello.state.lidClosed == true)
        #expect(hello.state.timeZone == "America/Los_Angeles")
        #expect(hello.tools.first?.name == "battery_status")
        #expect(hello.tools.first?.deadlineMS == 5000)
    }

    @Test func unknownTimeZoneEncodesAsNull() throws {
        var state = AgentState.sample
        state.timeZone = nil
        state.lidClosed = nil
        state.timeRemainingMin = nil
        let object = try jsonObject(AgentMessage.state(StateUpdate(state: state)).encode()) as! [String: Any]
        let encodedState = object["state"] as! [String: Any]
        #expect(encodedState["time_zone"] is NSNull)
        #expect(encodedState["lid_closed"] is NSNull)
        #expect(encodedState["time_remaining_min"] is NSNull)
    }
}

extension AgentState {
    static let sample = AgentState(
        batteryPercent: 82, powerSource: .battery, charging: false, timeRemainingMin: 312,
        thermalState: .nominal, lowPowerMode: false, lidClosed: false, timeZone: "Europe/Helsinki",
        keepAwake: .on, observedAt: Date(timeIntervalSince1970: 1_790_000_000))
}
