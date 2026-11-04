import Foundation

/// The fence around a Shell command's writes (spec 004 FR-317 to FR-319, plan D9): macOS's
/// sandbox, given as a profile to `sandbox-exec`. It applies to the shell and everything it
/// starts, for as long as they run.
enum Fence {
    /// Caches package tools write without being asked (research.md).
    static let caches = ["Library/Caches", ".cache", ".npm"]
    /// Programs macOS won't start inside a sandbox (they read other processes), started outside
    /// the fence instead; they write nothing (live check 2026-10-27: `ps` and `top` failed).
    static let unfenced = ["/bin/ps", "/usr/bin/top"]

    /// What a command may reach beyond the fence once declared in `uses` (FR-328).
    enum Use: String, CaseIterable, Sendable {
        /// Opening apps, files, and links through macOS (`open`), which starts them outside the fence.
        case open
    }

    /// macOS's services for opening apps, for sending Apple Events, and for changing settings
    /// (research.md, "Handing work to macOS"). Opening fails at once without the first; a script
    /// sent without the second fails within a second.
    static let launchServices = [
        "com.apple.coreservices.launchservicesd", "com.apple.lsd.mapdb", "com.apple.lsd.modifydb", "com.apple.lsd.open",
    ]
    static let appleEvents = "com.apple.coreservices.appleevents"
    /// Always refused: settings are then read from their files and changed only by writing the
    /// declared domain's file, which the fence scopes (Latchkey's own settings never; FR-329).
    static let settingsService = ["com.apple.cfprefsd.daemon", "com.apple.cfprefsd.agent"]
    /// Always refused, so a script fails at once, not after a wait: scripting other apps is never
    /// done from Shell (Toni, 2026-10-29), since a script must run outside the fence to reach an
    /// app and could then run anything.
    static let scriptRunner = "/usr/bin/osascript"

    /// The job's mark beside its scratch folder: its fence refuses reading it, which tells the
    /// job's processes apart from every other process wherever they went (FR-327).
    static func mark(of scratch: URL) -> URL {
        scratch.deletingLastPathComponent().appending(path: scratch.lastPathComponent + ".mark")
    }

    /// An empty file beside the mark that the job's fence lets it read: another sandbox treats
    /// the two alike, since only the job's own names the mark (the font service's refuses every
    /// file but no folder, live check 2026-10-29).
    static func control(of scratch: URL) -> URL {
        scratch.deletingLastPathComponent().appending(path: scratch.lastPathComponent + ".open")
    }

    /// Places that make something run again: writable only when declared (FR-319).
    static let permanent = [
        ".zshrc", ".zprofile", ".zshenv", ".zlogin", ".zlogout", ".bashrc", ".bash_profile", ".profile",
        "Library/LaunchAgents", "Library/Application Support/com.apple.backgroundtaskmanagementagent", ".ssh",
    ]
    /// Git hooks run on every commit in their project, wherever it is: any `.git/hooks`, a
    /// submodule's included, in any letter case since the Mac's disks ignore it (FR-319).
    static let hooks = #"(regex #"/\.[gG][iI][tT]/([^/]+/)*[hH][oO][oO][kK][sS](/|$)")"#
    /// What `git init` and `git clone` write there, inside the folders a command may write
    /// anyway: creating and deleting the hooks folder, and the samples as plain files, which git
    /// never runs (live check 2026-10-28: every new project outside scratch failed without them,
    /// and a cloned project couldn't be deleted). Renaming another folder into its place is a
    /// known gap (research.md).
    static func hookSamples(in allowed: [String]) -> [String] {
        let within = "(require-any " + allowed.map { "(subpath \(quote($0)))" }.joined(separator: " ") + ")"
        let folder = #"(regex #"/\.[gG][iI][tT]/([^/]+/)*[hH][oO][oO][kK][sS]$")"#
        let sample = #"(regex #"/\.[gG][iI][tT]/([^/]+/)*[hH][oO][oO][kK][sS]/[^/]+\.sample$")"#
        return [
            "(allow file-write-create file-write-unlink (require-all (vnode-type DIRECTORY) \(folder) \(within)))",
            "(allow file-write* (require-all (vnode-type REGULAR-FILE) \(sample) \(within)))",
        ]
    }

    /// The paths Claude declared, resolved; too broad ones are refused (FR-318).
    static func declared(_ writes: [String], home: URL) throws -> [URL] {
        try writes.map { raw in
            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { throw ShellJobs.Failure(message: "A path in writes is empty.") }
            let expanded =
                trimmed == "~"
                ? home.path
                : trimmed.hasPrefix("~/") ? home.path + String(trimmed.dropFirst(1)) : trimmed
            guard expanded.hasPrefix("/") else {
                throw ShellJobs.Failure(message: "Give writes as full paths (or starting with ~/): \(raw)")
            }
            let url = OwnFiles.real(URL(filePath: expanded).standardizedFileURL)
            if tooBroad(url, home: home) {
                throw ShellJobs.Failure(
                    message:
                        "\(raw) is too broad to declare: it would let the command write anywhere in it. Declare the specific folders or files it writes."
                )
            }
            return url
        }
    }

    /// True when `url` is one of the permanent places or inside one, or holds one.
    static func isPermanent(_ url: URL, home: URL) -> Bool {
        let parts = OwnFiles.parts(url)
        if let git = parts.firstIndex(of: ".git"), parts[(git + 1)...].contains("hooks") { return true }
        return permanent.contains { place in
            let p = OwnFiles.parts(home.appending(path: place))
            return parts.starts(with: p) || p.starts(with: parts)
        }
    }

    /// True when making `folder` writable would open the home folder, a folder above it, or the
    /// whole Library folder (FR-317, FR-318).
    static func tooBroad(_ folder: URL, home: URL) -> Bool {
        let homeParts = OwnFiles.parts(home)
        let parts = OwnFiles.parts(folder)
        return homeParts.starts(with: parts) || parts == homeParts + ["library"]
    }

    static func profile(
        scratch: URL, folder: URL, declared: [URL], home: URL, own: OwnFiles, uses: Set<Use> = [],
        mark: URL? = nil, systemTemp: URL? = nil
    ) -> String {
        let realHome = OwnFiles.real(home)
        var allowed = ["/dev", OwnFiles.real(scratch).path]
        // The user's own temporary and cache folders under /private/var/folders (…/T, …/C).
        if let systemTemp { allowed.append(systemTemp.path) }
        allowed.append(realHome.appending(path: "Downloads").path)
        allowed += caches.map { realHome.appending(path: $0).path }
        let working = OwnFiles.real(folder)
        if !tooBroad(working, home: realHome) { allowed.append(working.path) }
        allowed += declared.map(\.path)
        var rules = [
            "(version 1)", "(allow default)", "(deny file-write*)",
            "(allow file-write* " + allowed.map { "(subpath \(quote($0)))" }.joined(separator: " ") + ")",
            // bash's here-document files, deleted as soon as read; Homebrew clears TMPDIR before
            // its bash runs, so they land in /tmp (live check 2026-10-27). bash first checks that
            // /tmp itself is writable, which the folder rule allows; files in it stay fenced.
            // zsh's (here-documents, =(…)) are /tmp/zsh… when a zsh runs without the job's
            // TMPPREFIX (bug report 2026-11-03).
            "(allow file-write* (literal \"/private/tmp\") (regex #\"^/private/tmp/sh-thd[^/]*$\")"
                + " (regex #\"^/private/tmp/zsh[^/]*$\"))",
        ]
        let permanentPaths = permanent.map { OwnFiles.real(realHome.appending(path: $0)) }
        rules.append(
            "(deny file-write* " + permanentPaths.map { "(subpath \(quote($0.path)))" }.joined(separator: " ") + " "
                + hooks + ")")
        rules += hookSamples(in: allowed)
        // The other jobs' scratch folders and the records of their processes are Latchkey's
        // (the app stops and trashes by them at start, FR-324): only the job's own scratch.
        let jobsRoot = OwnFiles.real(scratch).deletingLastPathComponent()
        rules.append("(deny file-write* (subpath \(quote(jobsRoot.path))))")
        rules.append("(allow file-write* (subpath \(quote(OwnFiles.real(scratch).path))))")
        let declaredPermanent = declared.filter { isPermanent($0, home: realHome) }
        if !declaredPermanent.isEmpty {
            rules.append(
                "(allow file-write* " + declaredPermanent.map { "(subpath \(quote($0.path)))" }.joined(separator: " ")
                    + ")")
        }
        // Latchkey's own files, never (FR-319).
        var ownRules = own.folders.map { "(subpath \(quote(OwnFiles.real($0).path)))" }
        for folder in own.settingsFolders {
            for prefix in own.settingsPrefixes {
                let start = OwnFiles.real(folder).path + "/" + prefix + "."
                ownRules.append("(regex #\"^\(regexEscape(start))\")")
            }
        }
        if !ownRules.isEmpty { rules.append("(deny file-write* " + ownRules.joined(separator: " ") + ")") }
        // What macOS would do for the command outside the fence (FR-328, FR-329).
        func services(_ names: [String]) -> String {
            "(deny mach-lookup (global-name " + names.map(quote).joined(separator: " ") + "))"
        }
        if !uses.contains(.open) { rules.append(services(launchServices)) }
        rules += [
            services([appleEvents]), "(deny appleevent-send)", "(deny process-exec (literal \(quote(scriptRunner))))",
        ]
        rules.append(services(settingsService))
        if let mark { rules.append("(deny file-read* (literal \(quote(OwnFiles.real(mark).path))))") }
        rules.append(
            "(allow process-exec " + unfenced.map { "(literal \(quote($0)))" }.joined(separator: " ")
                + " (with no-sandbox))")
        return rules.joined(separator: "\n")
    }

    private static func quote(_ s: String) -> String {
        "\"" + s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }

    private static func regexEscape(_ s: String) -> String {
        var out = ""
        for c in s {
            if "\\^$.|?*+()[]{}\"".contains(c) { out.append("\\") }
            out.append(c)
        }
        return out
    }

    /// Added to an answer whose output shows a refused open or script (FR-328).
    static let handoffHint =
        "[Opening apps, files, or links through macOS (open) is refused unless declared: what it starts runs outside the fence; run it again with uses [\"open\"] if the owner's task needs it. Scripting other apps (osascript) isn't possible from Shell: use Latchkey's own tools for Notes, Messages, Calendar, Reminders, Contacts, Safari, or Computer control. Starting background services (launchctl, brew services) isn't possible either.]"

    /// Added to an answer whose output shows a refused change of settings (FR-329).
    static let settingsHint =
        "[Changing settings (defaults write) is refused unless declared: run it again with writes [\"~/Library/Preferences/<domain>.plist\"] and why.]"

    /// What an output shows was refused (FR-320, FR-328, FR-329).
    static func refusals(in text: String) -> (write: Bool, handoff: Bool, settings: Bool) {
        let lines = text.split(separator: "\n").map { $0.lowercased() }
        let script = lines.contains {
            $0.contains("operation not permitted: osascript") || $0.contains("osascript: operation not permitted")
        }
        let handoff =
            script
            || [
                "unable to find application", "kLSExecutableIncorrectFormat", "(-10814)",
                "no application knows how to open",
                "application isn’t running. (-600)", "application isn't running. (-600)",
            ].contains { needle in
                lines.contains { $0.contains(needle.lowercased()) }
            }
        let write = lines.contains {
            $0.contains("operation not permitted") && !$0.contains("osascript")
        }
        let settings = lines.contains { $0.contains("could not write domain") }
        return (write, handoff, settings)
    }

    /// Added too while Latchkey lacks Full Disk Access (spec 001 FR-625).
    static let privacyHint =
        "[Or macOS's privacy protection refused a read: Latchkey doesn't have Full Disk Access. The Mac's owner can turn it on in System Settings → Privacy & Security → Full Disk Access.]"

    /// Added to an answer whose output shows a refused write (FR-320).
    static let hint =
        "[A write was refused: a command writes only to its scratch folder ($LATCHKEY_SCRATCH, also $TMPDIR, emptied after it), the folder it runs in (unless that is the home folder), Downloads, and package caches. To write somewhere else, run it again with writes (the folders or files) and why.]"
}

/// What a command left, for its answer and the Left Behind list (spec 004 FR-321, FR-323).
enum Leftovers {
    struct Found: Equatable, Sendable {
        var files: [URL]
        /// Files beyond those listed.
        var more: Int
    }

    static let listed = 20
    static let looked = 2000

    /// Files new or changed since `since` in the given places (declared paths and Downloads).
    static func results(since: Date, in places: [URL]) -> Found {
        let fm = FileManager.default
        let keys: [URLResourceKey] = [.contentModificationDateKey, .creationDateKey, .isRegularFileKey]
        let after = since.addingTimeInterval(-1)
        var files: [URL] = []
        var count = 0
        var seen = Set<String>()
        func fresh(_ url: URL) -> Bool {
            guard let v = try? url.resourceValues(forKeys: Set(keys)), v.isRegularFile == true else { return false }
            return (v.contentModificationDate ?? .distantPast) >= after || (v.creationDate ?? .distantPast) >= after
        }
        func note(_ url: URL) {
            guard seen.insert(url.path).inserted else { return }
            count += 1
            if files.count < listed { files.append(url) }
        }
        var visited = 0
        for place in places {
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: place.path, isDirectory: &isDir) else { continue }
            if !isDir.boolValue {
                if fresh(place) { note(place) }
                continue
            }
            guard
                let walk = fm.enumerator(
                    at: place, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles, .skipsPackageDescendants])
            else { continue }
            for case let url as URL in walk {
                visited += 1
                if visited > looked { break }
                if fresh(url) { note(url) }
            }
        }
        return Found(files: files, more: count - files.count)
    }

    struct Report: Equatable {
        /// For Claude, in the answer.
        var answer: String
        /// For the Left Behind list; nil when the command left nothing at all.
        var entry: String?
    }

    static func describe(
        job: String, command: String, stopped: [String], stuck: [String], scratch: Bool, kept: Found,
        permanent: [URL], why: String?, home: URL
    ) -> Report {
        var parts: [String] = []
        if !stopped.isEmpty { parts.append("stopped what it left running: \(stopped.joined(separator: ", "))") }
        if !stuck.isEmpty { parts.append("couldn't stop: \(stuck.joined(separator: ", "))") }
        if scratch { parts.append("moved its scratch folder to the Trash") }
        if !kept.files.isEmpty {
            let names = kept.files.map { short($0, home: home) }.joined(separator: ", ")
            parts.append("kept the new files \(names)" + (kept.more > 0 ? " and \(kept.more) more" : ""))
        }
        if !permanent.isEmpty {
            parts.append(
                "permanent change, as declared: " + permanent.map { short($0, home: home) }.joined(separator: ", "))
        }
        guard !parts.isEmpty else { return Report(answer: "[Left behind: nothing]", entry: nil) }
        let text = parts.joined(separator: "; ")
        let reason = why.map { " (\(clip($0)))" } ?? ""
        return Report(
            answer: "[Left behind: \(text)]",
            entry: "\(job), \(clip(command))\(reason): \(text)")
    }

    static func kept(until end: Date, job: String) -> String {
        "[Left behind: kept running, with its scratch folder, until \(end.formatted(clock)); check \(job) to keep them longer]"
    }

    /// Times in answers name their zone ("23:43 PDT"), as job lists give UTC (live check 2026-10-27).
    static let clock = Date.FormatStyle().hour().minute().timeZone(.specificName(.short))

    static func short(_ url: URL, home: URL) -> String {
        let h = OwnFiles.real(home).path
        return url.path.hasPrefix(h + "/") ? "~" + url.path.dropFirst(h.count) : url.path
    }

    static func clip(_ s: String) -> String { s.count > 80 ? String(s.prefix(79)) + "…" : s }
}

/// Watches the permanent places (spec 004 FR-325, plan D11): the home folder's top level for the
/// shell startup files, the launch agents folder, and the login items folder, each with a
/// `DispatchSource` (no recursive watch). Calls `changed` with each path whose modification
/// date, or whose presence, changed.
final class PermanentWatch: @unchecked Sendable {
    private let lock = NSLock()
    private let home: URL
    private let changed: @Sendable (URL) -> Void
    private let queue = DispatchQueue(label: "latchkey.permanent-watch", qos: .utility)
    private var sources: [String: DispatchSourceFileSystemObject] = [:]
    private var seen: [String: Date] = [:]

    init(home: URL, changed: @escaping @Sendable (URL) -> Void) {
        self.home = home
        self.changed = changed
        queue.async { self.rescan(report: false) }
    }

    deinit { lock.withLock { sources.values.forEach { $0.cancel() } } }

    /// The files whose dates are compared, and the folders and files watched for events.
    private func places() -> (files: [URL], watched: [URL]) {
        let fm = FileManager.default
        // Not ~/.ssh: ssh itself updates known_hosts on ordinary connections.
        let startup = Fence.permanent.filter { !$0.contains("/") && $0 != ".ssh" }.map { home.appending(path: $0) }
        let folders = ["Library/LaunchAgents", "Library/Application Support/com.apple.backgroundtaskmanagementagent"]
            .map { home.appending(path: $0, directoryHint: .isDirectory) }
        var files = startup
        for folder in folders {
            files += ((try? fm.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? [])
        }
        let watched = [home] + folders + files.filter { fm.fileExists(atPath: $0.path) }
        return (files, watched)
    }

    private func rescan(report: Bool) {
        let (files, watched) = places()
        var now: [String: Date] = [:]
        for f in files {
            if let d = try? f.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate {
                now[f.path] = d
            }
        }
        let before = lock.withLock { () -> [String: Date] in
            defer { seen = now }
            return seen
        }
        if report {
            for path in Set(before.keys).union(now.keys) where before[path] != now[path] {
                changed(URL(filePath: path))
            }
        }
        rewatch(watched)
    }

    private func rewatch(_ urls: [URL]) {
        lock.withLock {
            let wanted = Set(urls.map(\.path))
            for (path, source) in sources where !wanted.contains(path) {
                source.cancel()
                sources[path] = nil
            }
            for path in wanted where sources[path] == nil {
                let fd = open(path, O_EVTONLY)
                guard fd >= 0 else { continue }
                let source = DispatchSource.makeFileSystemObjectSource(
                    fileDescriptor: fd, eventMask: [.write, .extend, .delete, .rename, .attrib], queue: queue)
                source.setEventHandler { [weak self] in self?.rescan(report: true) }
                source.setCancelHandler { close(fd) }
                source.resume()
                sources[path] = source
            }
        }
    }
}
