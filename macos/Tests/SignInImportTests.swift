import Foundation
import Testing

@testable import Latchkey

/// Spec 013: a file saved in Latchkey's import folder is taken in and deleted (FR-1301, FR-1303).
@Suite struct SignInImportTests {
    static func folder() throws -> URL {
        let f = FileManager.default.temporaryDirectory.appending(path: "signin-import-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: f, withIntermediateDirectories: true)
        return f
    }

    static func write(_ text: String, in folder: URL, age: TimeInterval = 5) throws -> URL {
        let url = folder.appending(path: "Passwords.csv")
        try Data(text.utf8).write(to: url)
        try FileManager.default.setAttributes(
            [.modificationDate: Date().addingTimeInterval(-age)], ofItemAtPath: url.path)
        return url
    }

    @Test func takesInAnExportAndDeletesIt() throws {
        let f = try Self.folder()
        let store = SignInStore(vault: MemoryVault())
        let file = try Self.write(SignInDataTests.csv, in: f)
        let outcomes = SignInImport.check(folder: f, store: store)
        #expect(outcomes == [.imported(count: 3, codes: 1)])
        #expect(!FileManager.default.fileExists(atPath: file.path))
        #expect(store.load().logins.count == 3)
    }

    @Test func aFileThatIsntAnExportIsDeletedAndKeepsTheOldCopies() throws {
        let f = try Self.folder()
        let store = SignInStore(vault: MemoryVault())
        try store.replace(with: [SignInStoreTests.a], at: Date())
        let file = try Self.write("not,a\nfile,at all\n", in: f)
        #expect(SignInImport.check(folder: f, store: store) == [.notAnExport])
        #expect(!FileManager.default.fileExists(atPath: file.path))
        #expect(store.load().logins == [SignInStoreTests.a])
    }

    @Test func aFileStillBeingWrittenWaits() throws {
        let f = try Self.folder()
        let store = SignInStore(vault: MemoryVault())
        let file = try Self.write(SignInDataTests.csv, in: f, age: 0)
        #expect(SignInImport.check(folder: f, store: store).isEmpty)
        #expect(FileManager.default.fileExists(atPath: file.path))
    }

    @Test func otherFilesAreLeftAlone() throws {
        let f = try Self.folder()
        let other = f.appending(path: "notes.txt")
        try Data("x".utf8).write(to: other)
        try FileManager.default.setAttributes(
            [.modificationDate: Date(timeIntervalSinceNow: -60)], ofItemAtPath: other.path)
        #expect(SignInImport.check(folder: f, store: SignInStore(vault: MemoryVault())).isEmpty)
        #expect(FileManager.default.fileExists(atPath: other.path))
    }

    @Test func theFolderIsPrivateAndLeftOutOfBackups() throws {
        let f = try Self.folder().appending(path: "Sign-in Import")
        try SignInImport.prepare(f)
        let attrs = try FileManager.default.attributesOfItem(atPath: f.path)
        #expect((attrs[.posixPermissions] as? NSNumber)?.intValue == 0o700)
        #expect(try f.resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup == true)
    }

    @Test func whatTheOwnerIsTold() {
        #expect(SignInImport.Outcome.imported(count: 3, codes: 1).told.contains("3 sign-ins"))
        #expect(SignInImport.Outcome.imported(count: 1, codes: 0).told.contains("1 sign-in "))
        #expect(SignInImport.Outcome.notAnExport.told.contains("Passwords"))
    }
}
