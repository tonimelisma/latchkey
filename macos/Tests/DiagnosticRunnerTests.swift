import Foundation
import Testing

@testable import Latchkey

/// Temporary (2026-11-25): why the browser and sign-in tests fail on GitHub's macOS 26 runner
/// since real input (#51), also when run on their own. Measures how long a page takes to answer
/// a script before and after real clicks and keys, and the order of every event while typing
/// "Café". Records the numbers as issues so they show in the run; removed once understood.
@MainActor @Suite(.serialized) struct DiagnosticRunnerTests {
    static let base = URL(string: "https://a.test/login")!
    static let page = """
        <input data-latchkey="e1" placeholder="Name">
        <button data-latchkey="e2" onclick="window.clicks = (window.clicks || 0) + 1">Go</button>
        <script>
        window.log = [];
        var t0 = performance.now();
        var f = document.querySelector('[data-latchkey=e1]');
        ['keydown', 'keypress', 'beforeinput', 'input', 'keyup'].forEach(function (k) {
          f.addEventListener(k, function (ev) {
            log.push(Math.round(performance.now() - t0) + ' ' + k + ':' + (ev.key || ev.data || '') + '=' + f.value);
          });
        });
        </script>
        """

    func time(_ b: LockedBrowser, _ label: String, _ out: inout [String]) async {
        var ms: [Int] = []
        for _ in 0..<3 {
            let start = ContinuousClock.now
            _ = try? await b.run("1")
            let d = ContinuousClock.now - start
            ms.append(Int(d.components.seconds * 1000 + d.components.attoseconds / 1_000_000_000_000_000))
        }
        out.append("\(label): \(ms)")
    }

    @Test func howLongAPageTakesToAnswer() async throws {
        let b = LockedBrowser(cookies: { [] })
        defer { b.discard() }
        var out: [String] = []
        _ = try await b.open(html: Self.page, base: Self.base)
        await time(b, "fresh", &out)
        let c0 = ContinuousClock.now
        _ = try? await b.click("e2")
        out.append("click took \(ContinuousClock.now - c0)")
        await time(b, "after click", &out)
        try? await Task.sleep(for: .seconds(3))
        await time(b, "3 s after click", &out)
        let t0 = ContinuousClock.now
        _ = try? await b.type("e1", text: "Café", submit: false)
        out.append("type took \(ContinuousClock.now - t0)")
        await time(b, "after type", &out)
        let seen = (try? await b.run("JSON.stringify({ v: f.value, clicks: window.clicks, log: log })")) ?? "nil"
        out.append("seen \(seen)")
        try? await Task.sleep(for: .seconds(3))
        await time(b, "3 s after type", &out)
        Issue.record("DIAG \(out.joined(separator: " || "))")
    }
}
