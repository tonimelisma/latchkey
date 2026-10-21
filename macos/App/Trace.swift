import Foundation
import SwiftData

/// One tool call the Mac ran, with arguments and result (FR-026). Kept only on this Mac.
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

@MainActor
final class TraceStore {
    static let retention: TimeInterval = 90 * 86_400  // FR-026 default

    let container: ModelContainer

    init(inMemory: Bool = false) throws {
        let config: ModelConfiguration
        if inMemory {
            config = ModelConfiguration(isStoredInMemoryOnly: true)
        } else {
            let dir = URL.applicationSupportDirectory.appending(path: "Latchkey", directoryHint: .isDirectory)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            config = ModelConfiguration(url: dir.appending(path: "trace.store"))
        }
        container = try ModelContainer(for: TraceEntry.self, configurations: config)
    }

    func record(_ e: TraceEntry) throws {
        container.mainContext.insert(e)
        try container.mainContext.save()
    }

    func recent(limit: Int) throws -> [TraceEntry] {
        var d = FetchDescriptor<TraceEntry>(sortBy: [SortDescriptor(\.at, order: .reverse)])
        d.fetchLimit = limit
        return try container.mainContext.fetch(d)
    }

    @discardableResult
    func purge(olderThan cutoff: Date) throws -> Int {
        let old = try container.mainContext.fetch(FetchDescriptor<TraceEntry>(predicate: #Predicate { $0.at < cutoff }))
        old.forEach(container.mainContext.delete)
        try container.mainContext.save()
        return old.count
    }
}
