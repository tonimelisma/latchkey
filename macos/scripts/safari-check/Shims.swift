// Stand-ins for the app's own types that the Safari driver mentions but the check doesn't need
// (the check runs from a terminal that may already control Safari).
enum Permissions {
    enum Automation: Equatable { case notAsked }
    static let safariApp = "com.apple.Safari"
    static func automationOpening(_ bundleID: String) async -> Automation? { nil }
}
