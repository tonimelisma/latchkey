import Foundation

/// The Messages tools Claude sees: find, read, send (consolidated 2026-10-23).
extension MessagesCapability {
    static func readTools(store: @escaping StoreSource) -> [ToolEntry] {
        let ops = Operations(readOperations(store: store))
        return [
            ToolEntry(
                tool: .make(
                    "messages_find", title: "Find Messages",
                    description:
                        "Searches Messages (iMessage, SMS, RCS). With text or dates: finds messages across all history, newest first, optionally only with a person. With neither: lists recent conversations, optionally only those with a person or group name, each with its id for messages_read.",
                    input: [
                        "text": .stringParam("Words in the messages"),
                        "person": .stringParam("A name from Contacts, a number, an email address, or a group's name"),
                        "since": .stringParam("Only messages from this time on (ISO 8601)"),
                        "until": .stringParam("Only messages before this time (ISO 8601)"),
                        "limit": .integerParam("At most this many (default 20 conversations or 50 messages)"),
                    ], readOnly: true, deadlineMS: 30_000),
                handler: { args in
                    if args.hasAny("text", "since", "until") { return await ops.call("messages_search", args) }
                    return await ops.call(
                        "messages_conversations",
                        .object(["query": args["person"] ?? .null, "limit": args["limit"] ?? .null]))
                }),
            ToolEntry(
                tool: .make(
                    "messages_read", title: "Read a Conversation",
                    description:
                        "Reads a conversation, oldest first, ending with the latest message (or the last before the time given in before). Images appear as [image <id>] with their message's id; pass both as message and image to see the picture.",
                    input: [
                        "conversation": .stringParam("The conversation's id, from messages_find"),
                        "before": .stringParam("Only messages before this time (ISO 8601), to read further back"),
                        "limit": .integerParam("At most this many messages (default 50, up to 200)"),
                        "message": .stringParam("To see an image: the message's id"),
                        "image": .stringParam("To see an image: the image's id"),
                    ], readOnly: true),
                handler: { args in
                    if let image = args["image"]?.stringValue, !image.isEmpty {
                        return await ops.call(
                            "messages_image",
                            .object(["message": args["message"] ?? .null, "attachment": .string(image)]))
                    }
                    return await ops.call("messages_read", args)
                }),
        ]
    }

    /// `messages_send` (a person, a conversation, a new group, or an inline reply) and
    /// `messages_change` (tapbacks, edits, unsending, deleting; spec 002 FR-172 to FR-178).
    static func writeTools(
        store: @escaping StoreSource, contacts: any ContactsLookup, scripts: any ScriptRunner, staging: URL,
        ui: any MessagesUI, confirmWait: Duration = .seconds(5), windowActions: Bool = false
    ) -> [ToolEntry] {
        writeOperations(
            store: store, contacts: contacts, scripts: scripts, staging: staging, ui: ui, confirmWait: confirmWait,
            windowActions: windowActions)
    }
}
