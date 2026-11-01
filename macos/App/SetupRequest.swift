import AppKit

/// The request an Owner without a relay pastes into Claude Code, which then sets one up by
/// following the guide in the repository's plugin (spec 009 FR-903, plan D9; spec 011 FR-1113).
enum SetupRequest {
    static let guide =
        "https://raw.githubusercontent.com/tonimelisma/latchkey/main/plugin/skills/set-up-latchkey/own-relay.md"
    static let text = "Set up a Latchkey relay for me. Follow the instructions at \(guide)"

    static func copy(to board: NSPasteboard = .general) {
        board.clearContents()
        board.setString(text, forType: .string)
    }
}
