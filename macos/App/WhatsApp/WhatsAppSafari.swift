import Foundation
import WebKit

/// Where the Owner's WhatsApp Web tab in Safari stands (spec 012 plan D1).
enum WhatsAppPageState: Equatable, Sendable {
    /// The tab can't be used now, and why: none open, Safari won't run scripts, or isn't answering.
    case unavailable(String)
    /// WhatsApp Web hasn't set itself up yet (loading, or a sync screen).
    case loading
    /// The tab shows WhatsApp's log-in screen.
    case notLinked
    /// Logged in, but not connected to WhatsApp right now.
    case connecting
    case connected
    /// WhatsApp Web no longer has functions Latchkey uses (an update renamed them).
    case changed([String])
}

enum WhatsAppPageError: Error, Equatable {
    case timedOut
    case failed(String)
}

/// What the WhatsApp tools need from WhatsApp Web; `SafariWhatsApp` is the real one, tests use a
/// stand-in.
protocol WhatsAppPageAPI: Sendable {
    /// Calls `window.__latchkey.<function>(args)` in the tab and returns its answer.
    func call(_ function: String, _ args: JSONValue, timeout: Duration) async throws -> JSONValue
    /// Looks at the tab for up to `wait` until WhatsApp is connected (it never reloads the tab).
    func ready(wait: Duration) async -> WhatsAppPageState
}

/// The Owner's WhatsApp Web tab in Safari, driven with Safari's `do JavaScript` (plan D1). The tab
/// is never selected, reloaded, navigated, or closed, and Safari never comes to the front.
struct SafariWhatsApp: WhatsAppPageAPI {
    /// A script runner allowed `limit` in all (a call's own time plus room for Safari to start).
    var runner: @Sendable (Duration) -> any ScriptRunner = { OSAScriptRunner(app: "Safari", timeout: $0) }
    var locked: @Sendable () -> Bool = { SystemScreen().isLocked() }

    static let noTab =
        "WhatsApp Web isn't open in Safari on the Mac (a tab at web.whatsapp.com, logged in)"
    static let scriptsOff =
        "Safari doesn't let Latchkey run scripts in pages: in Safari, turn on Develop → Allow JavaScript from Apple Events"
    static let notAllowed =
        "Latchkey isn't allowed to control Safari (System Settings → Privacy & Security → Automation)"

    func call(_ function: String, _ args: JSONValue, timeout: Duration) async throws -> JSONValue {
        let id = String(UInt64.random(in: 1...UInt64.max), radix: 36)
        let tries = max(1, Int(timeout.components.seconds) * 5)
        // The start script goes through a file only Latchkey can read: with files in it, it is far
        // larger than a program's arguments may be (about 1 MB).
        let file = FileManager.default.temporaryDirectory.appending(path: "latchkey-whatsapp-\(id).js")
        guard
            FileManager.default.createFile(
                atPath: file.path, contents: Data(Self.start(function, args, id: id).utf8),
                attributes: [.posixPermissions: 0o600])
        else { throw WhatsAppPageError.failed("Latchkey couldn't write its script for Safari") }
        defer { try? FileManager.default.removeItem(at: file) }
        let out: String
        do {
            out = try await runner(timeout + .seconds(10)).run(
                Self.script, [file.path, Self.poll(id: id), String(tries)])
        } catch ScriptError.timedOut {
            if locked() {
                throw WhatsAppPageError.failed(
                    "Safari stopped answering while the Mac is locked; it answers again once someone unlocks the Mac")
            }
            throw WhatsAppPageError.timedOut
        } catch ScriptError.notAllowed {
            throw WhatsAppPageError.failed(Self.notAllowed)
        } catch ScriptError.failed(let message) {
            if message.contains("LATCHKEY_NO_WHATSAPP_TAB") { throw WhatsAppPageError.failed(Self.noTab) }
            if message.contains("Allow JavaScript from Apple Events") {
                throw WhatsAppPageError.failed(Self.scriptsOff)
            }
            throw WhatsAppPageError.failed("Safari reported a problem: \(message)")
        }
        return try Self.answer(out)
    }

    func ready(wait: Duration) async -> WhatsAppPageState {
        let end = ContinuousClock.now + wait
        var last = WhatsAppPageState.loading
        while true {
            do {
                last = Self.state(from: try await call("state", .object([:]), timeout: .seconds(5)))
            } catch WhatsAppPageError.failed(let why) {
                return .unavailable(why)
            } catch {
                return .unavailable("Safari didn't answer in time")
            }
            switch last {
            case .connected, .notLinked, .changed, .unavailable: return last
            case .loading, .connecting: break
            }
            if ContinuousClock.now >= end || Task.isCancelled { return last }
            try? await Task.sleep(for: .seconds(1))
        }
    }

    /// The bridge's `state()` answer as a state. The log-in screen first: there WhatsApp Web hasn't
    /// loaded its modules, so only a tab showing its chats can say a module is gone (2026-11-03).
    static func state(from answer: JSONValue) -> WhatsAppPageState {
        if answer["loginScreen"]?.boolValue == true { return .notLinked }
        if answer["chatList"]?.boolValue == true, case .array(let gone) = answer["missing"], !gone.isEmpty {
            return .changed(gone.compactMap(\.stringValue))
        }
        if answer["connected"]?.boolValue == true { return .connected }
        if (answer["chats"]?.numberValue ?? 0) > 0 { return .connecting }
        return .loading
    }

    /// What the script answered: "OK" and the function's JSON, "ER" and its error, or nothing when
    /// the time ran out.
    static func answer(_ out: String) throws -> JSONValue {
        if out.isEmpty { throw WhatsAppPageError.timedOut }
        if out.hasPrefix("ER") { throw WhatsAppPageError.failed(String(out.dropFirst(2))) }
        guard out.hasPrefix("OK") else { throw WhatsAppPageError.failed("WhatsApp Web gave an unexpected answer") }
        return (try? JSONDecoder().decode(JSONValue.self, from: Data(out.dropFirst(2).utf8))) ?? .null
    }

    /// Puts the bridge in the tab when it lacks this version, and starts `function` with its answer
    /// kept under `id`. `args` goes in as JSON (which is JavaScript); `function` is one of the
    /// bridge's fixed names. Answers "started", or "failed: …".
    static func start(_ function: String, _ args: JSONValue, id: String) -> String {
        """
        (function () { try {
        if (location.origin !== 'https://web.whatsapp.com') return "failed: the tab is not WhatsApp Web";
        if (!window.__latchkey || window.__latchkey.version !== \(WhatsAppBridge.version)) {
        \(WhatsAppBridge.source)
        }
        window.__lkr = window.__lkr || {};
        var f = window.__latchkey[\(JSONValue.string(function).jsonText)];
        if (typeof f !== 'function') return 'failed: no such function';
        Promise.resolve().then(function () { return f.call(window.__latchkey, \(args.jsonText)); }).then(
        function (v) { window.__lkr['\(id)'] = { ok: JSON.stringify(v === undefined ? null : v) }; },
        function (e) { window.__lkr['\(id)'] = { err: String((e && e.message) || e) }; });
        return 'started';
        } catch (e) { return 'failed: ' + String((e && e.message) || e); } })()
        """
    }

    /// The answer kept under `id`, taken once: "OK…", "ER…", or "" while it isn't there yet.
    static func poll(id: String) -> String {
        """
        (function () { var r = window.__lkr && window.__lkr['\(id)']; if (!r) return '';
        delete window.__lkr['\(id)']; return r.ok !== undefined ? 'OK' + r.ok : 'ER' + r.err; })()
        """
    }

    /// argv: the start script's file, the poll script, how many polls (0.2 s apart). Finds the first tab at
    /// web.whatsapp.com in any window without selecting it.
    static let script = """
        on run argv
        set startJS to read (POSIX file (item 1 of argv)) as «class utf8»
        set pollJS to item 2 of argv
        set tries to (item 3 of argv) as integer
        tell application "Safari"
        set theTab to missing value
        repeat with w in windows
        repeat with t in tabs of w
        set theAddress to ""
        try
        set theAddress to (URL of t) as text
        end try
        if theAddress starts with "https://web.whatsapp.com/" then
        set theTab to contents of t
        exit repeat
        end if
        end repeat
        if theTab is not missing value then exit repeat
        end repeat
        if theTab is missing value then error "LATCHKEY_NO_WHATSAPP_TAB"
        set started to do JavaScript startJS in theTab
        if started is missing value then set started to ""
        if (started as text) is not "started" then error "LATCHKEY_NOT_STARTED " & (started as text)
        repeat tries times
        delay 0.2
        set theAnswer to do JavaScript pollJS in theTab
        if theAnswer is not missing value then
        if (theAnswer as text) is not "" then return theAnswer as text
        end if
        end repeat
        return ""
        end tell
        end run
        """
}

/// Latchkey's own WhatsApp device was withdrawn (Toni, 2026-11-04, plan D4): at the first start
/// without it, what it stored is deleted, once.
@MainActor
enum WhatsAppOldDevice {
    static let storeID = UUID(uuidString: "6F1C2A4E-8B3D-4E51-9A7C-1D2E3F405162")!
    static let doneKey = "whatsappOldDeviceRemoved"

    static func removeOnce(_ defaults: UserDefaults = .standard) async {
        guard !defaults.bool(forKey: doneKey) else { return }
        // WebKit must be set up (a web view made) before a store can be removed (0.8.101 crashed).
        let starter = WKWebView(frame: .zero)
        try? await WKWebsiteDataStore.remove(forIdentifier: storeID)
        _ = starter
        defaults.removeObject(forKey: "whatsappLinked")
        defaults.set(true, forKey: doneKey)
        EventLog.shared.record(.app, "WhatsApp: deleted what Latchkey's own WhatsApp device stored (withdrawn)")
    }
}
