import Foundation

/// Programs a command started that macOS stopped (spec 004 FR-332): found in the crash reports
/// macOS writes for them, which name Latchkey as the responsible process. A command's own exit
/// status often hides them (a pipe's last program decides it), and an app that aborts inside
/// the fence shows a crash dialog on the owner's screen (headless Chrome, bug report 2026-11-03).
enum StoppedPrograms {
    struct Crash: Equatable, Sendable {
        var file: String
        var program: String
        var path: String
        var signal: String
        /// What the program said as it stopped ("abort() called"), when the report has it.
        var reason: String?
        var at: Date

        /// A program inside an app bundle: it registers as an app as it starts.
        var isApp: Bool { path.contains(".app/") }
    }

    static let folder = URL.homeDirectory.appending(path: "Library/Logs/DiagnosticReports", directoryHint: .isDirectory)

    /// Reports of programs that `responsible` started, stopped between `from` and `to`.
    static func find(in dir: URL, from: Date, to: Date, responsible: pid_t) -> [Crash] {
        let fm = FileManager.default
        let keys: Set<URLResourceKey> = [.contentModificationDateKey]
        guard let files = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: Array(keys)) else {
            return []
        }
        return files.filter { $0.pathExtension == "ips" }.compactMap { url -> Crash? in
            // Written after the stop, so never older than the job.
            guard let changed = try? url.resourceValues(forKeys: keys).contentModificationDate,
                changed >= from.addingTimeInterval(-1)
            else { return nil }
            guard let crash = parse(url), crash.responsible == responsible,
                crash.crash.at >= from.addingTimeInterval(-1),
                crash.crash.at <= to.addingTimeInterval(1)
            else { return nil }
            return crash.crash
        }.sorted { $0.at < $1.at }
    }

    private static func parse(_ url: URL) -> (crash: Crash, responsible: pid_t)? {
        guard let data = try? Data(contentsOf: url), let newline = data.firstIndex(of: UInt8(ascii: "\n")),
            let body = try? JSONSerialization.jsonObject(with: data[data.index(after: newline)...]) as? [String: Any],
            let responsible = body["responsiblePid"] as? Int, let program = body["procName"] as? String,
            let captured = (body["captureTime"] as? String).flatMap(captureTime.date(from:))
        else { return nil }
        let exception = body["exception"] as? [String: Any]
        let reason = (body["asi"] as? [String: Any])?.values.compactMap { ($0 as? [String])?.first }.first
        return (
            Crash(
                file: url.lastPathComponent, program: program, path: body["procPath"] as? String ?? "",
                signal: exception?["signal"] as? String ?? exception?["type"] as? String ?? "stopped", reason: reason,
                at: captured),
            pid_t(responsible)
        )
    }

    /// "2026-11-03 19:53:57.8874 -0800"
    private static let captureTime: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd HH:mm:ss.SSSS Z"
        return f
    }()

    /// The note added to the answer; `job` when it is about an earlier job than the one answered.
    static func note(_ crashes: [Crash], job: String?, usesOpen: Bool) -> String {
        var names: [String] = []
        var counts: [String: Int] = [:]
        var first: [String: Crash] = [:]
        for c in crashes {
            if counts[c.program] == nil {
                names.append(c.program)
                first[c.program] = c
            }
            counts[c.program, default: 0] += 1
        }
        let listed = names.map { name in
            let c = first[name]!
            let why = [c.signal, c.reason].compactMap { $0 }.joined(separator: ", ")
            let times = counts[name]! > 1 ? ", \(counts[name]!) times" : ""
            return "\(name) (\(why)\(times))"
        }.joined(separator: "; ")
        var text = (job.map { "[In \($0), " } ?? "[") + "macOS stopped a program the command started: \(listed)."
        if crashes.contains(where: \.isApp) {
            text +=
                usesOpen
                ? " An app's own sandbox can't start inside the fence: run it without (Chrome and other Chromium apps: --no-sandbox)."
                : #" A program with windows (an app such as Chrome or Preview, even headless) can't start inside the fence unless the command declares uses ["open"]; Chrome and other Chromium apps also need --no-sandbox."#
        }
        return text + " Don't run it again unchanged.]"
    }
}
