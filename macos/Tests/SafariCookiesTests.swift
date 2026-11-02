import Foundation
import Testing

@testable import Latchkey

/// Spec 005 FR-420: Safari's cookie file, read for the browser used while the Mac is locked.
@Suite struct SafariCookiesTests {
    /// One cookie record as Safari writes it (little-endian, offsets from the record's start).
    static func record(
        domain: String, name: String, path: String, value: String, flags: UInt32, expires: Date
    ) -> [UInt8] {
        func le(_ v: UInt32) -> [UInt8] {
            [UInt8(v & 0xFF), UInt8(v >> 8 & 0xFF), UInt8(v >> 16 & 0xFF), UInt8(v >> 24)]
        }
        func dbl(_ d: Double) -> [UInt8] { (0..<8).map { UInt8(d.bitPattern >> (8 * UInt64($0)) & 0xFF) } }
        let strings = [domain, name, path, value].map { Array($0.utf8) + [0] }
        var offset = UInt32(56)
        var offsets: [UInt32] = []
        for s in strings {
            offsets.append(offset)
            offset += UInt32(s.count)
        }
        var r: [UInt8] = le(offset) + le(0) + le(flags) + le(0)
        r += offsets.flatMap(le) + le(0) + le(0)
        r +=
            dbl(expires.timeIntervalSinceReferenceDate)
            + dbl(Date(timeIntervalSince1970: 0).timeIntervalSinceReferenceDate)
        return r + strings.flatMap { $0 }
    }

    static func file(_ records: [[UInt8]]) -> Data {
        func be(_ v: UInt32) -> [UInt8] {
            [UInt8(v >> 24), UInt8(v >> 16 & 0xFF), UInt8(v >> 8 & 0xFF), UInt8(v & 0xFF)]
        }
        func le(_ v: UInt32) -> [UInt8] {
            [UInt8(v & 0xFF), UInt8(v >> 8 & 0xFF), UInt8(v >> 16 & 0xFF), UInt8(v >> 24)]
        }
        var head: [UInt8] = [0, 0, 1, 0] + le(UInt32(records.count))
        var at = UInt32(head.count + 4 * records.count + 4)
        var body: [UInt8] = []
        for r in records {
            head += le(at)
            at += UInt32(r.count)
            body += r
        }
        let page = head + le(0) + body
        return Data(Array("cook".utf8) + be(1) + be(UInt32(page.count)) + page + [0, 0, 0, 0, 0, 0, 0, 0])
    }

    @Test func readsSafarisFormat() {
        let later = Date().addingTimeInterval(86_400)
        let data = Self.file([
            Self.record(domain: ".example.com", name: "session", path: "/", value: "abc", flags: 5, expires: later),
            Self.record(
                domain: "shop.example.net", name: "cart", path: "/basket", value: "1", flags: 0, expires: later),
            Self.record(
                domain: ".old.example", name: "gone", path: "/", value: "x", flags: 0,
                expires: Date().addingTimeInterval(-60)),
        ])
        let cookies = SafariCookies.parse(data)
        #expect(cookies.count == 2, "the expired one is left out")
        #expect(cookies[0].domain == ".example.com" && cookies[0].name == "session" && cookies[0].value == "abc")
        #expect(cookies[0].secure && cookies[0].httpOnly)
        #expect(cookies[1].path == "/basket" && !cookies[1].secure && !cookies[1].httpOnly)
        let http = SafariCookies.httpCookie(cookies[0])
        #expect(http?.isSecure == true && http?.isHTTPOnly == true && http?.domain == ".example.com")
        #expect(http?.sameSitePolicy == .sameSiteLax, "never sent with another site's requests")
    }

    @Test func nonsenseGivesNothing() {
        #expect(SafariCookies.parse(Data()).isEmpty)
        #expect(SafariCookies.parse(Data("cook".utf8) + Data([0xFF, 0xFF, 0xFF, 0xFF])).isEmpty)
        var cut = Self.file([
            Self.record(
                domain: ".example.com", name: "a", path: "/", value: "b", flags: 0,
                expires: Date().addingTimeInterval(60))
        ])
        cut.removeLast(30)
        #expect(SafariCookies.parse(cut).isEmpty, "a cut-off file is skipped, not guessed")
    }
}
