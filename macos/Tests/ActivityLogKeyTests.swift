import CryptoKit
import Foundation
import Testing

@testable import Latchkey

/// Stands in for the Keychain item that holds the activity log's key: what a look finds is set by
/// the test, and every save is kept so a test can show that none happened.
final class StandInKeyItem: TraceKeyItem, TraceKeyStore, @unchecked Sendable {
    private let lock = NSLock()
    private var state: StoredItem
    private var saved: [Data] = []

    init(_ state: StoredItem) { self.state = state }

    var added: [Data] { lock.withLock { saved } }
    func set(_ new: StoredItem) { lock.withLock { state = new } }

    func lookup() -> StoredItem { lock.withLock { state } }
    func add(_ data: Data) throws {
        lock.withLock {
            saved.append(data)
            state = .found(data)
        }
    }

    func loadOrCreate() throws -> SymmetricKey { try TraceKey.loadOrCreate(in: self) }
    func delete() { set(.absent) }
}

/// FR-201: a new key for the activity log is made only when no key exists at all. On 2026-10-24
/// a Keychain read that always failed made the app write a new key over the real one at every
/// launch; the log written under the old key was unreadable for good.
@Suite struct ActivityLogKeyTests {
    static func raw(_ k: SymmetricKey) -> Data { k.withUnsafeBytes { Data($0) } }

    @Test func noKeyAtAllMakesOne() throws {
        let item = StandInKeyItem(.absent)
        let key = try TraceKey.loadOrCreate(in: item)
        #expect(item.added.count == 1, "saved once")
        #expect(item.added.first?.count == 32, "AES-256")
        #expect(item.added.first == Self.raw(key))
        #expect(Self.raw(try TraceKey.loadOrCreate(in: item)) == Self.raw(key), "and used from then on")
        #expect(item.added.count == 1)
    }

    @Test func aReadableKeyIsUsed() throws {
        let existing = Data(repeating: 7, count: 32)
        let item = StandInKeyItem(.found(existing))
        #expect(Self.raw(try TraceKey.loadOrCreate(in: item)) == existing)
        #expect(item.added.isEmpty, "nothing written")
    }

    @Test func aKeyThatCannotBeReadIsNeverReplaced() {
        let item = StandInKeyItem(.unreadable("Keychain error -25308"))
        #expect(throws: TraceKeyUnreadable(reason: "Keychain error -25308")) { try TraceKey.loadOrCreate(in: item) }
        #expect(item.added.isEmpty, "the key that is there is left alone")
        #expect(item.lookup() == .unreadable("Keychain error -25308"))
    }

    @Test func aKeyOfTheWrongSizeIsNeverReplaced() {
        let odd = Data(repeating: 1, count: 16)
        let item = StandInKeyItem(.found(odd))
        #expect(throws: TraceKeyUnreadable.self) { try TraceKey.loadOrCreate(in: item) }
        #expect(item.added.isEmpty)
        #expect(item.lookup() == .found(odd), "left exactly as it was")
    }

    /// What the app holds for the launch: no log, and the sentence the Activity window shows.
    @MainActor @Test func theAppRunsWithoutTheLogAndSaysWhy() throws {
        let item = StandInKeyItem(.unreadable("Keychain error -25308"))
        let log = ActivityLog.open { try TraceStore(inMemory: true, keys: item) }
        #expect(log.store == nil)
        #expect(log.problem == ActivityLog.keyUnreadable)
        #expect(
            ActivityLog.keyUnreadable
                == "Activity can’t be shown or recorded right now because Latchkey couldn’t read the log’s key in the Keychain. Latchkey tries again each time it opens."
        )
        #expect(item.added.isEmpty, "opening the log wrote no key")
    }

    @MainActor @Test func anOpenLogHasNoProblemToShow() throws {
        let log = ActivityLog.open { try TraceStore(inMemory: true, keys: StandInKeyItem(.absent)) }
        #expect(log.store != nil)
        #expect(log.problem == nil)
    }

    @MainActor @Test func anyOtherFailureAlsoLeavesTheAppRunning() {
        let log = ActivityLog.open { throw CocoaError(.fileReadCorruptFile) }
        #expect(log.store == nil)
        #expect(log.problem == ActivityLog.cannotOpen)
    }

    /// The next launch tries again: once the key can be read, the log written under it is back.
    @MainActor @Test func theNextLaunchReadsTheOldLogAgain() throws {
        let dir = try TraceTests.scratch()
        defer { try? FileManager.default.removeItem(at: dir) }
        let item = StandInKeyItem(.absent)
        do {
            let first = try #require(ActivityLog.open { try TraceStore(directory: dir, keys: item) }.store)
            try first.record(
                Activity(at: Date(), tool: "files_read", arguments: "{}", result: "kept", isError: false, durationMS: 1)
            )
        }
        let key = try #require(item.added.first)

        item.set(.unreadable("stand-in failure"))
        #expect(ActivityLog.open { try TraceStore(directory: dir, keys: item) }.store == nil)
        #expect(item.added.count == 1, "no second key")

        item.set(.found(key))
        let again = try #require(ActivityLog.open { try TraceStore(directory: dir, keys: item) }.store)
        #expect(try again.recent(limit: 10).map(\.result) == ["kept"])
    }

    /// The pairing record has the same hazard: a record that is there but couldn't be read must
    /// not be deleted or written over by a launch.
    @Test func aPairingRecordThatCannotBeReadIsLeftAlone() throws {
        let vault = MemoryVault()
        try DeviceIdentity.save(
            relayURL: URL(string: "https://relay.example.com")!, deviceID: "dev_1", keyData: Data([1, 2, 3]),
            vault: vault)
        let record = try #require(vault.items["pairing"])
        vault.changes = []
        vault.unreadable = ["pairing"]

        #expect(DeviceIdentity.load(vault: vault, makeKey: { _ in SoftwareSigningKey() }) == nil)
        #expect(vault.items["pairing"] == record, "still there, unchanged")
        #expect(!vault.changes.contains { $0.hasSuffix(" pairing") }, "never written or deleted: \(vault.changes)")
        #expect(
            DeviceIdentity.missing(vault: vault) == "pairing record present but unreadable: stand-in failure",
            "and the start line says it is there")
        #expect(DeviceIdentity.missing(vault: MemoryVault()) == "missing pairing record")
    }
}
