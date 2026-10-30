import Foundation

/// The most text one answer carries: about 10,000 tokens, well inside Claude Code's 25,000-token
/// cap on a tool result (docs/best-practices.md). Longer content comes in pages.
enum ResultLimit {
    static let characters = 40_000

    /// The page of `text` starting at `offset`, and where the next page starts (nil at the end).
    static func page(_ text: String, offset: Int) -> (String, next: Int?) {
        let start = text.index(text.startIndex, offsetBy: min(max(offset, 0), text.count))
        let end = text.index(start, offsetBy: characters, limitedBy: text.endIndex) ?? text.endIndex
        return (String(text[start..<end]), end < text.endIndex ? text.distance(from: text.startIndex, to: end) : nil)
    }
}
