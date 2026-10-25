import Foundation
import Testing

@testable import Latchkey

/// The shared fixtures in specs/001-core/contracts/fixtures: the Go relay reads the same files.
enum Fixtures {
    static let dir = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .appendingPathComponent("../../specs/001-core/contracts/fixtures")
        .standardizedFileURL

    /// The app's own copies of fixtures not yet in the shared folder (FR-190 to FR-192: `clients`,
    /// `revoke_client`, hello with `features`). A file of the same name in the shared folder wins,
    /// so these can be deleted once the shared ones exist.
    static let localDir = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .appendingPathComponent("Fixtures")
        .standardizedFileURL

    static func files(_ kind: String) throws -> [URL] {
        var byName: [String: URL] = [:]
        for base in [localDir, dir] {
            let folder = base.appendingPathComponent(kind)
            guard FileManager.default.fileExists(atPath: folder.path) else { continue }
            for file in try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)
            where file.pathExtension == "json" {
                byName[file.lastPathComponent] = file
            }
        }
        return byName.values.sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    static func file(_ path: String) -> URL {
        let shared = dir.appendingPathComponent(path)
        return FileManager.default.fileExists(atPath: shared.path) ? shared : localDir.appendingPathComponent(path)
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
