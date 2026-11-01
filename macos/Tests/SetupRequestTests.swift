import AppKit
import Testing

@testable import Latchkey

/// "Don't have a relay?" in setup: the request the Owner copies into Claude Code (spec 009
/// FR-903, plan D9), at the guide in the plugin (spec 011 FR-1113).
struct SetupRequestTests {
    @Test func pointsClaudeCodeAtTheGuide() {
        #expect(
            SetupRequest.text.contains(
                "https://raw.githubusercontent.com/tonimelisma/latchkey/main/plugin/skills/set-up-latchkey/own-relay.md"
            ))
        #expect(SetupRequest.text.hasPrefix("Set up a Latchkey relay for me"))
    }

    @Test func copiesToThePasteboard() {
        let board = NSPasteboard.withUniqueName()  // never the Owner's own clipboard
        defer { board.releaseGlobally() }
        SetupRequest.copy(to: board)
        #expect(board.string(forType: .string) == SetupRequest.text)
    }
}
