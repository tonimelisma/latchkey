import Foundation
import UniformTypeIdentifiers

/// Saving a file from the web into the Owner's Downloads folder (spec 005 FR-438), and reading a
/// file of the Mac's to attach to a page (FR-437).
enum BrowserDownloads {
    /// The most a file saved from a page may be: it comes through the page as text (base64).
    static let pageLimit = 50_000_000
    /// The most a file fetched by Latchkey itself may be.
    static let directLimit = 500_000_000
    /// The most the files attached in one action may be together: they go into the page as text.
    static let attachLimit = 30_000_000

    static var downloads: URL { FileManager.default.homeDirectoryForCurrentUser.appending(path: "Downloads") }

    /// The name to save as: the server's (Content-Disposition), else the link's `download` name,
    /// else the address's last part, else "download"; made safe for a file name (no folders, no
    /// leading dot, no control characters, at most 200 characters), with the extension the type
    /// has when the name has none.
    static func name(disposition: String?, suggested: String?, address: String, type: String?) -> String {
        var candidates: [String] = []
        if let d = disposition, let n = fromDisposition(d) { candidates.append(n) }
        if let s = suggested { candidates.append(s) }
        if let u = URL(string: address), u.scheme?.hasPrefix("http") == true {
            let last = u.lastPathComponent
            if last != "/" { candidates.append(last.removingPercentEncoding ?? last) }
        }
        var name = candidates.lazy.map(clean).first { !$0.isEmpty } ?? "download"
        if (name as NSString).pathExtension.isEmpty, let mime = type?.split(separator: ";").first,
            let ext = UTType(mimeType: mime.trimmingCharacters(in: .whitespaces))?.preferredFilenameExtension
        {
            name += "." + ext
        }
        return name
    }

    /// filename*=UTF-8''… (RFC 6266) before filename="…".
    static func fromDisposition(_ d: String) -> String? {
        for part in d.split(separator: ";").map({ $0.trimmingCharacters(in: .whitespaces) }) {
            let lower = part.lowercased()
            if lower.hasPrefix("filename*=") {
                let value = part.dropFirst("filename*=".count)
                if let r = value.range(of: "''") { return String(value[r.upperBound...]).removingPercentEncoding }
            }
        }
        for part in d.split(separator: ";").map({ $0.trimmingCharacters(in: .whitespaces) }) {
            if part.lowercased().hasPrefix("filename=") {
                return String(part.dropFirst("filename=".count)).trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
            }
        }
        return nil
    }

    static func clean(_ s: String) -> String {
        var out = String(
            s.unicodeScalars.map { c -> Character in
                if CharacterSet.controlCharacters.contains(c) || c == "/" || c == ":" || c == "\\" { return "-" }
                return Character(c)
            })
        out = out.trimmingCharacters(in: .whitespacesAndNewlines)
        while out.hasPrefix(".") { out.removeFirst() }
        if out.count > 200 {
            let ext = (out as NSString).pathExtension
            out = String(out.prefix(200 - ext.count - 1)) + (ext.isEmpty ? "" : "." + ext)
        }
        return out
    }

    /// A place in `folder` for `name` that nothing has yet: "name.pdf", then "name 2.pdf", ….
    static func free(_ name: String, in folder: URL) -> URL {
        let base = (name as NSString).deletingPathExtension
        let ext = (name as NSString).pathExtension
        var n = 1
        while true {
            let candidate = n == 1 ? name : "\(base) \(n)" + (ext.isEmpty ? "" : "." + ext)
            let url = folder.appending(path: candidate)
            if !FileManager.default.fileExists(atPath: url.path) { return url }
            n += 1
        }
    }

    /// Writes `data` as a new file (never over another) and marks it as downloaded from the web,
    /// as Safari does, so macOS checks it before it is opened.
    static func save(_ data: Data, name: String, from address: String, in folder: URL = downloads) throws -> URL {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        for _ in 0..<20 {
            let url = free(name, in: folder)
            if FileManager.default.createFile(atPath: url.path, contents: nil, attributes: [.posixPermissions: 0o644]) {
                let h = try FileHandle(forWritingTo: url)
                defer { try? h.close() }
                try h.write(contentsOf: data)
                quarantine(url, from: address)
                return url
            }
        }
        throw SafariBrowser.Failure.failed("Latchkey couldn't save the file in \(folder.path).")
    }

    /// Moves a file Latchkey downloaded itself into `folder` under a free name.
    static func move(_ file: URL, name: String, from address: String, in folder: URL = downloads) throws -> URL {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = free(name, in: folder)
        try FileManager.default.moveItem(at: file, to: url)
        quarantine(url, from: address)
        return url
    }

    /// The quarantine mark browsers put on downloads (`com.apple.quarantine`).
    static func quarantine(_ url: URL, from address: String) {
        let value = String(format: "0081;%08x;Latchkey;", Int(Date().timeIntervalSince1970))
        _ = value.withCString { v in
            setxattr(url.path, "com.apple.quarantine", v, strlen(v), 0, 0)
        }
    }

    /// Fetches `address` with the Owner's Safari cookies, as Safari would (for a file the page
    /// itself may not fetch: another site's, without its permission). At most `limit` bytes.
    static func fetchDirect(_ address: String, limit: Int = directLimit, cookies: [HTTPCookie]) async throws -> (
        file: URL, type: String?, disposition: String?, final: String
    ) {
        guard let url = URL(string: try SafariBrowser.normalize(address)), url.scheme?.hasPrefix("http") == true else {
            throw SafariBrowser.Failure.failed("Only web addresses (http and https) can be saved.")
        }
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 20
        config.timeoutIntervalForResource = 25
        config.httpAdditionalHeaders = ["User-Agent": LockedBrowser.safariUserAgent]
        let jar = HTTPCookieStorage()
        jar.cookieAcceptPolicy = .always
        for c in cookies { jar.setCookie(c) }
        config.httpCookieStorage = jar
        let session = URLSession(configuration: config)
        defer { session.finishTasksAndInvalidate() }
        let (file, response) = try await session.download(from: url)
        let http = response as? HTTPURLResponse
        if let status = http?.statusCode, !(200..<300).contains(status) {
            try? FileManager.default.removeItem(at: file)
            throw SafariBrowser.Failure.failed("The site answered \(status) for \(url.host() ?? address).")
        }
        let size = (try? FileManager.default.attributesOfItem(atPath: file.path)[.size] as? Int) ?? 0
        if size > limit {
            try? FileManager.default.removeItem(at: file)
            throw SafariBrowser.Failure.failed("The file is \(size / 1_000_000) MB; Latchkey saves at most \(limit / 1_000_000) MB.")
        }
        return (
            file, http?.value(forHTTPHeaderField: "Content-Type"), http?.value(forHTTPHeaderField: "Content-Disposition"),
            response.url?.absoluteString ?? address
        )
    }

    /// The files to attach, read from the Mac (any file the Owner's account can read): a path
    /// may start with ~. At most `attachLimit` together; folders are refused.
    static func attachments(_ paths: [String], limit: Int = attachLimit) throws -> [PageScripts.Attachment] {
        guard !paths.isEmpty else { throw SafariBrowser.Failure.failed("Give the file's path.") }
        var out: [PageScripts.Attachment] = []
        var total = 0
        for p in paths {
            let url = URL(filePath: (p as NSString).expandingTildeInPath)
            var isFolder: ObjCBool = false
            guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isFolder) else {
                throw SafariBrowser.Failure.failed("There's no file at \(p).")
            }
            if isFolder.boolValue { throw SafariBrowser.Failure.failed("\(p) is a folder; attach the files in it.") }
            let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? 0
            total += size
            guard total <= limit else {
                throw SafariBrowser.Failure.failed(
                    "The files are more than \(limit / 1_000_000) MB together, the most Latchkey attaches at once.")
            }
            let data: Data
            do { data = try Data(contentsOf: url) } catch {
                throw SafariBrowser.Failure.failed("Latchkey can't read \(p): \(error.localizedDescription)")
            }
            let type = UTType(filenameExtension: url.pathExtension)?.preferredMIMEType ?? "application/octet-stream"
            out.append(PageScripts.Attachment(name: url.lastPathComponent, type: type, data: data))
        }
        return out
    }

    /// Bytes as Claude reads them: "12 KB".
    static func size(_ n: Int) -> String { ByteCountFormatter.string(fromByteCount: Int64(n), countStyle: .file) }
}
