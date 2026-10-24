import Foundation

/// Any JSON value: tool schemas, call arguments, and results pass through the app as these.
enum JSONValue: Codable, Equatable, Sendable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])

    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() {
            self = .null
        } else if let b = try? c.decode(Bool.self) {
            self = .bool(b)
        } else if let n = try? c.decode(Double.self) {
            self = .number(n)
        } else if let s = try? c.decode(String.self) {
            self = .string(s)
        } else if let a = try? c.decode([JSONValue].self) {
            self = .array(a)
        } else {
            self = .object(try c.decode([String: JSONValue].self))
        }
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .null: try c.encodeNil()
        case .bool(let b): try c.encode(b)
        case .number(let n):
            if n.rounded() == n, abs(n) < 1e15 { try c.encode(Int64(n)) } else { try c.encode(n) }
        case .string(let s): try c.encode(s)
        case .array(let a): try c.encode(a)
        case .object(let o): try c.encode(o)
        }
    }

    subscript(key: String) -> JSONValue? {
        if case .object(let o) = self { return o[key] }
        return nil
    }

    /// Compact JSON text, keys sorted.
    var jsonText: String {
        let enc = JSONEncoder()
        enc.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return (try? String(decoding: enc.encode(self), as: UTF8.self)) ?? "null"
    }
}

/// A tool argument that can't be used as given; the tool answers with the message as its error.
struct ArgumentError: Error, Equatable {
    var message: String
}

extension JSONValue {
    /// The whole number under `key`, or nil when it's missing. Numbers arrive as doubles, and
    /// Int(_:) crashes the app on NaN, infinity, or a value past Int's range (security scan,
    /// 2026-10-24), so every tool argument goes through here: those, fractions, and values outside
    /// `range` throw ArgumentError. Text holding a whole number is accepted.
    func integer(_ key: String, in range: ClosedRange<Int> = Int.min...Int.max) throws -> Int? {
        let found: Int?
        switch self[key] {
        case nil, .null?: return nil
        case .number(let n)?: found = n.isFinite ? Int(exactly: n) : nil
        case .string(let s)?: found = Int(s.trimmingCharacters(in: .whitespaces))
        default: found = nil
        }
        guard let found, range.contains(found) else { throw ArgumentError(message: Self.wholeNumber(key, range)) }
        return found
    }

    /// The number under `key`, or nil when it's missing; NaN, infinity, and values outside `range`
    /// throw ArgumentError.
    func number(_ key: String, in range: ClosedRange<Double>) throws -> Double? {
        let found: Double?
        switch self[key] {
        case nil, .null?: return nil
        case .number(let n)?: found = n
        case .string(let s)?: found = Double(s.trimmingCharacters(in: .whitespaces))
        default: found = nil
        }
        guard let found, found.isFinite, range.contains(found) else {
            throw ArgumentError(
                message:
                    "\(key) must be a number from \(range.lowerBound.formatted()) to \(range.upperBound.formatted()).")
        }
        return found
    }

    private static func wholeNumber(_ key: String, _ range: ClosedRange<Int>) -> String {
        switch (range.lowerBound, range.upperBound) {
        case (Int.min, Int.max): "\(key) must be a whole number."
        case (let low, Int.max): "\(key) must be a whole number, \(low) or more."
        case (let low, let high): "\(key) must be a whole number from \(low) to \(high)."
        }
    }
}

extension Data {
    /// Decodes base64url, with or without padding.
    init?(base64URL s: String) {
        var b = s.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        b += String(repeating: "=", count: (4 - b.count % 4) % 4)
        self.init(base64Encoded: b)
    }

    /// base64url without padding.
    func base64URLEncodedString() -> String {
        base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}
