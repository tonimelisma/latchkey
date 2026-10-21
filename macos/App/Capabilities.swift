import Foundation

/// A tool's answer, as the agent protocol's result carries it.
struct ToolResult: Sendable, Equatable {
    var content: JSONValue
    var structuredContent: JSONValue?
    var isError: Bool

    static func text(_ s: String, isError: Bool = false) -> ToolResult {
        ToolResult(content: .array([.object(["type": .string("text"), "text": .string(s)])]), isError: isError)
    }
}

/// The "System info" capability (FR-063): one tool, battery_status.
enum SystemInfoCapability {
    static let id = "system_info"
    static let title = "System info"
    static let summary = "Battery level and power state"

    static let batteryStatusTool = Tool(
        name: "battery_status",
        title: "Battery status",
        description: "Live battery level and power state of the user's Mac.",
        inputSchema: .object([
            "type": .string("object"), "properties": .object([:]), "additionalProperties": .bool(false),
        ]),
        outputSchema: .object([
            "type": .string("object"),
            "properties": .object([
                "battery_percent": .object(["type": .string("integer")]),
                "charging": .object(["type": .string("boolean")]),
                "power_source": .object([
                    "type": .string("string"),
                    "enum": .array([.string("battery"), .string("ac"), .string("ups"), .string("unknown")]),
                ]),
                "time_remaining_min": .object(["type": .array([.string("integer"), .string("null")])]),
            ]),
            "required": .array([.string("battery_percent"), .string("charging"), .string("power_source")]),
        ]),
        annotations: ToolAnnotations(readOnlyHint: true, openWorldHint: false),
        meta: [Tool.deadlineKey: .number(5000)])

    static func batteryStatus(_ p: PowerSnapshot) -> ToolResult {
        guard p.hasBattery else { return .text("This Mac has no battery; it runs on mains power.", isError: true) }
        let structured: JSONValue = .object([
            "battery_percent": .number(Double(p.batteryPercent)),
            "charging": .bool(p.charging),
            "power_source": .string(p.powerSource.rawValue),
            "time_remaining_min": p.timeRemainingMin.map { .number(Double($0)) } ?? .null,
        ])
        var r = ToolResult.text(structured.jsonText)
        r.structuredContent = structured
        return r
    }
}

/// The capabilities the Owner enabled; only their tools exist for Claude (Constitution III).
struct CapabilityRegistry: Sendable {
    static let defaultEnabled: Set<String> = [SystemInfoCapability.id]  // FR-064

    struct Capability: Identifiable, Sendable {
        var id: String
        var title: String
        var summary: String
        var tools: [Tool]
    }

    static let all: [Capability] = [
        Capability(
            id: SystemInfoCapability.id, title: SystemInfoCapability.title,
            summary: SystemInfoCapability.summary, tools: [SystemInfoCapability.batteryStatusTool])
    ]

    private(set) var enabled: Set<String>

    init(enabled: Set<String>) { self.enabled = enabled }

    mutating func setEnabled(_ id: String, _ on: Bool) {
        if on { enabled.insert(id) } else { enabled.remove(id) }
    }

    var tools: [Tool] { Self.all.filter { enabled.contains($0.id) }.flatMap(\.tools) }

    func call(tool: String, arguments: JSONValue, power: @Sendable () -> PowerSnapshot) async -> ToolResult {
        guard tools.contains(where: { $0.name == tool }) else {
            return .text("The tool \(tool) is turned off in the Latchkey app on this Mac.", isError: true)
        }
        switch tool {
        case SystemInfoCapability.batteryStatusTool.name: return SystemInfoCapability.batteryStatus(power())
        default: return .text("Unknown tool \(tool).", isError: true)
        }
    }
}
