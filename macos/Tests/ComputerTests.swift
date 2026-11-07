import CoreGraphics
import Foundation
import Testing

@testable import Latchkey

/// A built-in Retina display (1512×982 points, 3024×1964 pixels) and a second display to its right.
enum Displays {
    static let main = DisplayInfo(
        id: 1, bounds: CGRect(x: 0, y: 0, width: 1512, height: 982), pixelWidth: 3024, pixelHeight: 1964)
    static let side = DisplayInfo(
        id: 2, bounds: CGRect(x: 1512, y: -200, width: 1920, height: 1080), pixelWidth: 1920, pixelHeight: 1080)
}

final class FakeScreen: ScreenStateSource, @unchecked Sendable {
    var list = [Displays.main, Displays.side]
    var locked = false
    var asleep = false
    /// Connected displays, asleep ones included; nil: the same as the active list.
    var connected: Int?

    func displays() -> [DisplayInfo] { list }
    func connectedCount() -> Int { connected ?? list.count }
    func isLocked() -> Bool { locked }
    func isAsleep(_ id: CGDirectDisplayID) -> Bool { asleep }
}

final class FakePoster: InputPoster, @unchecked Sendable {
    private let lock = NSLock()
    private(set) var events: [InputEvent] = []
    func post(_ e: InputEvent) { lock.withLock { events.append(e) } }
}

@Suite struct ScreenGeometryTests {
    @Test func scalesToClaudesSize() {
        let (w, h) = ScreenGeometry.imageSize(Displays.main)
        #expect(w == 1568)
        #expect(h == 1018)
        let (sw, sh) = ScreenGeometry.imageSize(Displays.side)
        #expect(sw == 1568 && sh == 882)
        let small = DisplayInfo(
            id: 3, bounds: CGRect(x: 0, y: 0, width: 800, height: 600), pixelWidth: 800, pixelHeight: 600)
        #expect(ScreenGeometry.imageSize(small) == (800, 600), "never enlarged")
    }

    @Test func mapsImagePixelsToScreenPoints() throws {
        let p = ScreenGeometry.point(x: 784, y: 509, on: Displays.main)
        #expect(abs(p.x - 756) < 1 && abs(p.y - 491) < 1)
        let q = ScreenGeometry.point(x: 0, y: 0, on: Displays.side)
        #expect(q == CGPoint(x: 1512, y: -200), "a second display keeps its place")
        let (x, y) = try #require(ScreenGeometry.pixel(of: CGPoint(x: 756, y: 491), on: Displays.main))
        #expect(abs(x - 784) <= 1 && abs(y - 509) <= 1)
    }
}

@Suite struct KeyNameTests {
    @Test func parsesCombinations() throws {
        let k = try KeyNames.parse("cmd+shift+4")
        #expect(k.code == 0x15)
        #expect(k.flags.contains(.maskCommand) && k.flags.contains(.maskShift))
        #expect(try KeyNames.parse("Return").code == 0x24)
        #expect(try KeyNames.parse("ctrl+alt+delete").flags.contains(.maskAlternate))
        #expect(try KeyNames.parse("f5").code == 0x60)
        #expect(try KeyNames.parse("space").code == 0x31)
        #expect(throws: KeyNames.Unknown.self) { try KeyNames.parse("cmd+banana") }
    }
}

@Suite struct ScreenCheckTests {
    @Test func explainsEachReason() async {
        let s = FakeScreen()
        #expect(await ScreenCheck.problem(s) == nil)
        s.locked = true
        #expect(await ScreenCheck.problem(s)?.contains("locked") == true)
        s.locked = false
        s.list = []
        let none = await ScreenCheck.problem(s)
        #expect(none?.contains("no screen") == true)
        #expect(none?.contains("shell") == true, "says what still works")
    }

    /// Toni, 2026-11-02: a sleeping display isn't woken, so the Mac's idle lock comes as usual.
    @Test func aSleepingDisplayIsLeftAsleep() async {
        let s = FakeScreen()
        s.asleep = true
        let problem = await ScreenCheck.problem(s)
        #expect(problem?.contains("asleep") == true)
        #expect(problem?.contains("locks itself as usual") == true)
        #expect(problem?.contains("shell") == true, "says what still works")
    }

    /// A sleeping display isn't in the active list but is still connected: that is "asleep", not
    /// "the lid is closed" (live check 2026-11-07, lid open, Mac locked).
    @Test func aSleepingDisplayOutOfTheActiveListIsAsleepNotLidClosed() async {
        let s = FakeScreen()
        s.list = []
        s.connected = 1
        let problem = await ScreenCheck.problem(s)
        #expect(problem?.contains("asleep") == true, "\(problem ?? "")")
        #expect(problem?.contains("lid is closed") == false)
    }
}

@Suite struct ComputerActionTests {
    func actions(_ poster: FakePoster) -> ComputerActions {
        ComputerActions(poster: poster, displays: [Displays.main, Displays.side])
    }

    @Test func doubleClicksWhereClaudeLooked() throws {
        let poster = FakePoster()
        try actions(poster).click(x: 784, y: 509, button: .left, count: 2, display: 1)
        let p = ScreenGeometry.point(x: 784, y: 509, on: Displays.main)
        #expect(
            poster.events == [
                .move(p), .down(.left, p, 1), .up(.left, p, 1), .down(.left, p, 2), .up(.left, p, 2),
            ])
    }

    @Test func rightClicksOnTheSecondDisplay() throws {
        let poster = FakePoster()
        try actions(poster).click(x: 0, y: 0, button: .right, count: 1, display: 2)
        #expect(poster.events.contains(.down(.right, CGPoint(x: 1512, y: -200), 1)))
    }

    @Test func dragsInSteps() throws {
        let poster = FakePoster()
        try actions(poster).drag(from: (100, 100), to: (200, 300), display: 1)
        #expect(poster.events.first == .move(ScreenGeometry.point(x: 100, y: 100, on: Displays.main)))
        #expect(poster.events.filter { if case .dragTo = $0 { true } else { false } }.count == 10)
        #expect(poster.events.last == .up(.left, ScreenGeometry.point(x: 200, y: 300, on: Displays.main), 1))
    }

    @Test func scrollsAndTypes() throws {
        let poster = FakePoster()
        let a = actions(poster)
        try a.scroll(x: 10, y: 10, direction: "down", amount: 3, display: 1)
        #expect(poster.events.last == .scroll(dx: 0, dy: -3))
        a.type("Hei 👋")
        #expect(poster.events.last == .text("Hei 👋"))
        try a.key("cmd+c")
        let k = try KeyNames.parse("cmd+c")
        #expect(poster.events.suffix(2) == [.key(k.code, down: true, k.flags), .key(k.code, down: false, k.flags)])
    }

    @Test func unknownDisplayIsAnError() {
        #expect(throws: ComputerActions.Failure.self) {
            try actions(FakePoster()).click(x: 1, y: 1, button: .left, count: 1, display: 9)
        }
    }
}

@Suite struct ComputerToolTests {
    func env(_ screen: FakeScreen, _ poster: FakePoster) -> ComputerEnvironment {
        ComputerEnvironment(
            screen: screen, poster: poster,
            capture: { _ in PreparedImage(data: NotesFixture.pngPixel, mimeType: "image/png") },
            ui: {
                [
                    UIElementInfo(
                        role: "AXButton", label: "OK", value: nil, frame: CGRect(x: 10, y: 10, width: 50, height: 20))
                ]
            },
            apps: { [("Notes", true), ("Safari", false)] },
            permissions: { (true, true) }, notify: { _ in }, openApp: { _ in }, settle: .zero)
    }

    func tools(_ e: ComputerEnvironment) -> [String: ToolEntry] {
        Dictionary(
            uniqueKeysWithValues: (ComputerCapability.readOperations(env: e)
                + ComputerCapability.writeOperations(env: e)).map {
                    ($0.tool.name, $0)
                })
    }

    @Test func toolsAndHints() {
        let t = tools(env(FakeScreen(), FakePoster()))
        let read = ["computer_screenshot", "computer_ui", "computer_apps"]
        let write = [
            "computer_click", "computer_move", "computer_drag", "computer_scroll", "computer_type", "computer_key",
            "computer_open_app",
        ]
        #expect(Set(t.keys) == Set(read + write))
        for n in read { #expect(t[n]?.tool.annotations?.readOnlyHint == true) }
        for n in write { #expect(t[n]?.tool.annotations?.readOnlyHint == false) }
        #expect(t["computer_click"]?.tool.annotations?.destructiveHint == true)
    }

    @Test func screenshotSaysItsSize() async {
        let r = await tools(env(FakeScreen(), FakePoster()))["computer_screenshot"]!.handler(.object([:]))
        #expect(!r.isError)
        #expect(r.content.jsonText.contains("1568×1018"))
        #expect(r.content.jsonText.contains("image"))
    }

    @Test func actionsAnswerWithAFreshLook() async {
        let poster = FakePoster()
        let r = await tools(env(FakeScreen(), poster))["computer_click"]!.handler(
            .object(["x": .number(5), "y": .number(5)]))
        #expect(!r.isError, "\(r.content.jsonText)")
        #expect(!poster.events.isEmpty)
        #expect(r.content.jsonText.contains("\"type\":\"image\""))
        #expect(r.activity?.contains("Clicked") == true)
    }

    @Test func lockedMacIsExplainedAndUntouched() async {
        let screen = FakeScreen()
        screen.locked = true
        let poster = FakePoster()
        let start = Date()
        let r = await tools(env(screen, poster))["computer_click"]!.handler(
            .object(["x": .number(5), "y": .number(5)]))
        #expect(r.isError)
        #expect(r.content.jsonText.contains("locked"))
        #expect(poster.events.isEmpty, "FR-505")
        #expect(Date().timeIntervalSince(start) < 2, "SC-502")
    }

    @Test func missingPermissionIsExplained() async {
        var e = env(FakeScreen(), FakePoster())
        e.permissions = { (false, true) }
        let r = await tools(e)["computer_screenshot"]!.handler(.object([:]))
        #expect(r.isError)
        #expect(r.content.jsonText.contains("Screen & System Audio Recording"))
    }

    @Test func readsTheFrontWindow() async {
        let r = await tools(env(FakeScreen(), FakePoster()))["computer_ui"]!.handler(.object([:]))
        #expect(r.content.jsonText.contains("AXButton") && r.content.jsonText.contains("OK"))
    }

    /// The front app reports its own frames; NaN or huge ones crashed the app (scan 2026-10-24).
    @Test func impossibleFramesFromTheFrontAppAreSkipped() async {
        var e = env(FakeScreen(), FakePoster())
        e.ui = {
            [
                UIElementInfo(
                    role: "AXButton", label: "NaN", value: nil,
                    frame: CGRect(x: CGFloat.nan, y: CGFloat.nan, width: 10, height: 10)),
                UIElementInfo(
                    role: "AXButton", label: "Huge", value: nil, frame: CGRect(x: 1e300, y: 0, width: 10, height: 10)),
                UIElementInfo(
                    role: "AXButton", label: "Infinite", value: nil,
                    frame: CGRect(x: 0, y: -CGFloat.infinity, width: 10, height: 10)),
                UIElementInfo(
                    role: "AXButton", label: "OK", value: nil, frame: CGRect(x: 10, y: 10, width: 50, height: 20)),
            ]
        }
        let r = await tools(e)["computer_ui"]!.handler(.object([:]))
        #expect(!r.isError)
        let text = r.content.jsonText
        #expect(text.contains("\\\"OK\\\" at ("))
        for label in ["NaN", "Huge", "Infinite"] {
            #expect(text.contains("\\\"\(label)\\\" (no position)"), "\(label)")
        }
    }
}
