import CryptoKit
import Foundation

/// One sign-in from the Owner's Passwords export (spec 013). Kept only in Latchkey's Keychain
/// item (FR-1310); never shown to Claude except its site and user name (FR-1326).
struct SavedSignIn: Codable, Sendable, Equatable {
    var title: String
    /// The site it fills on, with its subdomains (FR-1321): the saved address's host without a
    /// leading "www.".
    var site: String
    var user: String
    var password: String
    /// The `otpauth://` address of its verification code, when it has one.
    var otp: String?
}

/// Apple's Passwords export: a CSV file with the columns Title, URL, Username, Password, Notes,
/// OTPAuth (`research.md`). Rows without a web address (apps only) are left out.
enum PasswordsCSV {
    enum Problem: Error, Equatable {
        case notPasswordsExport
        case malformed
    }

    static func parse(_ data: Data) throws -> [SavedSignIn] {
        let rows = try records(String(decoding: data, as: UTF8.self))
        guard let header = rows.first?.map({ $0.trimmingCharacters(in: .whitespaces).lowercased() }),
            let url = header.firstIndex(of: "url"), let password = header.firstIndex(of: "password")
        else { throw Problem.notPasswordsExport }
        let title = header.firstIndex(of: "title")
        let user = header.firstIndex(of: "username")
        let otp = header.firstIndex(of: "otpauth")
        func cell(_ row: [String], _ i: Int?) -> String { i.flatMap { $0 < row.count ? row[$0] : nil } ?? "" }
        return rows.dropFirst().compactMap { row in
            guard row.count > 1 || !(row.first ?? "").isEmpty, let site = SiteMatch.site(of: cell(row, url)) else {
                return nil
            }
            let code = cell(row, otp).trimmingCharacters(in: .whitespaces)
            return SavedSignIn(
                title: cell(row, title), site: site, user: cell(row, user), password: cell(row, password),
                otp: code.isEmpty ? nil : code)
        }
    }

    /// RFC 4180 records: quoted fields may hold commas, quotes (doubled), and line breaks.
    static func records(_ text: String) throws -> [[String]] {
        var rows: [[String]] = []
        var row: [String] = []
        var field = ""
        var quoted = false
        var chars = Array(text.unicodeScalars)[...]
        if chars.first == "\u{FEFF}" { chars = chars.dropFirst() }
        while let c = chars.popFirst() {
            if quoted {
                if c == "\"" {
                    if chars.first == "\"" {
                        field.unicodeScalars.append("\"")
                        chars = chars.dropFirst()
                    } else {
                        quoted = false
                    }
                } else {
                    field.unicodeScalars.append(c)
                }
                continue
            }
            switch c {
            case "\"" where field.isEmpty: quoted = true
            case ",":
                row.append(field)
                field = ""
            case "\r":
                break
            case "\n":
                row.append(field)
                rows.append(row)
                row = []
                field = ""
            default: field.unicodeScalars.append(c)
            }
        }
        guard !quoted else { throw Problem.malformed }
        if !field.isEmpty || !row.isEmpty {
            row.append(field)
            rows.append(row)
        }
        return rows
    }
}

/// Which pages a sign-in fills on (FR-1321): an https page on its site or a subdomain of it.
enum SiteMatch {
    /// The site of a saved address: its host, lowercased, without a leading "www.". Nil for an
    /// address that isn't a web site (an app's).
    static func site(of address: String) -> String? {
        let trimmed = address.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return nil }
        let withScheme = trimmed.contains("://") ? trimmed : "https://" + trimmed
        guard let u = URL(string: withScheme), ["http", "https"].contains(u.scheme?.lowercased() ?? ""),
            var host = u.host()?.lowercased()
        else { return nil }
        if host.hasSuffix(".") { host.removeLast() }
        guard host.contains("."), !host.hasPrefix("."), !host.contains("..") else { return nil }
        if host.hasPrefix("www."), !PublicSuffix.isSuffix(String(host.dropFirst(4))) { host.removeFirst(4) }
        return host
    }

    /// The page's host is the site, or a subdomain of it when the site isn't itself a public
    /// suffix: a sign-in saved for a shared host (herokuapp.com, github.io) never fills on its
    /// customers' sites (security review, 2026-11-21).
    static func fills(site: String, on page: String) -> Bool {
        guard !site.isEmpty, let u = URL(string: page), u.scheme?.lowercased() == "https",
            var host = u.host()?.lowercased()
        else { return false }
        if host.hasSuffix(".") { host.removeLast() }  // "example.com." is example.com
        return host == site || (host.hasSuffix("." + site) && !PublicSuffix.isSuffix(site))
    }
}

/// The Public Suffix List (publicsuffix.org, MPL 2.0, bundled as `public_suffix_list.dat`,
/// ICANN and private sections): names under which anyone may register their own (com, co.uk,
/// github.io, herokuapp.com).
enum PublicSuffix {
    private struct Rules {
        var exact: Set<String> = []
        var wildcard: Set<String> = []
        var exception: Set<String> = []
    }

    private static let rules: Rules = {
        var r = Rules()
        guard let url = Bundle.main.url(forResource: "public_suffix_list", withExtension: "dat"),
            let text = try? String(contentsOf: url, encoding: .utf8)
        else { return r }
        for raw in text.split(whereSeparator: \.isNewline) {
            let line = raw.trimmingCharacters(in: .whitespaces).lowercased()
            if line.isEmpty || line.hasPrefix("//") { continue }
            if line.hasPrefix("!") {
                r.exception.insert(String(line.dropFirst()))
            } else if line.hasPrefix("*.") {
                r.wildcard.insert(String(line.dropFirst(2)))
            } else {
                r.exact.insert(line)
            }
        }
        return r
    }()

    /// Whether the list loaded. Without it every name counts as a suffix: no subdomain fills,
    /// the safe side.
    static var loaded: Bool { !rules.exact.isEmpty }

    /// A name with a trailing or doubled dot, or an international one (the list writes those in
    /// Unicode, hosts come as punycode), counts as a suffix: no subdomain fills, the safe side
    /// (security review, 2026-11-21).
    static func isSuffix(_ name: String) -> Bool {
        let n = name.lowercased()
        guard n.contains("."), loaded, !n.hasPrefix("."), !n.hasSuffix("."), !n.contains(".."),
            n.unicodeScalars.allSatisfy(\.isASCII), !n.split(separator: ".").contains(where: { $0.hasPrefix("xn--") })
        else { return true }
        if rules.exception.contains(n) { return false }
        if rules.exact.contains(n) { return true }
        if let dot = n.firstIndex(of: "."), rules.wildcard.contains(String(n[n.index(after: dot)...])) { return true }
        return false
    }

    /// The name a site is registered under: the shortest ending of `host` that isn't a public
    /// suffix itself ("na.account.amazon.com" → "amazon.com"); the host when none is shorter.
    static func registrable(_ host: String) -> String {
        let labels = host.lowercased().split(separator: ".", omittingEmptySubsequences: false)
        guard labels.count > 1 else { return host.lowercased() }
        // The longest ending that is a public suffix, and one label more.
        for i in 0..<(labels.count - 1) where isSuffix(labels[(i + 1)...].joined(separator: ".")) {
            return labels[i...].joined(separator: ".")
        }
        return host.lowercased()
    }
}

/// A time-based verification code (RFC 6238) from an `otpauth://totp/` address.
struct TOTP: Sendable, Equatable {
    enum Algorithm: String, Sendable { case sha1 = "SHA1", sha256 = "SHA256", sha512 = "SHA512" }

    let secret: Data
    let digits: Int
    let period: Int
    let algorithm: Algorithm

    init?(uri: String) {
        guard let c = URLComponents(string: uri), c.scheme?.lowercased() == "otpauth",
            c.host?.lowercased() == "totp"
        else { return nil }
        let items = Dictionary(
            (c.queryItems ?? []).map { ($0.name.lowercased(), $0.value ?? "") }, uniquingKeysWith: { a, _ in a })
        guard let s = items["secret"], let secret = Base32.decode(s), !secret.isEmpty else { return nil }
        let digits = Int(items["digits"] ?? "6") ?? 0
        let period = Int(items["period"] ?? "30") ?? 0
        guard (6...10).contains(digits), period > 0,
            let algorithm = Algorithm(rawValue: (items["algorithm"] ?? "SHA1").uppercased())
        else { return nil }
        self.secret = secret
        self.digits = digits
        self.period = period
        self.algorithm = algorithm
    }

    /// The time step a moment falls in: a code refused once is never sent again (FR-1324), so a
    /// retry waits for the next step.
    func step(at date: Date) -> UInt64 { UInt64(max(0, date.timeIntervalSince1970) / Double(period)) }

    func code(at date: Date = Date()) -> String {
        var counter = step(at: date).bigEndian
        let message = Data(bytes: &counter, count: 8)
        let key = SymmetricKey(data: secret)
        let mac: [UInt8] =
            switch algorithm {
            case .sha1: Array(HMAC<Insecure.SHA1>.authenticationCode(for: message, using: key))
            case .sha256: Array(HMAC<SHA256>.authenticationCode(for: message, using: key))
            case .sha512: Array(HMAC<SHA512>.authenticationCode(for: message, using: key))
            }
        let offset = Int(mac[mac.count - 1] & 0x0f)
        let value =
            (UInt64(mac[offset] & 0x7f) << 24) | (UInt64(mac[offset + 1]) << 16) | (UInt64(mac[offset + 2]) << 8)
            | UInt64(mac[offset + 3])
        var modulus: UInt64 = 1
        for _ in 0..<digits { modulus *= 10 }
        let s = String(value % modulus)
        return String(repeating: "0", count: max(0, digits - s.count)) + s
    }
}

/// RFC 4648 base32, as verification-code secrets are written (case and padding ignored).
enum Base32 {
    private static let alphabet = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZ234567")

    static func decode(_ text: String) -> Data? {
        var bits: UInt64 = 0
        var count = 0
        var out = Data()
        for ch in text.uppercased() where ch != "=" && ch != " " && ch != "-" {
            guard let v = alphabet.firstIndex(of: ch) else { return nil }
            bits = (bits << 5) | UInt64(v)
            count += 5
            if count >= 8 {
                count -= 8
                out.append(UInt8((bits >> UInt64(count)) & 0xff))
            }
        }
        return out
    }

    static func encode(_ data: Data) -> String {
        var bits: UInt64 = 0
        var count = 0
        var out = ""
        for byte in data {
            bits = (bits << 8) | UInt64(byte)
            count += 8
            while count >= 5 {
                count -= 5
                out.append(alphabet[Int((bits >> UInt64(count)) & 31)])
            }
        }
        if count > 0 { out.append(alphabet[Int((bits << UInt64(5 - count)) & 31)]) }
        return out
    }
}
