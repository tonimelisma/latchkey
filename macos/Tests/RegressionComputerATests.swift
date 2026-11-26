import AppKit
import Foundation
import Testing

@testable import Latchkey

/// Computer control regression cases (docs/regression-coverage.md,
/// "regressions-computer"), on a stand-in app.
@Suite struct RegressionComputerATests {
    /// What the stand-in app was asked to do.
    final class Touched: @unchecked Sendable {
        private let lock = NSLock()
        private var list: [String] = []
        var calls: [String] { lock.withLock { list } }
        func add(_ s: String) { lock.withLock { list.append(s) } }
    }

    /// An app control that would find any app by the name given, Latchkey included, so only the
    /// tools' own refusal keeps Latchkey out.
    func env(_ touched: Touched) -> ComputerEnvironment {
        var e = ComputerToolTests().env(FakeScreen(), FakePoster())
        e.settle = .milliseconds(1)
        e.appControl = AppControl(
            find: { AppTarget(name: $0, pid: 7341) },
            elements: { _ in
                touched.add("elements")
                return AppListing(items: [
                    AppElement(ref: "e1", role: "AXButton", label: "Pause", value: nil, element: nil)
                ])
            },
            press: { _ in
                touched.add("press")
                return true
            },
            focus: { _ in
                touched.add("focus")
                return true
            },
            poster: { _ in
                touched.add("poster")
                return FakePoster()
            },
            picture: { _ in
                touched.add("picture")
                return PreparedImage(data: NotesFixture.pngPixel, mimeType: "image/png")
            })
        return e
    }

    /// regressions.computer_never_targets_latchkey (security review 2026-11-02): background
    /// computer control could target Latchkey itself, whose windows set what Claude may do. Every
    /// look and action naming Latchkey is refused before the app is read or touched.
    @Test func latchkeyIsRefusedForEveryLookAndAction() async throws {
        let touched = Touched()
        let e = env(touched)
        let look = try #require(ComputerCapability.readTools(env: e).first { $0.tool.name == "computer_look" })
        let act = try #require(ComputerCapability.writeTools(env: e).first { $0.tool.name == "computer_act" })
        for name in ["Latchkey", "Latchkey Dev", "latchkey"] {
            for show in ["ui", "screenshot"] {
                let r = await look.handler(.object(["app": .string(name), "show": .string(show)]))
                #expect(r.isError, "\(name) \(show): \(r.plainText)")
                #expect(r.plainText.contains("never acts on Latchkey"), "\(name) \(show): \(r.plainText)")
            }
            let press = await act.handler(
                .object(["app": .string(name), "action": .string("press"), "ref": .string("e1")]))
            #expect(press.isError && press.plainText.contains("never acts on Latchkey"), "\(press.plainText)")
            let typed = await act.handler(
                .object(["app": .string(name), "action": .string("type"), "text": .string("x")]))
            #expect(typed.isError && typed.plainText.contains("never acts on Latchkey"), "\(typed.plainText)")
        }
        #expect(touched.calls.isEmpty, "Latchkey's window was read or acted on: \(touched.calls)")
    }

    /// The running apps computer control reaches leave out every copy of Latchkey, this test
    /// build included (0.8.94, 0.8.95).
    @Test func theRunningLatchkeyIsNeverFound() {
        let me = NSRunningApplication.current
        #expect(AppControl.isLatchkey(me), "\(me.bundleIdentifier ?? "no bundle ID")")
        if let name = me.localizedName, !name.isEmpty {
            #expect(AppControl.live.find(name) == nil, "\(name) was found")
        }
    }
}
