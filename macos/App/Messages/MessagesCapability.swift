import Foundation

/// Messages: iMessage, SMS, RCS (spec 002 US2). Tools arrive in increments 4 and 5.
enum MessagesCapability {
    static func make() -> Capability {
        Capability(
            id: CapabilityRegistry.messages, title: "Messages", summary: "Read, search, and send messages",
            readTools: [], writeTools: [])
    }
}
