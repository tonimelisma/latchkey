import Foundation

/// A tool's answer, as the agent protocol's result carries it. `activity`, when set, names a change
/// Claude made on the Mac ("Sent a message to Sarah"); it becomes a notification (FR-130).
struct ToolResult: Sendable, Equatable {
    var content: JSONValue
    var structuredContent: JSONValue?
    var isError: Bool
    var activity: String?
    /// What the call created ("the note “Plan”"), for the Left Behind list (FR-641).
    var made: String?
    /// Changes made along the way that happened whether or not the call itself succeeded (iCloud
    /// copies deleted, spec 007 FR-727): notified even when the answer is an error.
    var alsoDone: String?

    /// Adds a line of text at the end of the answer, on a line of its own (Claude's apps join
    /// text parts without a break).
    mutating func appendText(_ s: String) {
        guard case .array(var items) = content else { return }
        items.append(.object(["type": .string("text"), "text": .string("\n" + s)]))
        content = .array(items)
    }

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
    /// The levels the Owner can choose; shell offers only Off and On (spec 004 FR-308).
    var levels: [AccessLevel] = AccessLevel.allCases
    /// The name of the top level when it isn't "Read & Write".
    var onTitle: String?

    func title(for level: AccessLevel) -> String {
        level == .readWrite ? onTitle ?? level.title : level.title
    }

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
    static let files = "files"
    static let shell = "shell"
    static let browser = "browser"
    static let computer = "computer"
    static let calendar = "calendar"
    static let reminders = "reminders"
    static let contacts = "contacts"
    static let location = "location"
    static let all = [notes, messages, files, shell, browser, computer, calendar, reminders, contacts, location]
    /// Every capability starts fully on (spec 002 FR-121; specs 003–006, Toni 2026-10-22; spec 007
    /// FR-741, Toni 2026-10-26).
    static let defaultLevels = Dictionary(uniqueKeysWithValues: all.map { ($0, AccessLevel.readWrite) })

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

    /// Why a running call of `tool` must stop: its capability is now off, or at a level without
    /// that tool. Nil while the tool is allowed (spec 001 FR-066).
    func stopReason(tool: String) -> String? {
        guard !entries.contains(where: { $0.tool.name == tool }),
            let capability = capabilities.first(where: { c in
                (c.readTools + c.writeTools).contains { $0.tool.name == tool }
            })
        else { return nil }
        let now = level(capability.id)
        let change =
            now == .off ? "turned \(capability.title) off" : "set \(capability.title) to \(capability.title(for: now))"
        return
            "The Mac's owner \(change) in the Latchkey app while this was running, so it was stopped. It may not have finished."
    }

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
