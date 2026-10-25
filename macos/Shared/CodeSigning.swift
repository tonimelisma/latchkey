import Foundation
import Security

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
