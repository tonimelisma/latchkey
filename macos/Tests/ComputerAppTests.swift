import CoreGraphics
import Foundation
import Testing

@testable import Latchkey

/// Spec 006 FR-510 (Toni, 2026-11-02, "Background first"): one named app is looked at and acted
/// on without the pointer or the front.
@Suite struct ComputerAppTests {
    final class Pressed: @unchecked Sendable {
        private let lock = NSLock()
        private(set) var refs: [String] = []
        func add(_ r: String) { lock.withLock { refs.append(r) } }
    }

    func setup() -> (ComputerEnvironment, pointer: FakePoster, app: FakePoster, Pressed) {
        let pointer = FakePoster()
        let appKeys = FakePoster()
        let pressed = Pressed()
        var e = ComputerToolTests().env(FakeScreen(), pointer)
        e.appControl = AppControl(
            find: { $0.lowercased() == "calculator" ? AppTarget(name: "Calculator", pid: 42) : nil },
            elements: { _ in
                [
                    AppElement(ref: "e1", role: "AXButton", label: "7", value: nil, element: nil),
                    AppElement(ref: "e2", role: "AXTextField", label: "Name", value: "", element: nil),
                ]
            },
            press: { e in
                pressed.add(e.ref)
                return true
            },
            focus: { _ in true }, poster: { _ in appKeys },
            picture: { _ in PreparedImage(data: NotesFixture.pngPixel, mimeType: "image/png") })
        return (e, pointer, appKeys, pressed)
    }

    func tool(_ e: ComputerEnvironment, _ name: String) -> ToolEntry {
        (ComputerCapability.readTools(env: e) + ComputerCapability.writeTools(env: e)).first { $0.tool.name == name }!
    }

    @Test func looksPressesAndTypesInOneAppOnly() async throws {
        let (e, pointer, appKeys, pressed) = setup()
        let ui = await tool(e, "computer_look").handler(.object(["show": .string("ui"), "app": .string("Calculator")]))
        #expect(ui.plainText.contains("[e1] AXButton \"7\""), "\(ui.plainText)")
        let press = await tool(e, "computer_act").handler(
            .object(["action": .string("press"), "app": .string("Calculator"), "ref": .string("e1")]))
        #expect(!press.isError, "\(press.plainText)")
        #expect(pressed.refs == ["e1"])
        _ = await tool(e, "computer_act").handler(
            .object([
                "action": .string("type"), "app": .string("Calculator"), "ref": .string("e2"), "text": .string("Hi"),
            ]))
        _ = await tool(e, "computer_act").handler(
            .object(["action": .string("key"), "app": .string("calculator"), "keys": .string("return")]))
        #expect(appKeys.events.contains(.text("Hi")))
        #expect(appKeys.events.contains { if case .key = $0 { true } else { false } })
        #expect(pointer.events.isEmpty, "nothing went to the real pointer or keyboard")
    }

    @Test func pointerActionsWithAnAppAreRefused() async {
        let (e, pointer, _, _) = setup()
        let r = await tool(e, "computer_act").handler(
            .object(["action": .string("click"), "app": .string("Calculator"), "x": .number(1), "y": .number(1)]))
        #expect(r.isError && r.plainText.contains("leave app out"))
        let unknown = await tool(e, "computer_act").handler(
            .object(["action": .string("press"), "app": .string("Nope"), "ref": .string("e1")]))
        #expect(unknown.isError && unknown.plainText.contains("No app called Nope"))
        let stale = await tool(e, "computer_act").handler(
            .object(["action": .string("press"), "app": .string("Calculator"), "ref": .string("e99")]))
        #expect(stale.isError && stale.plainText.contains("look again"))
        #expect(pointer.events.isEmpty)
    }
}
