import Foundation

/// A tool's answer, as the agent protocol's result carries it. `activity`, when set, names a change
/// Claude made on the Mac ("Sent a message to Sarah"); it becomes a notification (FR-130).
struct ToolResult: Sendable, Equatable {
    var content: JSONValue
    var structuredContent: JSONValue?
    var isError: Bool
    var activity: String?

    static func text(_ s: String, isError: Bool = false) -> ToolResult {
        ToolResult(content: .array([.object(["type": .string("text"), "text": .string(s)])]), isError: isError)
    }

    /// Text plus the same data as structured content.
    static func data(_ value: JSONValue, text: String? = nil) -> ToolResult {
        var r = ToolResult.text(text ?? value.jsonText)
        r.structuredContent = value
        return r
    }

    static func image(_ data: Data, mimeType: String) -> ToolResult {
        ToolResult(
            content: .array([
                .object([
                    "type": .string("image"), "data": .string(data.base64EncodedString()),
                    "mimeType": .string(mimeType),
                ])
            ]), isError: false)
    }
}

/// How much Claude may do with a capability (spec 002 FR-120).
enum AccessLevel: String, CaseIterable, Codable, Sendable {
    case off
    case readOnly = "read"
    case readWrite = "write"

    var title: String {
        switch self {
        case .off: "Off"
        case .readOnly: "Read Only"
        case .readWrite: "Read & Write"
        }
    }
}

typealias ToolHandler = @Sendable (JSONValue) async -> ToolResult

/// A tool and the code that answers it.
struct ToolEntry: Sendable {
    var tool: Tool
    var handler: ToolHandler
}

/// A group of tools the Owner allows as a whole, at a level.
struct Capability: Identifiable, Sendable {
    var id: String
    var title: String
    var summary: String
    var readTools: [ToolEntry]
    var writeTools: [ToolEntry]

    func entries(at level: AccessLevel) -> [ToolEntry] {
        switch level {
        case .off: []
        case .readOnly: readTools
        case .readWrite: readTools + writeTools
        }
    }
}

/// The capabilities and the Owner's level for each; only the tools of those levels exist for
/// Claude (Constitution III).
struct CapabilityRegistry: Sendable {
    static let notes = "notes"
    static let messages = "messages"
    /// FR-121: both start at Read & write.
    static let defaultLevels: [String: AccessLevel] = [notes: .readWrite, messages: .readWrite]

    let capabilities: [Capability]
    private(set) var levels: [String: AccessLevel]

    init(capabilities: [Capability], levels: [String: AccessLevel]) {
        self.capabilities = capabilities
        self.levels = levels
    }

    func level(_ id: String) -> AccessLevel { levels[id] ?? .off }

    mutating func setLevel(_ id: String, _ level: AccessLevel) { levels[id] = level }

    private var entries: [ToolEntry] { capabilities.flatMap { $0.entries(at: level($0.id)) } }

    var tools: [Tool] { entries.map(\.tool) }

    /// True when any capability is on (it then needs the macOS permissions).
    var anyOn: Bool { capabilities.contains { level($0.id) != .off } }

    func call(tool: String, arguments: JSONValue) async -> ToolResult {
        guard let entry = entries.first(where: { $0.tool.name == tool }) else {
            return .text("The tool \(tool) is turned off in the Latchkey app on this Mac.", isError: true)
        }
        return await entry.handler(arguments)
    }
}

extension Tool {
    /// A tool with the annotations Claude requires on every tool.
    static func make(
        _ name: String, title: String, description: String, input: [String: JSONValue] = [:],
        required: [String] = [], readOnly: Bool, destructive: Bool = false, openWorld: Bool = false,
        deadlineMS: Int = 10_000
    ) -> Tool {
        Tool(
            name: name, title: title, description: description,
            inputSchema: .object([
                "type": .string("object"), "properties": .object(input),
                "required": .array(required.map(JSONValue.string)), "additionalProperties": .bool(false),
            ]),
            outputSchema: nil,
            annotations: ToolAnnotations(
                title: title, readOnlyHint: readOnly, destructiveHint: destructive, openWorldHint: openWorld),
            meta: [Tool.deadlineKey: .number(Double(deadlineMS))])
    }
}

extension JSONValue {
    static func stringParam(_ description: String) -> JSONValue {
        .object(["type": .string("string"), "description": .string(description)])
    }
    static func integerParam(_ description: String) -> JSONValue {
        .object(["type": .string("integer"), "description": .string(description)])
    }
}
