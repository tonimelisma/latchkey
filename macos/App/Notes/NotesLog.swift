import Foundation

/// What Notes' window steps did, in Latchkey's own log (latchkey_log), so a failure can be traced
/// without guessing (2026-11-06: a tick failed and the front wasn't given back, with nothing
/// logged). Steps only: never a note's title or text.
enum NotesLog {
    static func record(_ text: String, error: Bool = false) {
        EventLog.shared.record(.app, "Notes: \(text)", error: error)
    }
}
