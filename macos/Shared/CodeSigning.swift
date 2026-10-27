import Foundation
import Security

/// Which file is at a path: an install puts a new file there (a new inode), so a long-running
/// helper can tell that its own program was replaced (2026-10-26: a helper started before
/// several installs refused every app connection until the Mac restarted).
struct FileStamp: Equatable, Sendable {
    var device: UInt64
    var inode: UInt64
    var modified: TimeInterval

    /// Nil when nothing is at the path.
    static func of(_ path: String) -> FileStamp? {
        var s = stat()
        guard stat(path, &s) == 0 else { return nil }
        return FileStamp(
            device: UInt64(s.st_dev), inode: UInt64(s.st_ino),
            modified: TimeInterval(s.st_mtimespec.tv_sec) + TimeInterval(s.st_mtimespec.tv_nsec) / 1e9)
    }
}

enum CodeSigning {
    /// The team ID this process is signed with, if any.
    static func ownTeamID() -> String? {
        var code: SecCode?
        guard SecCodeCopySelf([], &code) == errSecSuccess, let code else { return nil }
        var staticCode: SecStaticCode?
        guard SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess, let staticCode else { return nil }
        var info: CFDictionary?
        guard
            SecCodeCopySigningInformation(staticCode, SecCSFlags(rawValue: kSecCSSigningInformation), &info)
                == errSecSuccess,
            let dict = info as? [String: Any]
        else { return nil }
        return dict[kSecCodeInfoTeamIdentifier as String] as? String
    }

    /// A code-signing requirement for a peer signed by the same team (plan D7: the helper only
    /// talks to our app, and the app only to our helper). Nil without a team: callers then
    /// refuse to connect.
    static func requirement(identifier: String) -> String? {
        guard let team = ownTeamID() else { return nil }
        return requirement(identifier: identifier, team: team, allowDebuggable: debugBuild)
    }

    /// Development builds carry the debugging entitlement themselves, so a development app and
    /// helper accept each other; a release build accepts no debuggable peer.
    static let debugBuild: Bool = {
        #if DEBUG
            true
        #else
            false
        #endif
    }()

    /// Unless `allowDebuggable`, the peer must not carry the debugging entitlement
    /// (get-task-allow): any program running as the Owner can take over such a process, and with
    /// it the right to talk to the root helper.
    static func requirement(identifier: String, team: String, allowDebuggable: Bool) -> String {
        let signed =
            "identifier \"\(identifier)\" and anchor apple generic and certificate leaf[subject.OU] = \"\(team)\""
        return allowDebuggable
            ? signed : signed + " and !(entitlement[\"com.apple.security.get-task-allow\"] exists)"
    }
}
