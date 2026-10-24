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

/// Where the activity log's key lives. The app uses the Keychain; tests use memory, never the
/// real Keychain (the test app shares the installed app's Keychain).
protocol TraceKeyStore: Sendable {
    /// The key, made (256 random bits) and saved the first time.
    func loadOrCreate() throws -> SymmetricKey
    func delete()
}

extension Keychain {
    static let traceKeyAccount = "activity-log-key"
}

/// The key as a generic password in the login Keychain, readable after the first unlock, this
/// Mac only. Its access list trusts only the app that created it: another program asking for it
/// makes macOS ask the Owner first.
struct KeychainTraceKey: TraceKeyStore {
    private static var underTest: Bool { ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil }

    func loadOrCreate() throws -> SymmetricKey {
        guard !Self.underTest else { throw CocoaError(.featureUnsupported) }
        if let data = Keychain.read(account: Keychain.traceKeyAccount), data.count == 32 {
            return SymmetricKey(data: data)
        }
        let key = SymmetricKey(size: .bits256)
        try Keychain.write(key.withUnsafeBytes { Data($0) }, account: Keychain.traceKeyAccount)
        return key
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

@MainActor
final class TraceStore {
    static let retention: TimeInterval = 90 * 86_400  // FR-026 default
    static let defaultDirectory = URL.applicationSupportDirectory.appending(
        path: "Latchkey", directoryHint: .isDirectory)
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

    func recent(limit: Int) throws -> [Activity] {
        var d = FetchDescriptor<SealedActivity>(sortBy: [SortDescriptor(\.at, order: .reverse)])
        d.fetchLimit = limit
        return try container.mainContext.fetch(d).map(open)
    }

    @discardableResult
    func purge(olderThan cutoff: Date) throws -> Int {
        let old = try container.mainContext.fetch(
            FetchDescriptor<SealedActivity>(predicate: #Predicate { $0.at < cutoff }))
        old.forEach(container.mainContext.delete)
        try container.mainContext.save()
        return old.count
    }

    /// Decrypts an entry for display; one sealed with a lost key shows as unreadable.
    private func open(_ s: SealedActivity) -> Activity {
        if let box = try? AES.GCM.SealedBox(combined: s.sealed),
            let data = try? AES.GCM.open(box, using: key),
            var a = try? JSONDecoder().decode(Activity.self, from: data)
        {
            a.id = s.id
            return a
        }
        let unreadable = "This entry can’t be read: the activity log’s key is no longer in the Keychain."
        return Activity(
            id: s.id, at: s.at, tool: "unknown", arguments: unreadable, result: unreadable, isError: true, durationMS: 0
        )
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
