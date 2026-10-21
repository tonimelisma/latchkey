import Foundation
import SwiftData
import Testing

@testable import Latchkey

@Suite struct TraceTests {
    @MainActor @Test func recordsAndPurges() throws {
        let trace = try TraceStore(inMemory: true)
        let now = Date()
        try trace.record(
            TraceEntry(
                at: now.addingTimeInterval(-91 * 86_400), tool: "battery_status",
                arguments: "{}", result: "{\"battery_percent\":80}", isError: false, durationMS: 12))
        try trace.record(
            TraceEntry(at: now, tool: "battery_status", arguments: "{}", result: "{}", isError: true, durationMS: 3))
        #expect(try trace.recent(limit: 10).count == 2)

        let removed = try trace.purge(olderThan: now.addingTimeInterval(-90 * 86_400))
        #expect(removed == 1, "FR-026: 90 days")
        let left = try trace.recent(limit: 10)
        #expect(left.count == 1)
        #expect(left.first?.isError == true)
    }
}
