import Foundation

/// Paths for attachment files. An attachment's name is written by the sender, so it never
/// becomes part of a path unchecked: files are named by Latchkey, and a file found on disk must
/// resolve inside the folder it was looked for in (security review, 2026-10-29).
enum MailPaths {
    /// One path component that can't leave its folder: no "/", ":", NUL, or control characters,
    /// no leading dot ("." and ".." included), at most 120 characters.
    static func safeName(_ name: String, fallback: String) -> String {
        var s = String(
            String.UnicodeScalarView(
                name.unicodeScalars.map {
                    $0 == "/" || $0 == ":" || $0 == "\\" || $0.properties.generalCategory == .control ? "_" : $0
                }))
        s = s.trimmingCharacters(in: .whitespacesAndNewlines)
        while s.hasPrefix(".") { s.removeFirst() }
        s = String(s.prefix(120))
        return s.isEmpty ? fallback : s
    }

    /// The name's extension when it is short and plain letters and digits ("pdf"), else "".
    static func safeExtension(_ name: String) -> String {
        guard let dot = name.lastIndex(of: ".") else { return "" }
        let ext = name[name.index(after: dot)...]
        guard (1...10).contains(ext.count), ext.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber) }) else {
            return ""
        }
        return ext.lowercased()
    }

    /// A file name Latchkey chooses, keeping only a plain extension (for the file's type).
    static func chosenName(for name: String) -> String {
        let ext = safeExtension(name)
        return UUID().uuidString + (ext.isEmpty ? "" : ".\(ext)")
    }

    /// The file, with symbolic links resolved, when it is a regular file inside `folder`; nil
    /// otherwise.
    static func inside(_ file: URL, _ folder: URL) -> URL? {
        let base = folder.resolvingSymlinksInPath().standardizedFileURL.path
        let resolved = file.standardizedFileURL.resolvingSymlinksInPath().standardizedFileURL
        guard resolved.path.hasPrefix(base + "/") else { return nil }
        let values = try? resolved.resourceValues(forKeys: [.isRegularFileKey])
        return values?.isRegularFile == true ? resolved : nil
    }
}
