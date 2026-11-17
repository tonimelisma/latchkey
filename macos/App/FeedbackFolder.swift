import Foundation

/// Claude's feedback reports as plain text files, one per report, in `Feedback` inside the app's
/// data folder (spec 001 FR-693), where a Claude session on this Mac can read them.
struct FeedbackFolder: Sendable {
    let directory: URL

    /// The installed app's folder (a Debug build has its own, `Latchkey Dev`).
    static var standard: FeedbackFolder {
        FeedbackFolder(
            directory: AppIdentity.current.supportDirectory.appending(path: "Feedback", directoryHint: .isDirectory))
    }

    /// "2026-11-16T213000Z-fb_….md": sorts by time, and the same report always gets the same name.
    static func fileName(_ r: FeedbackReport) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "yyyy-MM-dd'T'HHmmss'Z'"
        return "\(f.string(from: r.at))-\(r.id).md"
    }

    static func text(_ r: FeedbackReport) -> String {
        var lines = [
            "# \(r.summary.replacingOccurrences(of: "\n", with: " "))", "",
            "- Report: \(r.id)",
            "- Filed: \(r.at.formatted(.iso8601))",
            "- Claude app: \(r.client.isEmpty ? "(unknown)" : r.client)",
        ]
        if !r.machine.isEmpty { lines.append("- Machine: \(r.machine)") }
        lines += ["", "## Details", "", r.details.isEmpty ? "(none given)" : r.details, ""]
        return lines.joined(separator: "\n")
    }

    /// Writes each report not already there and answers with the ids that are now saved,
    /// including those saved before. A report that can't be written isn't in the answer, so the
    /// relay sends it again later.
    func save(_ reports: [FeedbackReport]) -> [String] {
        let fm = FileManager.default
        do {
            try fm.createDirectory(
                at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        } catch {
            return []
        }
        var saved: [String] = []
        for r in reports where r.isValid {
            let file = directory.appending(path: Self.fileName(r), directoryHint: .notDirectory)
            if fm.fileExists(atPath: file.path) {
                saved.append(r.id)
                continue
            }
            do {
                try Data(Self.text(r).utf8).write(to: file, options: [.atomic])
                try? fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
                saved.append(r.id)
            } catch {
                continue
            }
        }
        return saved
    }
}
