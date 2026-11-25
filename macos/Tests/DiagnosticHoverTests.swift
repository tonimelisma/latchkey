import Foundation
import Testing

@testable import Latchkey

/// Temporary (2026-11-25): what each way of moving Latchkey's pointer reaches on GitHub's macOS
/// 26 runner, where hover does nothing. Recorded as an issue so it shows in the run; removed
/// once understood.
@MainActor @Suite struct DiagnosticHoverTests {
    @Test func whatAPointerMoveReaches() async throws {
        let b = LockedBrowser(cookies: { [] })
        defer { b.discard() }
        let page = """
            <style>#d:hover { outline: 2px solid red; }</style>
            <div id="d" data-latchkey="e1" style="width:200px;height:80px;background:#eee">Account</div>
            <script>
            window.log = [];
            ['pointerover', 'pointerenter', 'mouseover', 'mouseenter', 'pointermove', 'mousemove'].forEach(function (k) {
              document.getElementById('d').addEventListener(k, function (ev) { log.push(k + ':' + ev.isTrusted); });
            });
            </script>
            """
        _ = try await b.open(html: page, base: URL(string: "https://a.test/")!)
        let log =
            "(function () { var d = document.getElementById('d'); var r = JSON.stringify({ hover: d.matches(':hover'), log: log.slice(-6) }); log = []; return r; })()"
        let said = try await b.hoverDiagnostics("e1", log: log)
        Issue.record("DIAG hover: \(said)")
    }
}
