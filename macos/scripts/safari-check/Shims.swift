// Stand-ins for the app's own types that the Safari driver mentions but the check doesn't need
// (the check runs from a terminal that may already control Safari).
enum Permissions {
    enum Automation: Equatable { case notAsked }
    static let safariApp = "com.apple.Safari"
    static func automationOpening(_ bundleID: String) async -> Automation? { nil }
}

/// Latchkey's own browser isn't part of the check; the download code needs only its agent name.
enum LockedBrowser {
    static let safariUserAgent =
        "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Safari/605.1.15"
}
