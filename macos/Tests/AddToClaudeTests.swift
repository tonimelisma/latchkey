import AppKit
import Foundation
import Testing

@testable import Latchkey

/// Add Latchkey to Claude, setup's last step (spec 001 FR-627, FR-628, plan D25).
struct AddToClaudeTests {
    private func entry(_ host: String, _ redirect: String) -> ClientEntry {
        ClientEntry(id: UUID().uuidString, name: "Claude", host: host, redirect: redirect, approvedAt: Date())
    }

    @Test func linkOpensClaudesDialogFilledIn() throws {
        let relay = try #require(URL(string: "https://relay.example.com"))
        #expect(
            AddToClaude.link(relay: relay).absoluteString
                == "https://claude.ai/customize/connectors?modal=add-custom-connector&connectorName=Latchkey&connectorUrl=https%3A%2F%2Frelay.example.com%2Fmcp"
        )
        #expect(AddToClaude.connector(relay: relay) == "https://relay.example.com/mcp")
    }

    @Test func aTrailingSlashDoesNotDoubleUp() throws {
        let relay = try #require(URL(string: "https://relay.example.com/"))
        #expect(AddToClaude.connector(relay: relay) == "https://relay.example.com/mcp")
    }

    @Test func notKnownUntilTheListArrives() {
        #expect(AddToClaude.step(entries: nil) == .unknown)
    }

    @Test func missingWithNoApprovalOrOnlyClaudeCode() {
        #expect(AddToClaude.step(entries: []) == .missing)
        #expect(AddToClaude.step(entries: [entry("claude.ai", ClientEntry.thisComputer)]) == .missing)
        #expect(AddToClaude.step(entries: [entry("example.com", "example.com")]) == .missing)
    }

    @Test func doneOnceClaudeOnTheWebHasAccess() {
        #expect(AddToClaude.step(entries: [entry("claude.ai", "claude.ai")]) == .done)
        #expect(AddToClaude.step(entries: [entry("claude.com", "claude.com")]) == .done)
    }

    @Test func copiesTheAddress() throws {
        let relay = try #require(URL(string: "https://relay.example.com"))
        let board = NSPasteboard.withUniqueName()  // never the Owner's own clipboard
        defer { board.releaseGlobally() }
        AddToClaude.copy(relay: relay, to: board)
        #expect(board.string(forType: .string) == "https://relay.example.com/mcp")
    }
}
