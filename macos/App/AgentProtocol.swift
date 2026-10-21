import Foundation

// Messages of the agent protocol, v1 (specs/001-core/contracts/agent-protocol.md).

enum ProtocolError: Error, Equatable {
    case violation(String)  // the relay closes with 4005 for these
}

enum PowerSource: String, Codable, Sendable { case battery, ac, ups, unknown }
enum ThermalLevel: String, Codable, Sendable { case nominal, fair, serious, critical }

enum KeepAwake: String, Codable, Sendable {
    case on
    case offUser = "off_user"
    case offLowBattery = "off_low_battery"
    case offTooHot = "off_too_hot"
    case offHelperUnavailable = "off_helper_unavailable"
}

enum GoodbyeReason: String, Codable, Sendable {
    case lowBattery = "low_battery"
    case tooHot = "too_hot"
    case userQuit = "user_quit"
    case systemSleep = "system_sleep"
    case systemShutdown = "system_shutdown"
    case userDisconnected = "user_disconnected"
}

/// The Mac's condition, sent in hello, state, and goodbye. Unknown values are sent as null.
struct AgentState: Codable, Equatable, Sendable {
    var batteryPercent: Int
    var powerSource: PowerSource
    var charging: Bool
    var timeRemainingMin: Int?
    var thermalState: ThermalLevel
    var lowPowerMode: Bool
    var lidClosed: Bool?
    var timeZone: String?
    var keepAwake: KeepAwake
    var observedAt: Date

    enum CodingKeys: String, CodingKey {
        case batteryPercent = "battery_percent", powerSource = "power_source", charging
        case timeRemainingMin = "time_remaining_min", thermalState = "thermal_state"
        case lowPowerMode = "low_power_mode", lidClosed = "lid_closed", timeZone = "time_zone"
        case keepAwake = "keep_awake", observedAt = "observed_at"
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(batteryPercent, forKey: .batteryPercent)
        try c.encode(powerSource, forKey: .powerSource)
        try c.encode(charging, forKey: .charging)
        try c.encode(timeRemainingMin, forKey: .timeRemainingMin)  // null when nil
        try c.encode(thermalState, forKey: .thermalState)
        try c.encode(lowPowerMode, forKey: .lowPowerMode)
        try c.encode(lidClosed, forKey: .lidClosed)
        try c.encode(timeZone, forKey: .timeZone)
        try c.encode(keepAwake, forKey: .keepAwake)
        try c.encode(observedAt, forKey: .observedAt)
    }
}

struct ToolAnnotations: Codable, Equatable, Sendable {
    var title: String?
    var readOnlyHint: Bool?
    var destructiveHint: Bool?
    var idempotentHint: Bool?
    var openWorldHint: Bool?
}

/// An MCP Tool, plus the latchkey/deadline_ms extension in _meta.
struct Tool: Codable, Equatable, Sendable {
    var name: String
    var title: String?
    var description: String?
    var inputSchema: JSONValue
    var outputSchema: JSONValue?
    var annotations: ToolAnnotations?
    var meta: [String: JSONValue]?

    enum CodingKeys: String, CodingKey {
        case name, title, description, inputSchema, outputSchema, annotations, meta = "_meta"
    }

    static let deadlineKey = "latchkey/deadline_ms"

    var deadlineMS: Int? {
        if case .number(let n) = meta?[Self.deadlineKey] { return Int(n) }
        return nil
    }
}

struct Challenge: Codable, Sendable {
    var nonce: String; var serverTime: Date
    enum CodingKeys: String, CodingKey { case nonce, serverTime = "server_time" }
}

struct Hello: Codable, Sendable {
    var deviceID: String
    var signature: String
    var appVersion: String
    var osVersion: String
    var tools: [Tool]
    var state: AgentState
    enum CodingKeys: String, CodingKey {
        case deviceID = "device_id", signature, appVersion = "app_version", osVersion = "os_version", tools, state
    }
}

struct Welcome: Codable, Sendable {
    var heartbeatIntervalS: Int; var serverTime: Date
    enum CodingKeys: String, CodingKey { case heartbeatIntervalS = "heartbeat_interval_s", serverTime = "server_time" }
}

struct StateUpdate: Codable, Sendable { var state: AgentState }
struct ToolsUpdate: Codable, Sendable { var tools: [Tool] }

struct Progress: Codable, Sendable {
    var id: String
    var progress: Double
    var total: Double?
    var message: String?
}

struct CallResult: Codable, Sendable {
    var id: String
    var content: JSONValue
    var structuredContent: JSONValue?
    var isError: Bool
    enum CodingKeys: String, CodingKey {
        case id, content, structuredContent = "structured_content", isError = "is_error"
    }
}

struct Goodbye: Codable, Sendable { var reason: GoodbyeReason; var state: AgentState }

struct Call: Codable, Sendable {
    var id: String
    var tool: String
    var arguments: JSONValue
    var deadlineMS: Int
    enum CodingKeys: String, CodingKey { case id, tool, arguments, deadlineMS = "deadline_ms" }
}

struct Cancel: Codable, Sendable { var id: String; var reason: String }
struct Notice: Codable, Sendable { var kind: String; var at: Date }

enum AgentMessage: Sendable {
    case challenge(Challenge), hello(Hello), welcome(Welcome), state(StateUpdate), tools(ToolsUpdate)
    case progress(Progress), result(CallResult), goodbye(Goodbye), call(Call), cancel(Cancel), notice(Notice)

    static let allTypes = [
        "challenge", "hello", "welcome", "state", "tools", "progress", "result", "goodbye", "call", "cancel", "notice",
    ]

    var type: String {
        switch self {
        case .challenge: "challenge"
        case .hello: "hello"
        case .welcome: "welcome"
        case .state: "state"
        case .tools: "tools"
        case .progress: "progress"
        case .result: "result"
        case .goodbye: "goodbye"
        case .call: "call"
        case .cancel: "cancel"
        case .notice: "notice"
        }
    }

    private struct Envelope: Decodable { var type: String? }
    private enum TypeKey: String, CodingKey { case type }

    static func decode(_ data: Data) throws -> AgentMessage {
        let dec = Self.decoder
        guard let env = try? dec.decode(Envelope.self, from: data), let type = env.type else {
            throw ProtocolError.violation("not a message object")
        }
        do {
            switch type {
            case "challenge": return .challenge(try dec.decode(Challenge.self, from: data))
            case "hello":
                let h = try dec.decode(Hello.self, from: data)
                try validate(tools: h.tools)
                return .hello(h)
            case "welcome": return .welcome(try dec.decode(Welcome.self, from: data))
            case "state": return .state(try dec.decode(StateUpdate.self, from: data))
            case "tools":
                let t = try dec.decode(ToolsUpdate.self, from: data)
                try validate(tools: t.tools)
                return .tools(t)
            case "progress": return .progress(try dec.decode(Progress.self, from: data))
            case "result": return .result(try dec.decode(CallResult.self, from: data))
            case "goodbye": return .goodbye(try dec.decode(Goodbye.self, from: data))
            case "call": return .call(try dec.decode(Call.self, from: data))
            case "cancel": return .cancel(try dec.decode(Cancel.self, from: data))
            case "notice": return .notice(try dec.decode(Notice.self, from: data))
            default: throw ProtocolError.violation("unknown message type \(type)")
            }
        } catch let e as ProtocolError {
            throw e
        } catch {
            throw ProtocolError.violation("\(type): \(error)")
        }
    }

    func encode() throws -> Data {
        let enc = Self.encoder
        let body: Data
        switch self {
        case .challenge(let m): body = try enc.encode(m)
        case .hello(let m): body = try enc.encode(m)
        case .welcome(let m): body = try enc.encode(m)
        case .state(let m): body = try enc.encode(m)
        case .tools(let m): body = try enc.encode(m)
        case .progress(let m): body = try enc.encode(m)
        case .result(let m): body = try enc.encode(m)
        case .goodbye(let m): body = try enc.encode(m)
        case .call(let m): body = try enc.encode(m)
        case .cancel(let m): body = try enc.encode(m)
        case .notice(let m): body = try enc.encode(m)
        }
        guard var object = try JSONSerialization.jsonObject(with: body) as? [String: Any] else {
            throw ProtocolError.violation("message did not encode as an object")
        }
        object["type"] = type
        return try JSONSerialization.data(withJSONObject: object, options: [.withoutEscapingSlashes])
    }

    /// Same rules as the relay: valid unique names, none reserved, object input and output schemas.
    static func validate(tools: [Tool]) throws {
        var seen = Set<String>()
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_.-")
        for t in tools {
            guard !t.name.isEmpty, t.name.count <= 128, t.name.unicodeScalars.allSatisfy(allowed.contains) else {
                throw ProtocolError.violation("invalid tool name")
            }
            guard t.name != "laptop_status" else { throw ProtocolError.violation("reserved tool name") }
            guard seen.insert(t.name).inserted else { throw ProtocolError.violation("duplicate tool \(t.name)") }
            guard t.inputSchema["type"] == .string("object") else {
                throw ProtocolError.violation("inputSchema must be an object")
            }
            if let out = t.outputSchema, out["type"] != .string("object") {
                throw ProtocolError.violation("outputSchema must be an object")
            }
        }
    }

    static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        e.outputFormatting = [.withoutEscapingSlashes]
        return e
    }()

    static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .custom { decoder in
            let s = try decoder.singleValueContainer().decode(String.self)
            let plain = ISO8601DateFormatter()
            let fractional = ISO8601DateFormatter()
            fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            if let date = plain.date(from: s) ?? fractional.date(from: s) { return date }
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "bad date \(s)"))
        }
        return d
    }()
}
