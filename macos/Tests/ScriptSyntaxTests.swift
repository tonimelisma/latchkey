import Foundation
import Testing

@testable import Latchkey

/// Every AppleScript Latchkey sends compiles against the real apps' scripting dictionaries on
/// this Mac (compiling sends no Apple Events, so it needs no permission).
@Suite struct ScriptSyntaxTests {
    static let scripts: [(String, String)] = [
        ("notes create", NotesCapability.Script.create), ("notes append", NotesCapability.Script.append),
        ("notes set body", NotesCapability.Script.setBody), ("notes get body", NotesCapability.Script.getBody),
        ("notes delete", NotesCapability.Script.delete), ("notes folders", NotesScriptReader.Script.folders),
        ("notes search", NotesScriptReader.Script.search), ("notes read", NotesScriptReader.Script.read),
        ("messages send", MessagesCapability.Script.send), ("safari open", SafariBrowser.Script.open),
        ("safari javascript", SafariBrowser.Script.javaScript), ("safari tabs", SafariBrowser.Script.tabs),
        ("safari probe", SafariBrowser.Script.probe), ("safari close", SafariBrowser.Script.close),
        ("safari tab addresses", SafariBrowser.Script.tabAddresses),
        ("safari find window", SafariBrowser.Script.findWindow),
        ("safari any tab at", SafariBrowser.Script.anyTabAt),
        ("notes delete folder", NotesCapability.Script.deleteFolder),
        ("safari tab survey", SafariBrowser.Script.tabSurvey),
        ("safari tab javascript", SafariBrowser.Script.tabJavaScript),
        ("safari tab load", SafariBrowser.Script.tabLoad), ("safari tab new", SafariBrowser.Script.tabNew),
        ("safari tab show", SafariBrowser.Script.tabShow), ("safari tab restore", SafariBrowser.Script.tabRestore),
        ("safari tab close", SafariBrowser.Script.tabClose),
        ("mail accounts", MailScript.accounts), ("mail change", MailScript.change),
        ("mail save attachment", MailScript.saveAttachment),
    ]

    @Test(arguments: scripts.map(\.0))
    func compiles(_ name: String) async throws {
        let source = try #require(Self.scripts.first { $0.0 == name }?.1)
        let file = FileManager.default.temporaryDirectory.appending(path: "\(UUID().uuidString).applescript")
        try source.write(to: file, atomically: true, encoding: .utf8)
        let r = try await ProcessCommands.launch(
            "/usr/bin/osacompile", ["-o", "/dev/null", file.path], timeout: .seconds(30))
        #expect(r.status == 0, "\(name): \(r.errorText)")
    }
}
