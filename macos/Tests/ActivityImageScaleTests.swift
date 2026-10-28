import Foundation
import Testing

@testable import Latchkey

/// A log like Toni's on 2026-10-27: a few hundred entries, about 19 MB, most of it screenshots
/// in computer-control results. The Activity window must open at once (its first page off the
/// main thread, the main thread doing only cheap work), and Export… must write the images too.
@Suite(.serialized) struct ActivityImageScaleTests {
    /// A result as computer control returns it: an image block of base64 JPEG.
    static func screenshot(_ n: Int, bytes: Int) -> String {
        let data = Data((0..<bytes).map { UInt8(truncatingIfNeeded: $0 &* 31 &+ n) }).base64EncodedString()
        return #"[{"type":"image","mimeType":"image/jpeg","data":""# + data
            + #""},{"type":"text","text":"screen \#(n)"}]"#
    }

    @MainActor @Test func aLogOfScreenshotsOpensQuickly() throws {
        let dir = try TraceTests.scratch()
        defer { try? FileManager.default.removeItem(at: dir) }
        let keys = MemoryTraceKey()
        let latest = MemoryLatestEntry()
        var timings: [(String, Double)] = []
        func time<T>(_ name: String, _ body: () throws -> T) rethrows -> T {
            let start = Date()
            let value = try body()
            timings.append((name, Date().timeIntervalSince(start)))
            return value
        }
        let now = Date()
        do {
            let trace = try TraceStore(directory: dir, keys: keys, latest: latest)
            for n in 0..<320 {
                let image = n % 4 == 0
                try trace.record(
                    Activity(
                        at: now.addingTimeInterval(Double(n - 400) * 60), tool: image ? "computer_look" : "shell_run",
                        arguments: #"{"command":"echo \#(n)"}"#,
                        result: image ? Self.screenshot(n, bytes: 180_000) : "output \(n)", isError: false,
                        durationMS: n, callID: "call_\(n)", device: "dev_1"))
            }
        }
        let trace = try time("open the log") { try TraceStore(directory: dir, keys: keys, latest: latest) }
        #expect(trace.diskBytes > 15_000_000, "about Toni's 19 MB")
        let first = try time("first page (200)") { try trace.reader.page(ActivityQuery(), limit: 200) }
        #expect(first.entries.count == 200)
        let rows = time("window rows") { first.entries.map(ActivityRow.init) }
        #expect(rows.allSatisfy { $0.summary.count <= ActivityRow.summaryLimit + 1 })
        // The details pane shows a screenshot as a line, not 240 KB of base64 in one Text.
        let shot = try #require(first.entries.first { $0.tool == "computer_look" })
        let preview = time("details preview") { ActivityFormat.preview(shot.result) }
        #expect(preview.count < 1000)
        #expect(preview.contains("image/jpeg image, 180 KB"))
        #expect(!preview.contains("AAAA"))
        let long = ActivityFormat.preview(String(repeating: "a", count: 200_000))
        #expect(long.count < ActivityFormat.previewLimit + 200)
        #expect(long.hasSuffix("(190000 more characters; Export… saves the whole entry)"))
        let recent = try time("menu (10 newest)") { try trace.recent(limit: 10) }
        _ = time("menu titles and lines") {
            recent.map { (ActivityFormat.title($0), ActivityFormat.clip($0.result), ActivityFormat.clip($0.arguments)) }
        }
        _ = try time("tamper check") { try trace.reader.check(expected: trace.expected) }
        _ = try time("calls for the audit check") { try trace.reader.calls() }

        let url = dir.appending(path: "export.jsonl")
        let exported = try time("export") { try trace.reader.export(ActivityQuery(), to: url) }
        #expect(exported == 320)
        let lines = try String(contentsOf: url, encoding: .utf8).split(separator: "\n")
        let images = lines.filter { $0.contains(#""type":"image""#) }
        #expect(images.count == 80, "every screenshot is in the export")
        let object = try #require(
            try JSONSerialization.jsonObject(with: Data(images[0].utf8)) as? [String: Any])
        let blocks = try #require(object["result"] as? [[String: Any]])
        #expect((blocks[0]["data"] as? String)?.count ?? 0 > 200_000, "the image whole, as JSON")

        for (name, seconds) in timings { print("image log: \(name): \(String(format: "%.3f", seconds)) s") }
        for (name, seconds) in timings where name != "export" {
            #expect(seconds < 1, "\(name) took \(seconds) s")
        }
    }
}
