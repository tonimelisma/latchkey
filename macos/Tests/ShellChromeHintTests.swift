import Testing

@testable import Latchkey

/// Problem report 2026-11-24: headless Chrome's print-to-PDF exited 0 and wrote nothing until it
/// was given --user-data-dir in the scratch folder: Chrome makes its profile in the folder macOS
/// gives each user for temporary files, not $TMPDIR, and the fence doesn't let it write there.
/// The shell's description tells Claude, so the next run doesn't fail silently.
@Suite struct ShellChromeHintTests {
    @Test func theDescriptionNamesChromesProfileFolder() {
        #expect(ShellCapability.writesRule.contains("--user-data-dir in the scratch folder"))
        #expect(ShellCapability.writesRule.contains("writes nothing without a word"))
    }
}
