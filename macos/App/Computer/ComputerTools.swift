import Foundation

/// The Computer control tools Claude sees: look and act (consolidated 2026-10-23).
extension ComputerCapability {
    static let looks = ["screenshot", "ui", "apps"]

    static func readTools(env: ComputerEnvironment) -> [ToolEntry] {
        let ops = Operations(readOperations(env: env))
        return [
            ToolEntry(
                tool: .make(
                    "computer_look", title: "Look at the Screen",
                    description: """
                        Looks at the Mac's screen. show: screenshot (default; coordinates for computer_act are \
                        pixels of this image), ui (the front window's buttons, fields, and text with their \
                        positions: faster and more exact than a screenshot), apps (the running apps). Works only \
                        while the Mac is unlocked with its screen on.
                        """,
                    input: [
                        "show": .enumParam(looks, "What to look at (default screenshot)"),
                        "display": .integerParam("Which display, from 1 (the main one)"),
                    ], readOnly: true, deadlineMS: 20_000),
                handler: { args in
                    let show = args["show"]?.stringValue ?? "screenshot"
                    switch show {
                    case "screenshot": return await ops.call("computer_screenshot", args)
                    case "ui": return await ops.call("computer_ui", args)
                    case "apps": return await ops.call("computer_apps", args)
                    default: return .unknown("show", show, allowed: looks)
                    }
                })
        ]
    }

    static let actions = ["click", "move", "drag", "scroll", "type", "key", "open_app"]

    static func writeTools(env: ComputerEnvironment) -> [ToolEntry] {
        let ops = Operations(writeOperations(env: env))
        return [
            ToolEntry(
                tool: .make(
                    "computer_act", title: "Use the Mouse and Keyboard",
                    description: """
                        Uses the Mac's mouse and keyboard, then answers with a new screenshot. Points are pixels \
                        of the screenshot from computer_look. action: click (x, y; button right, count 2 for a \
                        double click), move (x, y), drag (x, y to to_x, to_y), scroll (x, y, direction, amount in \
                        lines), type (text, where the keyboard focus is), key (keys like return, escape, cmd+c, \
                        cmd+shift+4), open_app (name).
                        """,
                    input: [
                        "action": .enumParam(actions, "What to do"),
                        "x": .integerParam("Horizontal pixel"), "y": .integerParam("Vertical pixel"),
                        "to_x": .integerParam("For drag: end, horizontal pixel"),
                        "to_y": .integerParam("For drag: end, vertical pixel"),
                        "button": .enumParam(["left", "right"], "For click (default left)"),
                        "count": .integerParam("For click: 1, 2, or 3 clicks"),
                        "direction": .enumParam(["up", "down", "left", "right"], "For scroll"),
                        "amount": .integerParam("For scroll: lines (default 5)"),
                        "text": .stringParam("For type: the text"),
                        "keys": .stringParam("For key: the key, with modifiers joined by +"),
                        "name": .stringParam("For open_app: the app's name"),
                        "display": .integerParam("Which display, from 1 (default 1)"),
                    ], required: ["action"], readOnly: false, destructive: true, deadlineMS: 20_000),
                handler: { args in
                    let action = args["action"]?.stringValue
                    switch action {
                    case "click": return await ops.call("computer_click", args)
                    case "move": return await ops.call("computer_move", args)
                    case "drag":
                        return await ops.call(
                            "computer_drag", args.with(["from_x": args["x"], "from_y": args["y"]]))
                    case "scroll": return await ops.call("computer_scroll", args)
                    case "type": return await ops.call("computer_type", args)
                    case "key": return await ops.call("computer_key", args)
                    case "open_app": return await ops.call("computer_open_app", args)
                    default: return .unknown("action", action, allowed: actions)
                    }
                })
        ]
    }
}
