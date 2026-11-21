import Foundation

/// Latchkey's import folder (spec 013 FR-1301, FR-1303; plan D2): a `.csv` saved there, by the
/// one-touch export or by the Owner, is read once it stops changing, replaces every copy when the
/// whole file reads, and is overwritten and deleted at once either way.
enum SignInImport {
    enum Outcome: Equatable, Sendable {
        case imported(count: Int, codes: Int)
        case notAnExport
        case failed(String)

        /// What the Owner's notification says.
        var told: String {
            switch self {
            case .imported(let count, let codes):
                "Latchkey now holds \(count) sign-in\(count == 1 ? "" : "s") from Passwords"
                    + (codes > 0 ? ", \(codes) with verification codes" : "") + ". The exported file is deleted."
            case .notAnExport:
                "The file wasn't an export from Passwords, so Latchkey deleted it and kept the sign-ins it had."
            case .failed(let why):
                "Latchkey couldn't keep the sign-ins (\(why)) and deleted the exported file; it kept the ones it had."
            }
        }
    }

    static var folder: URL {
        AppIdentity.current.supportDirectory.appending(path: "Sign-in Import", directoryHint: .isDirectory)
    }

    /// Makes the folder: only the Owner's account can open it, and Time Machine leaves it out.
    static func prepare(_ folder: URL = folder) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: folder.path)
        var url = folder
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try url.setResourceValues(values)
    }

    /// Takes in every `.csv` in the folder that hasn't changed for a second; the outcome of each.
    static func check(folder: URL = folder, store: SignInStore = .shared, now: Date = Date()) -> [Outcome] {
        let fm = FileManager.default
        guard
            let names = try? fm.contentsOfDirectory(
                at: folder, includingPropertiesForKeys: [.contentModificationDateKey], options: [.skipsHiddenFiles])
        else { return [] }
        var out: [Outcome] = []
        for url in names where url.pathExtension.lowercased() == "csv" {
            let changed = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
            guard let changed, now.timeIntervalSince(changed) >= 1 else { continue }
            out.append(take(url, store: store, now: now))
        }
        return out
    }

    static func take(_ url: URL, store: SignInStore, now: Date) -> Outcome {
        defer { wipe(url) }
        guard let data = try? Data(contentsOf: url) else { return .failed("the file couldn't be read") }
        let logins: [SavedSignIn]
        do { logins = try PasswordsCSV.parse(data) } catch { return .notAnExport }
        do { try store.replace(with: logins, at: now) } catch {
            return .failed("the Keychain refused it: \(error.localizedDescription)")
        }
        return .imported(count: logins.count, codes: logins.filter { $0.otp != nil }.count)
    }

    /// Overwrites the file with zeros, then deletes it.
    static func wipe(_ url: URL) {
        if let h = try? FileHandle(forWritingTo: url) {
            let size = (try? h.seekToEnd()) ?? 0
            try? h.seek(toOffset: 0)
            try? h.write(contentsOf: Data(count: Int(size)))
            try? h.synchronize()
            try? h.close()
        }
        try? FileManager.default.removeItem(at: url)
    }
}
