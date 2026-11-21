import Foundation
import Testing

@testable import Latchkey

/// Spec 013 FR-1307: an export saved somewhere other than Latchkey's folder, during or after a
/// stopped export, is found by its name and wiped. Each test has a home folder of its own.
@Suite struct PasswordsExportCleanupTests {
    static func home() throws -> URL {
        let h = FileManager.default.temporaryDirectory.appending(path: "export-home-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: h, withIntermediateDirectories: true)
        return h
    }

    static func put(_ path: String, in home: URL) throws -> URL {
        let url = home.appending(path: path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("Title,URL,Username,Password,Notes,OTPAuth\n".utf8).write(to: url)
        return url
    }

    @Test(arguments: [
        "Downloads/Passwords-AB12CD34.csv",
        "Downloads/Folder/Passwords-AB12CD34.csv",
        "Desktop/Passwords-AB12CD34.csv",
        "Documents/Work/Passwords-AB12CD34.csv",
        "Passwords-AB12CD34.csv",
        "Library/Mobile Documents/com~apple~CloudDocs/Passwords-AB12CD34.csv",
        "Library/CloudStorage/OneDrive-Personal/Backup/Passwords-AB12CD34.csv",
    ])
    func aFileSavedElsewhereIsWiped(_ path: String) throws {
        let h = try Self.home()
        let file = try Self.put(path, in: h)
        let other = try Self.put("Downloads/Passwords.csv", in: h)
        #expect(PasswordsExport.wipeStray("Passwords-AB12CD34.csv", home: h))
        #expect(!FileManager.default.fileExists(atPath: file.path))
        // Only the export's own name: the Owner's other files stay.
        #expect(FileManager.default.fileExists(atPath: other.path))
    }

    @Test func nothingFoundIsSaid() throws {
        let h = try Self.home()
        _ = try Self.put("Downloads/Other.csv", in: h)
        #expect(!PasswordsExport.wipeStray("Passwords-AB12CD34.csv", home: h))
    }

    @Test func aFileSavedAfterTheStopIsWipedWhenItTurnsUp() async throws {
        let h = try Self.home()
        let sweep = Task {
            await PasswordsExport.sweep("Passwords-LATE0001.csv", home: h, every: .milliseconds(50), for: .seconds(5))
        }
        try await Task.sleep(for: .milliseconds(300))
        let file = try Self.put("Downloads/Passwords-LATE0001.csv", in: h)
        #expect(await sweep.value)
        #expect(!FileManager.default.fileExists(atPath: file.path))
    }

    @Test func theSweepEndsWhenNothingTurnsUp() async throws {
        let h = try Self.home()
        #expect(
            !(await PasswordsExport.sweep(
                "Passwords-NONE0001.csv", home: h, every: .milliseconds(50), for: .milliseconds(300))))
    }
}
