import Foundation

/// Reads notes by asking Notes itself, for a database layout Latchkey doesn't know (plan D2).
/// Slower than the database and without checklist state or images, but it keeps reading working
/// after a macOS update.
struct NotesScriptReader: NotesReader {
    let scripts: any ScriptRunner
    var knowsContents: Bool { false }

    func image(note: String, attachment: String) async throws -> NotesStore.Image {
        throw NotesStore.Failure.notAnImage(attachment)
    }

    /// Notes' scripting ids serve as note ids here.
    func identifier(forScriptID scriptID: String) async throws -> String? { scriptID }

    func folders() async throws -> [NotesStore.Folder] {
        try await lines(Script.folders, []).map { f in
            NotesStore.Folder(id: f[0], name: f[0], noteCount: Int(f[safe: 1] ?? "") ?? 0)
        }
    }

    func search(_ query: String, folder: String?, limit: Int) async throws -> [NotesStore.Summary] {
        try await lines(Script.search, [query, folder ?? "", String(limit)]).map { f in
            NotesStore.Summary(
                id: f[0], title: f[safe: 1] ?? "", folder: f[safe: 2] ?? "", modified: Self.date(f[safe: 3]),
                snippet: "", locked: f[safe: 4] == "true")
        }
    }

    func read(id: String) async throws -> NotesStore.Note {
        let out = try await scripts.run(Script.read, [id])
        let parts = out.split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: false)
        let f = parts[0].split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
        let locked = f[safe: 3] == "true"
        return NotesStore.Note(
            id: id, title: f[0], folder: f[safe: 1] ?? "", created: nil, modified: Self.date(f[safe: 2]),
            locked: locked, text: locked ? "" : parts.count > 1 ? String(parts[1]) : "", attachments: [],
            scriptID: id)
    }

    private func lines(_ script: String, _ args: [String]) async throws -> [[String]] {
        try await scripts.run(script, args).split(separator: "\n").map {
            $0.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
        }
    }

    /// AppleScript's «class isot» text: local time, no zone.
    static func date(_ s: String?) -> Date {
        guard let s else { return .distantPast }
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd'T'HH:mm:ss"
        return f.date(from: s) ?? .distantPast
    }

    enum Script {
        static let folders = """
            on run argv
            set out to ""
            tell application "Notes"
            repeat with f in folders
            set out to out & (name of f) & tab & (count of notes of f) & linefeed
            end repeat
            end tell
            return out
            end run
            """
        static let search = """
            on run argv
            set q to item 1 of argv
            set folderName to item 2 of argv
            set maxCount to (item 3 of argv) as integer
            set out to ""
            set found to 0
            tell application "Notes"
            if folderName is "" then
            set candidates to notes
            else
            set candidates to notes of folder folderName
            end if
            repeat with n in candidates
            if found ≥ maxCount then exit repeat
            if q is "" or (name of n contains q) or ((not password protected of n) and (plaintext of n contains q)) then
            set out to out & (id of n) & tab & (name of n) & tab & (name of container of n) & tab & ((modification date of n) as «class isot» as string) & tab & (password protected of n) & linefeed
            set found to found + 1
            end if
            end repeat
            end tell
            return out
            end run
            """
        static let read = """
            on run argv
            tell application "Notes"
            set n to note id (item 1 of argv)
            set head to (name of n) & tab & (name of container of n) & tab & ((modification date of n) as «class isot» as string) & tab & (password protected of n)
            if password protected of n then return head
            return head & linefeed & (plaintext of n)
            end tell
            end run
            """
    }
}

/// What the Notes tools read through: the database, or Notes itself as a fallback.
protocol NotesReader: Sendable {
    /// Whether checklists and attachments are visible, so changes can be checked (FR-106).
    var knowsContents: Bool { get }
    func folders() async throws -> [NotesStore.Folder]
    func search(_ query: String, folder: String?, limit: Int) async throws -> [NotesStore.Summary]
    func read(id: String) async throws -> NotesStore.Note
    func image(note: String, attachment: String) async throws -> NotesStore.Image
    func identifier(forScriptID scriptID: String) async throws -> String?
}

extension NotesStore: NotesReader {
    var knowsContents: Bool { true }
}

extension Array {
    subscript(safe i: Int) -> Element? { indices.contains(i) ? self[i] : nil }
}
