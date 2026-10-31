import Foundation

/// Notices a permission or setting that was on and is now off, once per loss, for the Owner's
/// notification (FR-626, plan D23). Missing from the start is setup's business (FR-621), and a
/// state macOS hasn't said yet is neither on nor off.
struct PermissionLoss {
    /// Never told: a notice can't arrive without Notifications, and macOS doesn't take back the
    /// screenshot question (only Screen Recording, which is watched).
    static let unwatched: Set<String> = ["notifications", "screenAccess"]
    /// The notification's category, so a click opens setup.
    static let category = "permissionLost"

    private var allowed: Set<String> = []

    /// The approvals that were allowed at the last look and are missing now.
    mutating func update(_ approvals: [Approval]) -> [Approval] {
        var lost: [Approval] = []
        for approval in approvals where !Self.unwatched.contains(approval.id) {
            switch approval.state {
            case .allowed: allowed.insert(approval.id)
            case .missing: if allowed.remove(approval.id) != nil { lost.append(approval) }
            case .checking: break
            }
        }
        return lost
    }

    /// What the notification says; nil when nothing was lost.
    static func notice(_ lost: [Approval]) -> (title: String, body: String)? {
        guard let first = lost.first else { return nil }
        if lost.count == 1 {
            return ("\(first.title) is off", "Latchkey needs it \(need(first)) Click to turn it on again.")
        }
        return (
            "\(lost.count) Latchkey permissions are off",
            "\(joined(lost.map(\.title))). Claude can’t use what they allow until they’re on again. Click to turn them on."
        )
    }

    /// The approval's purpose, to follow "Latchkey needs it".
    private static func need(_ approval: Approval) -> String {
        if approval.id == "safariJS" { return "to read and use web pages in Safari." }  // its purpose says how
        return approval.purpose.prefix(1).lowercased() + approval.purpose.dropFirst()
    }

    /// "A and B", "A, B, and C".
    private static func joined(_ names: [String]) -> String {
        guard names.count > 2, let last = names.last else { return names.joined(separator: " and ") }
        return names.dropLast().joined(separator: ", ") + ", and " + last
    }
}
