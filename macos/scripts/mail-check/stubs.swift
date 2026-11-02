// The three helpers the compose files use from the rest of the app, copied so the harness
// compiles without the whole Mail capability (MailWrite.bare, MailStore.bareSubject,
// MailCapability.mailApp; keep them the same as there).
import Foundation

enum MailWrite {
    static func bare(_ a: String) -> String {
        guard let open = a.lastIndex(of: "<"), let close = a.lastIndex(of: ">"), open < close else {
            return a.trimmingCharacters(in: .whitespaces)
        }
        return String(a[a.index(after: open)..<close])
    }
}

enum MailStore {
    static func bareSubject(_ s: String) -> String {
        var t = s.trimmingCharacters(in: .whitespaces)
        while let r = t.range(of: #"^(re|fwd?|aw|sv|vs)\s*:\s*"#, options: [.regularExpression, .caseInsensitive]) {
            t.removeSubrange(r)
        }
        return t.lowercased()
    }
}

enum MailCapability {
    static let mailApp = "com.apple.mail"
}
