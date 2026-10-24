// Tests for latchkey.yml (`semgrep --test`): each `ruleid:` line must be reported, each `ok:` line
// must not.

enum Script {
    // ok: latchkey-applescript-constant
    static let fixed = "on run argv\nreturn item 1 of argv\nend run"
    static func send(_ text: String) -> String {
        // ruleid: latchkey-applescript-constant
        "tell application \"Messages\" to send \"\(text)\""
    }
}

enum Store {
    static func search(db: OpaquePointer, term: String) throws {
        // ok: latchkey-sql-bound
        _ = try SQLite.rows(db, "SELECT text FROM message WHERE text LIKE ?", bind: [.text(term)])
        let sql = "SELECT text FROM message WHERE text LIKE '%\(term)%'"
        // ruleid: latchkey-sql-bound
        _ = try SQLite.rows(db, sql)
    }
}


enum PageScripts {
    static func literal(_ s: String) -> String { s }

    static func fill(_ text: String) -> String {
        // ok: latchkey-page-script-literal
        "(function (t) { return t; })(\(literal(text)))"
    }

    static func unsafe(_ text: String) -> String {
        // ruleid: latchkey-page-script-literal
        "(function () { return '\(text)'; })()"
    }
}
