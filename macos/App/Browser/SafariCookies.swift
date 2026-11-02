import Foundation

/// Safari's cookies, read from its `Cookies.binarycookies` file, for the browser Latchkey uses
/// while the Mac is locked (spec 005 FR-420, FR-421). The format isn't documented by Apple; it is
/// the long-known one: "cook", a big-endian page count and page sizes, then pages of
/// little-endian cookie records (flags, offsets to domain, name, path, and value, and the expiry
/// as seconds since 2001). Anything that doesn't fit is skipped, never guessed. The values stay
/// in memory: never logged, written elsewhere, or sent off the Mac.
enum SafariCookies {
    struct Cookie: Equatable, Sendable {
        var domain: String
        var name: String
        var path: String
        var value: String
        var secure: Bool
        var httpOnly: Bool
        var expires: Date
    }

    static var file: URL {
        URL.homeDirectory.appending(
            path: "Library/Containers/com.apple.Safari/Data/Library/Cookies/Cookies.binarycookies")
    }

    /// The cookies in `data` that haven't expired at `now`.
    static func parse(_ data: Data, now: Date = Date()) -> [Cookie] {
        let b = [UInt8](data)
        func be32(_ i: Int) -> Int? {
            guard i >= 0, i + 4 <= b.count else { return nil }
            return Int(b[i]) << 24 | Int(b[i + 1]) << 16 | Int(b[i + 2]) << 8 | Int(b[i + 3])
        }
        func le32(_ i: Int) -> Int? {
            guard i >= 0, i + 4 <= b.count else { return nil }
            return Int(b[i]) | Int(b[i + 1]) << 8 | Int(b[i + 2]) << 16 | Int(b[i + 3]) << 24
        }
        func double(_ i: Int) -> Double? {
            guard i >= 0, i + 8 <= b.count else { return nil }
            var bits: UInt64 = 0
            for k in 0..<8 { bits |= UInt64(b[i + k]) << (8 * UInt64(k)) }
            return Double(bitPattern: bits)
        }
        func string(_ i: Int, end: Int) -> String? {
            guard i >= 0, i < end, end <= b.count, let zero = b[i..<end].firstIndex(of: 0) else { return nil }
            return String(bytes: b[i..<zero], encoding: .utf8)
        }
        guard b.count >= 8, b[0..<4] == [0x63, 0x6F, 0x6F, 0x6B], let pages = be32(4), pages < 100_000 else {
            return []
        }
        var sizes: [Int] = []
        for p in 0..<pages {
            guard let s = be32(8 + 4 * p) else { return [] }
            sizes.append(s)
        }
        var out: [Cookie] = []
        var pageStart = 8 + 4 * pages
        for size in sizes {
            defer { pageStart += size }
            guard pageStart + size <= b.count, let count = le32(pageStart + 4), count < 100_000 else { continue }
            for c in 0..<count {
                guard let rel = le32(pageStart + 8 + 4 * c) else { continue }
                let start = pageStart + rel
                guard let length = le32(start), length >= 56, start + length <= pageStart + size,
                    let flags = le32(start + 8), let domainAt = le32(start + 16), let nameAt = le32(start + 20),
                    let pathAt = le32(start + 24), let valueAt = le32(start + 28), let expiry = double(start + 40)
                else { continue }
                let end = start + length
                guard let domain = string(start + domainAt, end: end), let name = string(start + nameAt, end: end),
                    let path = string(start + pathAt, end: end), let value = string(start + valueAt, end: end),
                    !domain.isEmpty, !name.isEmpty
                else { continue }
                let expires = Date(timeIntervalSinceReferenceDate: expiry)
                guard expires > now else { continue }
                out.append(
                    Cookie(
                        domain: domain, name: name, path: path.isEmpty ? "/" : path, value: value,
                        secure: flags & 1 != 0, httpOnly: flags & 4 != 0, expires: expires))
            }
        }
        return out
    }

    static func httpCookie(_ c: Cookie) -> HTTPCookie? {
        var p: [HTTPCookiePropertyKey: Any] = [
            .domain: c.domain, .name: c.name, .path: c.path, .value: c.value, .expires: c.expires,
        ]
        if c.secure { p[.secure] = "TRUE" }
        if c.httpOnly { p[HTTPCookiePropertyKey("HttpOnly")] = "TRUE" }
        return HTTPCookie(properties: p)
    }
}
