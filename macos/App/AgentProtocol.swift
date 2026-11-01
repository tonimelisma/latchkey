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
    /// A Linux server's uptime (spec 010); a Mac never sends it, but the shared fixtures carry it.
    var uptimeS: Int64? = nil
    var observedAt: Date

    enum CodingKeys: String, CodingKey {
        case batteryPercent = "battery_percent", powerSource = "power_source", charging
        case timeRemainingMin = "time_remaining_min", thermalState = "thermal_state"
        case lowPowerMode = "low_power_mode", lidClosed = "lid_closed", timeZone = "time_zone"
        case keepAwake = "keep_awake", uptimeS = "uptime_s", observedAt = "observed_at"
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
        try c.encodeIfPresent(uptimeS, forKey: .uptimeS)  // left out when nil
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
        if case .number(let n) = meta?[Self.deadlineKey], n.isFinite { return Int(exactly: n.rounded()) }
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
    /// Optional things this app understands; a relay that doesn't know the field ignores it.
    var features: [String]?
    /// "mac" for this app; a Linux server sends "linux" (spec 010).
    var kind: String?
    /// The name the Mac asks to be shown by to Claude; the relay keeps it unique (spec 010 FR-1002).
    var name: String?
    enum CodingKeys: String, CodingKey {
        case deviceID = "device_id", signature, appVersion = "app_version", osVersion = "os_version", tools, state
        case features, kind, name
    }

    /// `clients`: send the list of Claude apps with access, and keep it current (FR-190, FR-192).
    /// `audit`: answer `audit_request` with this Mac's audit (FR-634).
    static let supportedFeatures = ["clients", "audit"]

    /// The hello this app sends: always with the features it supports, its kind, and its name.
    static func make(
        deviceID: String, signature: String, appVersion: String, osVersion: String, tools: [Tool], state: AgentState,
        name: String? = nil
    ) -> Hello {
        Hello(
            deviceID: deviceID, signature: signature, appVersion: appVersion, osVersion: osVersion, tools: tools,
            state: state, features: supportedFeatures, kind: "mac", name: name)
    }
}

struct Welcome: Codable, Sendable {
    var heartbeatIntervalS: Int; var serverTime: Date
    /// The name the relay kept for this Mac, when the hello asked for one (spec 010 FR-1002).
    var name: String?
    enum CodingKeys: String, CodingKey {
        case heartbeatIntervalS = "heartbeat_interval_s", serverTime = "server_time", name
    }
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
    /// The Claude app that made the call, as the relay records it (FR-637); nil or "" when the
    /// relay doesn't know or is older. Text from the network: shown with `Text(verbatim:)`.
    var client: String?
    enum CodingKeys: String, CodingKey { case id, tool, arguments, deadlineMS = "deadline_ms", client }
}

struct Cancel: Codable, Sendable { var id: String; var reason: String }
struct Notice: Codable, Sendable {
    var kind: String
    var at: Date
    /// For `client_authorized`: the client's name.
    var client: String?
}

/// One approval the Owner gave on the relay's Allow page that still works (FR-190). `name` and
/// `host` are text from the network: shown as plain text only (see `ClientAccess.swift`).
struct ClientEntry: Codable, Equatable, Sendable, Identifiable {
    var id: String
    var name: String
    var host: String
    /// A host, or `thisComputer` for a program that signed in on a computer (Claude Code).
    var redirect: String
    var approvedAt: Date
    var lastUsedAt: Date?

    static let thisComputer = "this computer"
    static let maxIDLength = 64
    static let maxEntries = 50

    enum CodingKeys: String, CodingKey {
        case id, name, host, redirect, approvedAt = "approved_at", lastUsedAt = "last_used_at"
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(name, forKey: .name)
        try c.encode(host, forKey: .host)
        try c.encode(redirect, forKey: .redirect)
        try c.encode(approvedAt, forKey: .approvedAt)
        try c.encode(lastUsedAt, forKey: .lastUsedAt)  // null when never used
    }

    /// 1 to 64 characters of A-Z, a-z, 0-9, "_" and "-".
    static func isValid(id: String) -> Bool {
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_-")
        return !id.isEmpty && id.unicodeScalars.count <= maxIDLength && id.unicodeScalars.allSatisfy(allowed.contains)
    }
}

/// Relay → app: the full list, newest approval first; replaces the one before (FR-192).
struct ClientsUpdate: Codable, Equatable, Sendable { var clients: [ClientEntry] }

/// App → relay: remove this approval (FR-191). The relay answers with the new `clients` list.
struct RevokeClient: Codable, Equatable, Sendable { var id: String }

/// App → relay: a page of the relay's audit of this Mac (FR-634). `since` is in milliseconds
/// since 1970, inclusive; `limit` 1 to 1000.
struct AuditRequest: Codable, Equatable, Sendable {
    var id: String
    var since: Int64
    var limit: Int
}

enum AuditOutcome: String, Codable, Sendable {
    case ok, error, timeout
    /// The call never reached the Mac: not expected in its log.
    case offline
}

/// One row of the relay's audit: metadata only.
struct AuditEntry: Codable, Equatable, Sendable {
    /// "" for a call from before call ids (FR-632).
    var callID: String
    /// Milliseconds since 1970.
    var at: Int64
    var tool: String
    var outcome: AuditOutcome
    var durationMS: Int64

    enum CodingKeys: String, CodingKey {
        case callID = "call_id", at, tool, outcome, durationMS = "duration_ms"
    }

    var date: Date { Date(timeIntervalSince1970: Double(at) / 1000) }
}

/// Relay → app: the answer to an `audit_request`, oldest first.
struct AuditPage: Codable, Equatable, Sendable {
    var id: String
    var entries: [AuditEntry]
    /// The `since` of the next page; nil when there are no more.
    var nextSince: Int64?

    enum CodingKeys: String, CodingKey { case id, entries, nextSince = "next_since" }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(entries, forKey: .entries)
        try c.encode(nextSince, forKey: .nextSince)  // null on the last page
    }
}

enum AgentMessage: Sendable {
    case challenge(Challenge), hello(Hello), welcome(Welcome), state(StateUpdate), tools(ToolsUpdate)
    case progress(Progress), result(CallResult), goodbye(Goodbye), call(Call), cancel(Cancel), notice(Notice)
    case clients(ClientsUpdate), revokeClient(RevokeClient)
    case auditRequest(AuditRequest), audit(AuditPage)

    static let allTypes = [
        "challenge", "hello", "welcome", "state", "tools", "progress", "result", "goodbye", "call", "cancel", "notice",
        "clients", "revoke_client", "audit_request", "audit",
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
        case .clients: "clients"
        case .revokeClient: "revoke_client"
        case .auditRequest: "audit_request"
        case .audit: "audit"
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
                if let kind = h.kind, kind != "mac", kind != "linux" {
                    throw ProtocolError.violation("unknown machine kind")
                }
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
            case "clients":
                let c = try dec.decode(ClientsUpdate.self, from: data)
                try validate(clients: c.clients)
                return .clients(c)
            case "revoke_client":
                let r = try dec.decode(RevokeClient.self, from: data)
                guard ClientEntry.isValid(id: r.id) else { throw ProtocolError.violation("invalid client id") }
                return .revokeClient(r)
            case "audit_request": return .auditRequest(try dec.decode(AuditRequest.self, from: data))
            case "audit": return .audit(try dec.decode(AuditPage.self, from: data))
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
        case .clients(let m): body = try enc.encode(m)
        case .revokeClient(let m): body = try enc.encode(m)
        case .auditRequest(let m): body = try enc.encode(m)
        case .audit(let m): body = try enc.encode(m)
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
            // laptop_status and machines are the relay's own tools (spec 010 FR-1006).
            guard t.name != "laptop_status", t.name != "machines" else {
                throw ProtocolError.violation("reserved tool name")
            }
            guard seen.insert(t.name).inserted else { throw ProtocolError.violation("duplicate tool \(t.name)") }
            guard t.inputSchema["type"] == .string("object") else {
                throw ProtocolError.violation("inputSchema must be an object")
            }
            // The relay adds the machine argument to every tool (spec 010 plan D2).
            if case .object(let props) = t.inputSchema["properties"], props["machine"] != nil {
                throw ProtocolError.violation("the input property machine is the relay's")
            }
            if let out = t.outputSchema, out["type"] != .string("object") {
                throw ProtocolError.violation("outputSchema must be an object")
            }
        }
    }

    /// At most 50 entries, each with a well-formed id that appears once. Missing fields already
    /// failed to decode.
    static func validate(clients: [ClientEntry]) throws {
        guard clients.count <= ClientEntry.maxEntries else { throw ProtocolError.violation("too many clients") }
        var seen = Set<String>()
        for c in clients {
            guard ClientEntry.isValid(id: c.id) else { throw ProtocolError.violation("invalid client id") }
            guard seen.insert(c.id).inserted else { throw ProtocolError.violation("duplicate client id") }
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
