import Foundation

/// The text inside `message.attributedBody`, an NSArchiver typedstream of an attributed string,
/// where recent macOS keeps most message text (spec 002 research "Messages"). Read by finding
/// the string's bytes rather than unarchiving, so nothing from the database becomes an object.
enum AttributedBody {
    private static let marker = Array("NSString".utf8)

    /// After the marker come 5 fixed bytes, then the UTF-8 length: one byte below 0x80,
    /// 0x81 + 2 bytes, or 0x82 + 4 bytes, little-endian (checked against NSArchiver output).
    static func text(_ data: Data) -> String? {
        data.withUnsafeBytes { text($0) }
    }

    static func text(_ raw: UnsafeRawBufferPointer) -> String? {
        let b = raw.bindMemory(to: UInt8.self)
        guard let base = b.baseAddress, b.count > marker.count,
            let hit = memmem(base, b.count, marker, marker.count)
        else { return nil }
        var i = base.distance(to: hit.assumingMemoryBound(to: UInt8.self)) + marker.count + 5
        guard i < b.count else { return nil }
        var length = 0
        switch b[i] {
        case 0x81:
            guard i + 2 < b.count else { return nil }
            length = Int(b[i + 1]) | Int(b[i + 2]) << 8
            i += 3
        case 0x82:
            guard i + 4 < b.count else { return nil }
            length = Int(b[i + 1]) | Int(b[i + 2]) << 8 | Int(b[i + 3]) << 16 | Int(b[i + 4]) << 24
            i += 5
        case let n where n < 0x80:
            length = Int(n)
            i += 1
        default: return nil
        }
        guard length > 0, i + length <= b.count else { return nil }
        return String(decoding: UnsafeBufferPointer(rebasing: b[i..<i + length]), as: UTF8.self)
    }
}
