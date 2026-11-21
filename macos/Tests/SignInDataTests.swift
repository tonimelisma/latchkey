import Foundation
import Testing

@testable import Latchkey

/// Spec 013: Passwords' CSV export, verification codes, and which pages a sign-in fills on.
@Suite struct SignInDataTests {
    // MARK: Passwords' CSV (FR-1300, FR-1303)

    static let csv = """
        Title,URL,Username,Password,Notes,OTPAuth
        example.com (toni),https://www.example.com/login,toni@example.com,"pa,ss""word",,otpauth://totp/Example:toni?secret=GEZDGNBVGY3TQOJQGEZDGNBVGY3TQOJQ&issuer=Example
        shop.test,https://shop.test/,buyer,hunter2,"a note
        on two lines",
        nouser.test,https://nouser.test/,,onlypassword,,
        app only,,someone,secret,,
        """

    @Test func readsApplesColumnsWithQuotes() throws {
        let rows = try PasswordsCSV.parse(Data(Self.csv.utf8))
        #expect(rows.count == 3)  // the row without a web address is left out
        let first = try #require(rows.first)
        #expect(first.site == "example.com")
        #expect(first.user == "toni@example.com")
        #expect(first.password == "pa,ss\"word")
        #expect(first.otp?.hasPrefix("otpauth://totp/") == true)
        #expect(rows[1].site == "shop.test" && rows[1].otp == nil)
        #expect(rows[2].user == "" && rows[2].password == "onlypassword")
    }

    @Test func refusesAFileThatIsntPasswordsExport() {
        #expect(throws: PasswordsCSV.Problem.self) { try PasswordsCSV.parse(Data("a,b\n1,2\n".utf8)) }
        #expect(throws: PasswordsCSV.Problem.self) { try PasswordsCSV.parse(Data("Title,URL\n\"unterminated".utf8)) }
    }

    @Test func readsColumnsInAnyOrderAndWindowsLineEnds() throws {
        let text = "URL,Password,Username,Title\r\nhttps://a.test/,p1,u1,A\r\n"
        let rows = try PasswordsCSV.parse(Data(text.utf8))
        #expect(rows == [SavedSignIn(title: "A", site: "a.test", user: "u1", password: "p1", otp: nil)])
    }

    // MARK: verification codes (RFC 6238 test vectors)

    @Test func codesMatchTheRFC() throws {
        // RFC 6238 appendix B, SHA-1, 8 digits: secret "12345678901234567890".
        let secret = try #require(
            TOTP(uri: "otpauth://totp/x?secret=GEZDGNBVGY3TQOJQGEZDGNBVGY3TQOJQ&digits=8"))
        #expect(secret.code(at: Date(timeIntervalSince1970: 59)) == "94287082")
        #expect(secret.code(at: Date(timeIntervalSince1970: 1_111_111_109)) == "07081804")
        #expect(secret.code(at: Date(timeIntervalSince1970: 2_000_000_000)) == "69279037")
        let six = try #require(TOTP(uri: "otpauth://totp/x?secret=GEZDGNBVGY3TQOJQGEZDGNBVGY3TQOJQ"))
        #expect(six.code(at: Date(timeIntervalSince1970: 59)) == "287082")
    }

    @Test func codesWithOtherAlgorithms() throws {
        // RFC 6238 SHA-256 and SHA-512 vectors at T = 59 (their secrets are 32 and 64 bytes).
        let s256 = Data("12345678901234567890123456789012".utf8)
        let s512 = Data("1234567890123456789012345678901234567890123456789012345678901234".utf8)
        let a = try #require(
            TOTP(uri: "otpauth://totp/x?secret=\(Base32.encode(s256))&digits=8&algorithm=SHA256"))
        let b = try #require(
            TOTP(uri: "otpauth://totp/x?secret=\(Base32.encode(s512))&digits=8&algorithm=SHA512"))
        #expect(a.code(at: Date(timeIntervalSince1970: 59)) == "46119246")
        #expect(b.code(at: Date(timeIntervalSince1970: 59)) == "90693936")
    }

    @Test func refusesCodesItCantMake() {
        #expect(TOTP(uri: "otpauth://hotp/x?secret=GEZDGNBV&counter=1") == nil)  // counter codes
        #expect(TOTP(uri: "otpauth://totp/x?secret=not*base32") == nil)
        #expect(TOTP(uri: "otpauth://totp/x?secret=GEZDGNBV&algorithm=MD5") == nil)
        #expect(TOTP(uri: "https://example.com") == nil)
    }

    @Test func secondsLeftInTheStep() throws {
        let six = try #require(TOTP(uri: "otpauth://totp/x?secret=GEZDGNBVGY3TQOJQGEZDGNBVGY3TQOJQ"))
        #expect(six.step(at: Date(timeIntervalSince1970: 59)) == 1)
        #expect(six.step(at: Date(timeIntervalSince1970: 60)) == 2)
    }

    // MARK: which pages a sign-in fills on (FR-1321)

    @Test func fillsOnItsSiteAndSubdomainsOverHTTPS() {
        #expect(SiteMatch.fills(site: "amazon.com", on: "https://www.amazon.com/ap/signin"))
        #expect(SiteMatch.fills(site: "amazon.com", on: "https://amazon.com/"))
        #expect(SiteMatch.fills(site: "amazon.com", on: "https://signin.aws.amazon.com/"))
        #expect(!SiteMatch.fills(site: "amazon.com", on: "http://www.amazon.com/"))  // not https
        #expect(!SiteMatch.fills(site: "amazon.com", on: "https://amazon.com.evil.test/"))
        #expect(!SiteMatch.fills(site: "amazon.com", on: "https://notamazon.com/"))
        #expect(!SiteMatch.fills(site: "amazon.com", on: "https://amaz0n.com/"))
        #expect(!SiteMatch.fills(site: "", on: "https://amazon.com/"))
    }

    @Test func aSavedAddressBecomesItsSite() {
        #expect(SiteMatch.site(of: "https://www.Example.com/login?x=1") == "example.com")
        #expect(SiteMatch.site(of: "https://accounts.google.com/") == "accounts.google.com")
        #expect(SiteMatch.site(of: "example.org") == "example.org")  // Passwords may omit the scheme
        #expect(SiteMatch.site(of: "") == nil)
        #expect(SiteMatch.site(of: "android://abc@com.example") == nil)
    }
}
