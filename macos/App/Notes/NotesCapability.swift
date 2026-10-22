import Foundation

/// Apple Notes (spec 002 US1). Tools arrive in increments 2 and 3.
enum NotesCapability {
    static func make() -> Capability {
        Capability(
            id: CapabilityRegistry.notes, title: "Notes", summary: "Read, search, create, edit, and delete notes",
            readTools: [], writeTools: [])
    }
}
