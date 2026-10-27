import Foundation
import Security
import Testing

@testable import Latchkey

/// The keep-awake helper runs as root: the app and the helper each talk only to a peer that
/// passes a code-signing requirement (threat model invariant 9). Nothing here contacts the
/// installed helper.
@Suite struct HelperSigningTests {
    /// A build with no team has no requirement to check the helper against: it must not connect
    /// at all (security review, 2026-10-25), so keep-awake reports the helper as unavailable.
    @Test func withoutARequirementThereIsNoConnection() {
        let none = HelperClient.makeConnection(requirement: nil)
        #expect(none == nil, "connected to whatever answers on the helper's name")
        // Never resumed with a message, so nothing reaches the helper; an XPC connection must be
        // resumed before it is invalidated.
        none?.resume()
        none?.invalidate()
        let checked = HelperClient.makeConnection(requirement: "identifier \"net.melisma.latchkey.helper\"")
        #expect(checked != nil)
        checked?.resume()
        checked?.invalidate()
    }

    static func satisfiesSelf(_ requirement: String) -> OSStatus {
        var code: SecCode?
        guard SecCodeCopySelf([], &code) == errSecSuccess, let code else { return errSecInternalError }
        var req: SecRequirement?
        let made = SecRequirementCreateWithString(requirement as CFString, [], &req)
        guard made == errSecSuccess, let req else { return made }
        return SecCodeCheckValidity(code, [], req)
    }

    /// Any program running as the Owner can take over an app signed with the debugging
    /// entitlement (get-task-allow), so a release helper refuses such a caller. The tests run in
    /// a development build of the app, which carries that entitlement: it is exactly the caller
    /// to refuse.
    @Test(.enabled(if: CodeSigning.ownTeamID() != nil)) func aDebuggableCallerIsRefusedByAReleaseHelper() throws {
        let team = try #require(CodeSigning.ownTeamID())
        let release = CodeSigning.requirement(
            identifier: AppIdentity.current.bundleID, team: team, allowDebuggable: false)
        let development = CodeSigning.requirement(
            identifier: AppIdentity.current.bundleID, team: team, allowDebuggable: true)
        #expect(Self.satisfiesSelf(development) == errSecSuccess, "a development pair still works together")
        #expect(Self.satisfiesSelf(release) == errSecCSReqFailed, "this debuggable app passed the release check")
    }

    @Test func theReleaseRequirementIsValidAndNamesTheEntitlement() {
        let release = CodeSigning.requirement(identifier: "a.b", team: "TEAM123456", allowDebuggable: false)
        #expect(release.contains(#"!(entitlement["com.apple.security.get-task-allow"] exists)"#))
        #expect(release.contains(#"identifier "a.b""#) && release.contains(#"= "TEAM123456""#))
        var req: SecRequirement?
        #expect(SecRequirementCreateWithString(release as CFString, [], &req) == errSecSuccess, "it compiles")
        #expect(
            !CodeSigning.requirement(identifier: "a.b", team: "T", allowDebuggable: true).contains("get-task-allow"))
    }
}

/// Sparkle is fetched by commit, not only by version tag: a tag can be moved to other code, a
/// commit can't (security review, 2026-10-25).
@Suite struct DependencyPinTests {
    @Test func sparkleIsPinnedByCommit() throws {
        let file = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appending(path: "../project.yml")
        let text = try String(contentsOf: file, encoding: .utf8)
        let block = try #require(text.firstMatch(of: /(?m)^  Sparkle:\n((?:    .*\n)+)/)).output.1
        #expect(block.contains("url: https://github.com/sparkle-project/Sparkle"))
        #expect(block.firstMatch(of: /(?m)^    revision: [0-9a-f]{40}  # \d+\.\d+\.\d+$/) != nil, "\(block)")
        // XcodeGen ignores `revision` when a version is also given, so there must be none.
        #expect(block.firstMatch(of: /(?m)^    (exactVersion|version|from|branch|majorVersion|minorVersion):/) == nil)
    }
}

/// A helper started before an install must notice that its program was replaced (2026-10-26).
@Suite struct FileStampTests {
    @Test func tellsAReplacedFileFromTheSameOne() throws {
        let dir = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appending(path: "LatchkeyHelper")
        try Data("old".utf8).write(to: file)
        let start = try #require(FileStamp.of(file.path))
        #expect(FileStamp.of(file.path) == start, "untouched")
        // An install puts a new file in place, as copying a new app bundle does.
        let new = dir.appending(path: "new")
        try Data("new".utf8).write(to: new)
        _ = try FileManager.default.replaceItemAt(file, withItemAt: new)
        #expect(FileStamp.of(file.path) != start, "replaced")
        try FileManager.default.removeItem(at: file)
        #expect(FileStamp.of(file.path) == nil, "gone")
    }
}
