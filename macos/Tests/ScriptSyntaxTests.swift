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
        ("safari probe", SafariBrowser.Script.probe),
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
