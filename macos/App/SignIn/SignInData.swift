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
            var host = u.host()?.lowercased(), host.contains(".")
        else { return nil }
        if host.hasPrefix("www.") { host.removeFirst(4) }
        return host
    }

    static func fills(site: String, on page: String) -> Bool {
        guard !site.isEmpty, let u = URL(string: page), u.scheme?.lowercased() == "https",
            let host = u.host()?.lowercased()
        else { return false }
        return host == site || host.hasSuffix("." + site)
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
