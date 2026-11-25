import Foundation
import Testing

@testable import Latchkey

/// Temporary (2026-11-25): what a page hears from Latchkey's real keys and pointer on GitHub's
/// macOS 26 runner, where code typing and hover behave differently than on macOS 27. Records
/// the events as issues so they show in the run; removed once understood.
@MainActor @Suite struct DiagnosticRealInputTests {
    static let base = URL(string: "https://a.test/login")!
    static let page = """
        <input data-latchkey="e1" autocomplete="one-time-code" placeholder="Code">
        <div data-latchkey="e2" style="width:200px;height:60px;background:#eee">Account</div>
        <script>
        window.log = [];
        var f = document.querySelector('[data-latchkey=e1]');
        ['focus', 'keydown', 'keypress', 'beforeinput', 'input', 'keyup', 'blur'].forEach(function (k) {
          f.addEventListener(k, function (ev) { log.push(k + ':' + ev.isTrusted + ':' + (ev.key || ev.data || '') + ':' + f.value); });
        });
        var d = document.querySelector('[data-latchkey=e2]');
        ['pointerover', 'pointerenter', 'mouseover', 'mouseenter', 'pointermove', 'mousemove'].forEach(function (k) {
          d.addEventListener(k, function (ev) { log.push(k + ':' + ev.isTrusted + ':' + Math.round(ev.clientX) + ',' + Math.round(ev.clientY)); });
        });
        </script>
        """

    @Test func whatThePageHears() async throws {
        let b = LockedBrowser(cookies: { [] })
        defer { b.discard() }
        _ = try await b.open(html: Self.page, base: Self.base)
        _ = try await b.type("e1", text: "3205", submit: false)
        let typed = try await b.run("JSON.stringify({ value: f.value, log: log })")
        _ = try await b.run("log = []; f.value = ''; 1")
        let fill = try await b.fillReal(ref: "e1", kind: "code", value: "3205", host: "a.test")
        let filled = try await b.run(
            "JSON.stringify({ value: f.value, log: log, active: document.activeElement.outerHTML.slice(0, 80) })")
        _ = try await b.run("log = []; 1")
        _ = try await b.hover("e2")
        let hovered = try await b.run(
            "JSON.stringify({ log: log, hover: document.querySelector('[data-latchkey=e2]').matches(':hover') })")
        Issue.record("DIAG fill: \(fill) \(filled) || hover: \(hovered) || type: \(typed.prefix(60))")
    }
}
