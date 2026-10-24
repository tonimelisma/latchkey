import Foundation

/// A capability's internal operations, by name. Claude sees a few consolidated tools (15 in all,
/// Toni 2026-10-23); each hands a request to the operation it asks for.
struct Operations: Sendable {
    private let entries: [String: ToolEntry]

    init(_ list: [ToolEntry]) {
        entries = Dictionary(uniqueKeysWithValues: list.map { ($0.tool.name, $0) })
    }

    func call(_ name: String, _ args: JSONValue) async -> ToolResult {
        guard let entry = entries[name] else { return .text("Latchkey has no operation \(name).", isError: true) }
        return await entry.handler(args)
    }
}

extension JSONValue {
    /// The object with keys set (or removed, for nil).
    func with(_ changes: [String: JSONValue?]) -> JSONValue {
        guard case .object(var o) = self else { return self }
        for (k, v) in changes { o[k] = v }
        return .object(o)
    }

    var isPresent: Bool {
        switch self {
        case .null: false
        case .string(let s): !s.isEmpty
        case .bool(let b): b
        default: true
        }
    }

    static func boolParam(_ description: String) -> JSONValue {
        .object(["type": .string("boolean"), "description": .string(description)])
    }

    static func enumParam(_ values: [String], _ description: String) -> JSONValue {
        .object([
            "type": .string("string"), "enum": .array(values.map(JSONValue.string)),
            "description": .string(description),
        ])
    }
}

extension ToolResult {
    /// Two answers as one, the second after the first.
    static func + (a: ToolResult, b: ToolResult) -> ToolResult {
        guard case .array(let x) = a.content, case .array(let y) = b.content else { return a }
        return ToolResult(content: .array(x + y), isError: a.isError && b.isError, activity: a.activity ?? b.activity)
    }

    static func unknown(_ field: String, _ value: String?, allowed: [String]) -> ToolResult {
        .text(
            "\(field) must be one of: \(allowed.joined(separator: ", "))" + (value.map { " (got \"\($0)\")." } ?? "."),
            isError: true)
    }
}

extension JSONValue {
    /// Whether any of these keys is set.
    func hasAny(_ keys: String...) -> Bool { keys.contains { self[$0]?.isPresent == true } }
}
