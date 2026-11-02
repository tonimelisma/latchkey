import AppKit

/// Add Latchkey to Claude, setup's last step (spec 001 FR-627, FR-628, plan D25): claude.ai's
/// documented link that opens its Add custom connector dialog with Latchkey's name and this
/// relay's address filled in. The Owner still clicks Add, signs in, and clicks Allow.
enum AddToClaude {
    /// The address Claude connects to: the relay's own address followed by /mcp.
    static func connector(relay: URL) -> String {
        var base = relay.absoluteString
        while base.hasSuffix("/") { base.removeLast() }
        return base + "/mcp"
    }

    private static let page = "https://claude.ai/customize/connectors"
    // Everything but letters, digits, and -._~ is encoded, as the link's documentation asks.
    private static let unreserved = CharacterSet(
        charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-._~")

    static func link(relay: URL) -> URL {
        let address = connector(relay: relay).addingPercentEncoding(withAllowedCharacters: unreserved) ?? ""
        let text = "\(page)?modal=add-custom-connector&connectorName=Latchkey&connectorUrl=\(address)"
        // Fixed parts and an encoded address always parse; the page itself is the fallback.
        return URL(string: text) ?? URL(fileURLWithPath: "/")
    }

    /// Done while Claude on the web, desktop, and phone has access; a program on a computer, such
    /// as Claude Code, doesn't count. Not known until the relay has sent the list.
    static func step(entries: [ClientEntry]?) -> SetupStep {
        guard let entries else { return .unknown }
        return entries.contains(where: \.coversHostedApps) ? .done : .missing
    }

    static func open(relay: URL) { NSWorkspace.shared.open(link(relay: relay)) }

    static func copy(relay: URL, to board: NSPasteboard = .general) {
        board.clearContents()
        board.setString(connector(relay: relay), forType: .string)
    }
}
