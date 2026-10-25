import CryptoKit
import Foundation
import Security
import SwiftData

/// One tool call the Mac ran, as the app shows it (FR-026). Kept only on this Mac.
struct Activity: Identifiable, Sendable, Codable {
    var id = UUID()
    var at: Date
    var tool: String
    var arguments: String
    var result: String
    var isError: Bool
    var durationMS: Int
}

/// What is stored: only the time (so the 90-day purge can find old entries) and the sealed
/// entry. Tool, arguments, result, outcome, and duration are AES-GCM encrypted (FR-026a).
@Model
final class SealedActivity {
    var id: UUID
    var at: Date
    var sealed: Data

    init(id: UUID, at: Date, sealed: Data) {
        self.id = id
        self.at = at
        self.sealed = sealed
    }
}

/// The activity log before FR-026a, in plaintext: read once, encrypted into the new log, and
/// its file deleted (research.md "Encrypting the activity log").
@Model
final class TraceEntry {
    var at: Date
    var tool: String
    var arguments: String
    var result: String
    var isError: Bool
    var durationMS: Int

    init(at: Date, tool: String, arguments: String, result: String, isError: Bool, durationMS: Int) {
        self.at = at
        self.tool = tool
        self.arguments = arguments
        self.result = result
        self.isError = isError
        self.durationMS = durationMS
    }
}

/// What a look for one stored item found. "Unreadable" is not "absent": the item is there, and
/// whatever was encrypted or paired with it is lost the moment something writes over it.
enum StoredItem: Equatable, Sendable {
    case absent
    case found(Data)
    /// The item exists but its data can't be had; the text says why, for the log.
    case unreadable(String)
}

/// Where the activity log's key lives. The app uses the Keychain; tests use memory, never the
/// real Keychain (the test app has its own identity, `AppIdentity`, but still keeps no real data).
protocol TraceKeyStore: Sendable {
    /// The key, made (256 random bits) and saved only when there is none at all (FR-201).
    func loadOrCreate() throws -> SymmetricKey
    func delete()
}

/// The one place the key is kept, as the rule below sees it.
protocol TraceKeyItem: Sendable {
    func lookup() -> StoredItem
    /// Saves a new key. Never replaces one that is there.
    func add(_ data: Data) throws
}

/// The key exists but can't be used: the log is unavailable for this launch and the key is
/// left exactly as it is (FR-201).
struct TraceKeyUnreadable: Error, Equatable, LocalizedError {
    var reason: String
    var errorDescription: String? { "the activity log’s key is in the Keychain but can’t be read (\(reason))" }
}

enum TraceKey {
    static let size = 32  // AES-256

    /// The rule of FR-201: a new key only when no key exists at all. On 2026-10-24 a Keychain
    /// read that always failed made every launch write a new key over the real one, and the log
    /// written under it was unreadable for good.
    static func loadOrCreate(in item: any TraceKeyItem) throws -> SymmetricKey {
        switch item.lookup() {
        case .found(let data) where data.count == size:
            return SymmetricKey(data: data)
        case .found(let data):
            throw TraceKeyUnreadable(reason: "it has \(data.count) bytes, not \(size)")
        case .unreadable(let reason):
            throw TraceKeyUnreadable(reason: reason)
        case .absent:
            let key = SymmetricKey(size: .bits256)
            try item.add(key.withUnsafeBytes { Data($0) })
            return key
        }
    }
}

extension Keychain {
    static let traceKeyAccount = "activity-log-key"
}

/// The key as a generic password in the login Keychain, readable after the first unlock, this
/// Mac only. Its access list trusts only the app that created it: another program asking for it
/// makes macOS ask the Owner first.
struct KeychainTraceKey: TraceKeyStore, TraceKeyItem {
    private static var underTest: Bool { ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil }

    func loadOrCreate() throws -> SymmetricKey {
        guard !Self.underTest else { throw CocoaError(.featureUnsupported) }
        return try TraceKey.loadOrCreate(in: self)
    }

    func lookup() -> StoredItem { Keychain.lookup(account: Keychain.traceKeyAccount) }

    func add(_ data: Data) throws {
        guard !Self.underTest else { throw CocoaError(.featureUnsupported) }
        try Keychain.write(data, account: Keychain.traceKeyAccount, replacing: false)
    }

    func delete() {
        guard !Self.underTest else { return }
        Keychain.delete(account: Keychain.traceKeyAccount)
    }
}

final class MemoryTraceKey: TraceKeyStore, @unchecked Sendable {
    private let lock = NSLock()
    private var key: SymmetricKey?

    func loadOrCreate() throws -> SymmetricKey {
        lock.lock()
        defer { lock.unlock() }
        if let key { return key }
        let k = SymmetricKey(size: .bits256)
        key = k
        return k
    }

    func delete() {
        lock.lock()
        key = nil
        lock.unlock()
    }
}

/// What the Activity window shows: the entries, and how many more are stored but can't be read.
struct ActivityPage: Sendable {
    var entries: [Activity] = []
    /// Entries saved under a key that is no longer in the Keychain (FR-203).
    var unreadable = 0
}

/// The activity log for this launch: open, or unavailable with the sentence the app shows
/// (FR-201). The app works the same either way; without the log nothing is recorded.
@MainActor
enum ActivityLog {
    case available(TraceStore)
    case unavailable(String)

    static let keyUnreadable =
        "Activity can’t be shown or recorded right now because Latchkey couldn’t read the log’s key in the Keychain. Latchkey tries again each time it opens."
    static let cannotOpen =
        "Activity can’t be shown or recorded right now because the log couldn’t be opened. Latchkey tries again each time it opens."

    static func open(_ make: () throws -> TraceStore = { try TraceStore() }) -> ActivityLog {
        do {
            return .available(try make())
        } catch let error as TraceKeyUnreadable {
            AppModel.log.error("Activity log unavailable: \(error.localizedDescription, privacy: .public)")
            return .unavailable(keyUnreadable)
        } catch {
            AppModel.log.error("Activity log unavailable: \(error.localizedDescription, privacy: .public)")
            return .unavailable(cannotOpen)
        }
    }

    var store: TraceStore? { if case .available(let s) = self { s } else { nil } }
    var problem: String? { if case .unavailable(let why) = self { why } else { nil } }
}

@MainActor
final class TraceStore {
    static let retention: TimeInterval = 90 * 86_400  // FR-026 default
    static let defaultDirectory = AppIdentity.current.supportDirectory
    static let fileName = "activity.store"
    static let legacyFileName = "trace.store"

    let container: ModelContainer
    private let key: SymmetricKey

    init(directory: URL = TraceStore.defaultDirectory, keys: any TraceKeyStore = KeychainTraceKey()) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        key = try keys.loadOrCreate()
        container = try ModelContainer(
            for: SealedActivity.self, configurations: ModelConfiguration(url: directory.appending(path: Self.fileName)))
        try migrateLegacy(in: directory)
    }

    init(inMemory: Bool, keys: any TraceKeyStore) throws {
        key = try keys.loadOrCreate()
        container = try ModelContainer(
            for: SealedActivity.self, configurations: ModelConfiguration(isStoredInMemoryOnly: inMemory))
    }

    func record(_ a: Activity) throws {
        let sealed = try AES.GCM.seal(try JSONEncoder().encode(a), using: key).combined!
        container.mainContext.insert(SealedActivity(id: a.id, at: a.at, sealed: sealed))
        try container.mainContext.save()
    }

    /// The newest entries that can be read, for the menu. Entries that can't be read are passed
    /// over (FR-203); the search stops as soon as `limit` are found.
    func recent(limit: Int) throws -> [Activity] { try scan(limit: limit, all: false).entries }

    /// The newest readable entries, and how many stored entries can't be read (FR-203). Looks at
    /// the whole log, to count them.
    func page(limit: Int) throws -> ActivityPage { try scan(limit: limit, all: true) }

    /// Goes through the log newest first, a batch at a time.
    private func scan(limit: Int, all: Bool) throws -> ActivityPage {
        var page = ActivityPage()
        let batch = max(limit, 50)
        var offset = 0
        while all || page.entries.count < limit {
            var d = FetchDescriptor<SealedActivity>(sortBy: [SortDescriptor(\.at, order: .reverse)])
            d.fetchLimit = batch
            d.fetchOffset = offset
            let rows = try container.mainContext.fetch(d)
            for row in rows {
                if let activity = open(row) {
                    if page.entries.count < limit { page.entries.append(activity) }
                } else {
                    page.unreadable += 1
                }
            }
            if rows.count < batch { break }
            offset += batch
        }
        return page
    }

    @discardableResult
    func purge(olderThan cutoff: Date) throws -> Int {
        let old = try container.mainContext.fetch(
            FetchDescriptor<SealedActivity>(predicate: #Predicate { $0.at < cutoff }))
        old.forEach(container.mainContext.delete)
        try container.mainContext.save()
        return old.count
    }

    /// Decrypts an entry for display; nil for one sealed with a key that is gone. Such an entry
    /// is never shown as a tool run, least of all a failed one (FR-203).
    private func open(_ s: SealedActivity) -> Activity? {
        guard let box = try? AES.GCM.SealedBox(combined: s.sealed),
            let data = try? AES.GCM.open(box, using: key),
            var a = try? JSONDecoder().decode(Activity.self, from: data)
        else { return nil }
        a.id = s.id
        return a
    }

    /// Encrypts the plaintext log from before FR-026a into this one, then deletes its files.
    /// The files go even if they can't be read: plaintext must not stay on disk.
    private func migrateLegacy(in directory: URL) throws {
        let legacy = directory.appending(path: Self.legacyFileName)
        guard FileManager.default.fileExists(atPath: legacy.path) else { return }
        do {
            let old = try ModelContainer(for: TraceEntry.self, configurations: ModelConfiguration(url: legacy))
            let context = ModelContext(old)
            for e in try context.fetch(FetchDescriptor<TraceEntry>()) {
                try record(
                    Activity(
                        at: e.at, tool: e.tool, arguments: e.arguments, result: e.result, isError: e.isError,
                        durationMS: e.durationMS))
            }
        } catch {
            AppModel.log.error("Couldn't move the old activity log; deleting it: \(error.localizedDescription)")
        }
        for suffix in ["", "-wal", "-shm"] {
            try? FileManager.default.removeItem(at: directory.appending(path: Self.legacyFileName + suffix))
        }
    }
}
