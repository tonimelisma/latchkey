import Foundation
import Testing

@testable import Latchkey

/// Regression cases whose live check needs macOS's privacy system or another app's window, tested
/// at the decision Latchkey's own code makes (docs/regression-coverage.md).
@Suite struct RegressionSeamsTests {
    // MARK: regressions.never_disturb_no_permission_prompts

    /// 2026-10-31: a script for an app macOS hadn't asked about raised "Allow Latchkey to …" on
    /// the owner's screen during use. Such a script is refused before osascript runs (FR-623).
    @Test func aScriptForAnAppMacOSHasntAskedAboutIsNeverRun() async {
        let runner = OSAScriptRunner(app: "com.apple.Notes", automation: { _ in .notAsked })
        await #expect(throws: ScriptError.notAllowed) {
            _ = try await runner.run("return \"ran\"", [])
        }
    }

    // MARK: regressions.setup_ask_now_says_what_is_off

    /// Toni, 2026-11-21: Ask Now did nothing when Mail had been turned off for Latchkey earlier,
    /// which macOS never asks about again. Setup's note names the apps and where to turn them on.
    @Test func appsTurnedOffEarlierAreNamedWithWhereToTurnThemOn() throws {
        #expect(AppModel.turnedOffNote([]) == nil)
        let one = try #require(AppModel.turnedOffNote(["Mail"]))
        #expect(one.hasPrefix("Mail was turned off for Latchkey earlier, so macOS won't ask again."), "\(one)")
        #expect(one.contains("Privacy & Security → Automation") && one.hasSuffix("turn on Mail."), "\(one)")
        let two = try #require(AppModel.turnedOffNote(["Mail", "Notes"]))
        #expect(two.hasPrefix("Mail, Notes were turned off"), "\(two)")
        #expect(two.hasSuffix("turn on Mail and Notes."), "\(two)")
    }

    // MARK: regressions.computer_window_buttons_named

    /// 2026-11-20: a window's close, minimize and zoom buttons were listed with empty names, so
    /// the close button had to be guessed. Their kind names them.
    @Test func windowButtonsWithoutATitleAreNamedByTheirKind() {
        for sub in ["AXCloseButton", "AXMinimizeButton", "AXZoomButton", "AXFullScreenButton"] {
            let name = AppWindowReader.label(
                title: nil, description: "", help: nil, subrole: sub, roleDescription: { "close button" })
            #expect(name == "close button", "\(sub)")
        }
        // A title wins; other untitled elements stay unnamed rather than get their kind.
        #expect(
            AppWindowReader.label(
                title: "Save", description: "d", help: nil, subrole: "AXCloseButton", roleDescription: { "button" })
                == "Save")
        #expect(
            AppWindowReader.label(
                title: "", description: "Search", help: nil, subrole: nil, roleDescription: { "text field" })
                == "Search")
        #expect(
            AppWindowReader.label(title: nil, description: nil, help: nil, subrole: nil, roleDescription: { "group" })
                == "")
    }

    // MARK: regressions.computer_press_selects_sidebar_row

    /// 2026-11-20/22: press couldn't select a SwiftUI sidebar row (Otos). A press on a row, a
    /// cell, or text in one selects the row; a button or checkbox in a row is pressed instead.
    @Test func aPressOnARowItsCellOrItsTextSelectsTheRow() {
        for role in ["AXRow", "AXCell", "AXStaticText"] { #expect(AppWindowReader.selectsRow(role: role), "\(role)") }
        for role in ["AXButton", "AXCheckBox", "AXTextField", "AXPopUpButton", "AXLink"] {
            #expect(!AppWindowReader.selectsRow(role: role), "\(role)")
        }
    }
}
