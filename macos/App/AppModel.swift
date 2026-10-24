import AppKit
import ApplicationServices
import Contacts
import Foundation
import Network
import OSLog
import Observation
import ServiceManagement
import UserNotifications

/// The app's state and behavior; the menu bar UI reads from it.
@MainActor
@Observable
final class AppModel {
    private(set) var status: ConnectionStatus = .notPaired
    private(set) var power = PowerReader.read()
    private(set) var keepAwake: KeepAwake = .offUser
    private(set) var relayURL: URL?
    private(set) var helperStatus: SMAppService.Status = .notRegistered
    var lastError: String?

    var keepAwakeEnabled: Bool {
        didSet { defaults.set(keepAwakeEnabled, forKey: Keys.keepAwake); Task { await refresh() } }
    }
    private(set) var capabilities: CapabilityRegistry
    private(set) var startsAtLogin = SMAppService.mainApp.status == .enabled

    let trace: TraceStore?
    let updates = Updates()
    private let keepAwakeController = KeepAwakeController()
    private var connection: RelayConnection?
    private var powerMonitor: PowerMonitor?
    private var pathMonitor: NWPathMonitor?
    private var lastPathSatisfied: Bool?
    private var observers: [NSObjectProtocol] = []
    private let defaults = UserDefaults.standard
    private let pairing = PairingFlow()
    private var trashWatcher: TrashWatcher?
    private var uninstalling = false
    private let setupWindow = SetupWindow()

    /// Pairing and uninstall events, readable with `log show --predicate 'subsystem == "net.melisma.latchkey"'`.
    /// Events only, never arguments or results.
    static let log = Logger(subsystem: "net.melisma.latchkey", category: "lifecycle")
    static let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"

    /// Every capability, in menu order.
    static func makeCapabilities() -> [Capability] {
        [
            NotesCapability.make(), MessagesCapability.make(), FilesCapability.make(), ShellCapability.make(),
            BrowserCapability.make(), ComputerCapability.make(),
        ]
    }

    private enum Keys {
        static let keepAwake = "keepAwakeEnabled"
        static let levels = "capabilityLevels"
        static let launchedBefore = "launchedBefore"
        static let appControl = "appControlAllowed"
        static let safariJavaScript = "safariJavaScriptAllowed"
    }

    init() {
        let d = UserDefaults.standard
        keepAwakeEnabled = d.object(forKey: Keys.keepAwake) as? Bool ?? true
        var levels = CapabilityRegistry.defaultLevels  // FR-121
        for (id, raw) in d.dictionary(forKey: Keys.levels) as? [String: String] ?? [:] {
            if let level = AccessLevel(rawValue: raw) { levels[id] = level }
        }
        capabilities = CapabilityRegistry(
            capabilities: Self.makeCapabilities(), levels: levels)
        do {
            trace = try TraceStore()
        } catch {
            trace = nil
            Self.log.error("Activity log unavailable: \(error.localizedDescription, privacy: .public)")
        }
    }

    // MARK: lifecycle

    func start() {
        if !defaults.bool(forKey: Keys.launchedBefore) {
            defaults.set(true, forKey: Keys.launchedBefore)
            setStartsAtLogin(true)  // FR-076
        }
        keepAwakeController.helper.registerIfNeeded()
        keepAwakeController.helper.onInterrupted = { [weak self] in
            Task {
                try? await Task.sleep(for: .seconds(1))  // the helper restarts with normal sleep
                await self?.refresh()
            }
        }
        helperStatus = keepAwakeController.helper.status
        let installedPath = Bundle.main.bundleURL.path
        trashWatcher = TrashWatcher(bundle: Bundle.main.bundleURL) { [weak self] in
            Task { await self?.movedToTrash(installedPath: installedPath) }
        }
        powerMonitor = PowerMonitor { [weak self] in Task { await self?.refresh() } }
        watchSystem()
        purgeTrace()
        if let identity = DeviceIdentity.load() {
            Self.log.notice(
                "Started \(Self.version, privacy: .public), paired with \(identity.relayURL.absoluteString, privacy: .public)"
            )
            relayURL = identity.relayURL
            connect(identity)
        } else {
            Self.log.notice(
                "Started \(Self.version, privacy: .public), not paired (\(DeviceIdentity.missing, privacy: .public))")
        }
        Task { await refresh() }
        loadRecentActivity()
        if needsSetup { showSetup() }
    }

    /// The setup window: approve keep-awake, connect to a relay (FR-078).
    func showSetup() { setupWindow.show(model: self) }

    var needsSetup: Bool {
        !isPaired || helperStatus != .enabled || (capabilities.anyOn && !fullDiskAccess) || needsAppControl
            || needsSafariJavaScript || needsScreenRecording || needsAccessibility
            || needsContacts
    }

    /// Re-reads whether the Owner approved the helper; applies keep-awake as soon as they do.
    func checkHelperApproval() async {
        let before = helperStatus
        helperStatus = keepAwakeController.helper.status
        if before != helperStatus { await refresh() }
    }

    /// The app landed in the Trash. If a newer copy takes its place within a few seconds, this is
    /// an update: hand over to it and quit. Otherwise uninstall.
    func movedToTrash(installedPath: String) async {
        Self.log.notice("The app was moved to the Trash; waiting to see whether it was replaced")
        for _ in 0..<25 {
            if AppLocation.replaced(at: installedPath) {
                await shutdown()
                let config = NSWorkspace.OpenConfiguration()
                config.createsNewApplicationInstance = true
                _ = try? await NSWorkspace.shared.openApplication(
                    at: URL(fileURLWithPath: installedPath), configuration: config)
                NSApp.terminate(nil)
                return
            }
            try? await Task.sleep(for: .milliseconds(200))
        }
        Self.log.notice("Not replaced: uninstalling")
        await uninstall()
    }

    /// Moved to the Trash: disconnect from the account, restore sleep, remove the login and
    /// background items and every local file, then quit (FR-077, SC-09).
    func uninstall() async {
        guard !uninstalling else { return }
        uninstalling = true
        await connection?.stop(goodbye: .userDisconnected, state: agentState)
        connection = nil
        await keepAwakeController.restore()
        await BackgroundItems.unregisterAll()
        LocalData().remove()
        NSApp.terminate(nil)
    }

    /// Quit: tell the relay, restore sleep (FR-035).
    func shutdown() async {
        if uninstalling { return }
        await connection?.stop(goodbye: .userQuit, state: agentState)
        await ShellCapability.jobs.stopAll()  // spec 004 FR-309
        await keepAwakeController.restore()
    }

    private func watchSystem() {
        let ws = NSWorkspace.shared.notificationCenter
        observers.append(
            ws.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    let reason = KeepAwakePolicy.sleepReason(self.keepAwake)
                    Task { await self.connection?.sendGoodbye(reason) }
                }
            })
        observers.append(
            ws.addObserver(forName: NSWorkspace.willPowerOffNotification, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    Task { await self.connection?.sendGoodbye(.systemShutdown) }
                }
            })
        observers.append(
            ws.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    Task {
                        await self.refresh()  // re-apply keep-awake after wake (FR-031)
                        await self.connection?.reconnectNow()
                    }
                }
            })
        let monitor = NWPathMonitor()
        monitor.pathUpdateHandler = { @Sendable [weak self] path in
            let ok = path.status == .satisfied
            Task { @MainActor in await self?.pathChanged(satisfied: ok) }
        }
        monitor.start(queue: .main)
        pathMonitor = monitor
    }

    /// A network change reconnects at once instead of waiting for backoff (FR-004, SC-05).
    private func pathChanged(satisfied: Bool) async {
        defer { lastPathSatisfied = satisfied }
        if satisfied, lastPathSatisfied != nil { await connection?.reconnectNow() }
    }

    private func purgeTrace() {
        _ = try? trace?.purge(olderThan: Date().addingTimeInterval(-TraceStore.retention))
        Task {
            try? await Task.sleep(for: .seconds(86_400))
            purgeTrace()
        }
    }

    // MARK: power and keep-awake

    /// Re-reads power state, re-applies keep-awake, and reports any change (FR-031, FR-036).
    func refresh() async {
        power = PowerReader.read()
        helperStatus = keepAwakeController.helper.status
        let decision = KeepAwakePolicy.decide(
            KeepAwakeInputs(
                powerSource: power.powerSource, batteryPercent: power.batteryPercent, thermal: power.thermal,
                userEnabled: keepAwakeEnabled, helperAvailable: keepAwakeController.helperApproved))
        let ok = await keepAwakeController.apply(decision)
        keepAwake = (decision == .on && !ok) ? .offHelperUnavailable : decision
        await connection?.sendState()
    }

    func approveHelper() { keepAwakeController.helper.openApprovalSettings() }

    var agentState: AgentState { power.agentState(keepAwake: keepAwake) }

    // MARK: capabilities

    func setLevel(_ id: String, _ level: AccessLevel) {
        capabilities.setLevel(id, level)
        defaults.set(capabilities.levels.mapValues(\.rawValue), forKey: Keys.levels)
        Task { await connection?.sendTools() }  // FR-062
        if needsSetup { showSetup() }
    }

    // MARK: permissions

    private(set) var fullDiskAccess = Permissions.hasFullDiskAccess

    func checkFullDiskAccess() { fullDiskAccess = Permissions.hasFullDiskAccess }

    /// Which apps Latchkey may control (Automation), remembered once seen: macOS can only say
    /// while the app runs.
    private(set) var appControl: [String: Permissions.Automation] = Dictionary(
        uniqueKeysWithValues: (UserDefaults.standard.stringArray(forKey: Keys.appControl) ?? []).map { ($0, .allowed) })

    /// The app each capability drives when it changes things.
    static let controlledApps = [
        CapabilityRegistry.notes: Permissions.notesApp, CapabilityRegistry.messages: Permissions.messagesApp,
    ]

    func control(of app: String) -> Permissions.Automation { appControl[app] ?? .notAsked }

    /// Changing notes and sending messages need it; asked in setup so no prompt waits on an
    /// unattended Mac (FR-140).
    func needsControl(for capability: String) -> Bool {
        guard let app = Self.controlledApps[capability] else { return false }
        // Reading Safari pages needs it too; Notes and Messages read their databases.
        let level = capabilities.level(capability)
        let needed = capability == CapabilityRegistry.browser ? level != .off : level == .readWrite
        return needed && control(of: app) != .allowed
    }

    /// Safari's "Allow JavaScript from Apple Events" (spec 005 FR-406): only a test shows it.
    private(set) var safariJavaScript: Bool? =
        UserDefaults.standard.object(forKey: Keys.safariJavaScript) as? Bool == true ? true : nil

    var needsSafariJavaScript: Bool {
        capabilities.level(CapabilityRegistry.browser) != .off && safariJavaScript != true
    }

    /// Computer control (spec 006 FR-506): Screen Recording to see, Accessibility to act.
    private(set) var screenRecording = CGPreflightScreenCaptureAccess()
    private(set) var accessibility = AXIsProcessTrusted()

    var needsScreenRecording: Bool { capabilities.level(CapabilityRegistry.computer) != .off && !screenRecording }
    var needsAccessibility: Bool { capabilities.level(CapabilityRegistry.computer) != .off && !accessibility }

    func checkScreenPermissions() {
        screenRecording = CGPreflightScreenCaptureAccess()
        accessibility = AXIsProcessTrusted()
    }

    /// Asks macOS to show its prompt the first time; after that, opens System Settings.
    func allowScreenRecording() {
        if !CGRequestScreenCaptureAccess() { Permissions.openPrivacySettings("Privacy_ScreenCapture") }
        checkScreenPermissions()
    }

    func allowAccessibility() {
        let prompt = "AXTrustedCheckOptionPrompt"  // kAXTrustedCheckOptionPrompt, which Swift 6 rejects as shared state
        if !AXIsProcessTrustedWithOptions([prompt: true] as CFDictionary) {
            Permissions.openPrivacySettings("Privacy_Accessibility")
        }
        checkScreenPermissions()
    }

    func checkSafariJavaScript() async {
        do {
            try await BrowserCapability.browser.probe()
            safariJavaScript = true
        } catch {
            safariJavaScript = false
        }
        defaults.set(safariJavaScript == true, forKey: Keys.safariJavaScript)
    }

    var needsAppControl: Bool { Self.controlledApps.keys.contains { needsControl(for: $0) } }

    func checkAppControl() async {
        for app in Self.controlledApps.values {
            let state = await Task.detached { Permissions.automation(of: app, ask: false) }.value
            if let state { setControl(app, state) }
        }
    }

    /// Opens the app in the background if needed, then lets macOS ask the Owner.
    func allowControl(of app: String) async {
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: app) {
            let config = NSWorkspace.OpenConfiguration()
            config.activates = false
            config.hides = true
            _ = try? await NSWorkspace.shared.openApplication(at: url, configuration: config)
        }
        let state = await Task.detached { Permissions.automation(of: app, ask: true) }.value
        if let state { setControl(app, state) }
    }

    private func setControl(_ app: String, _ state: Permissions.Automation) {
        appControl[app] = state
        defaults.set(appControl.filter { $0.value == .allowed }.keys.sorted(), forKey: Keys.appControl)
    }

    /// Contacts gives names to numbers in Messages (FR-111). Asked once in setup; after a "Don't
    /// Allow", messages show numbers and setup stops asking.
    private(set) var contactsStatus = CNContactStore.authorizationStatus(for: .contacts)

    var needsContacts: Bool {
        capabilities.level(CapabilityRegistry.messages) != .off && contactsStatus == .notDetermined
    }

    func checkContacts() { contactsStatus = CNContactStore.authorizationStatus(for: .contacts) }

    func allowContacts() async {
        _ = try? await CNContactStore().requestAccess(for: .contacts)
        checkContacts()
    }

    func setStartsAtLogin(_ on: Bool) {
        do {
            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
        } catch {
            lastError = "Couldn't change Start at Login: \(error.localizedDescription)"
        }
        startsAtLogin = SMAppService.mainApp.status == .enabled
    }

    // MARK: pairing and connection

    func pair(relayText: String) async {
        lastError = nil
        guard let relay = PairingFlow.normalize(relayText) else {
            lastError = PairingError.invalidRelay.errorDescription
            return
        }
        do {
            let identity = try await pairing.pair(relay: relay, macName: Host.current().localizedName ?? "Mac")
            relayURL = relay
            connect(identity)
        } catch PairingError.cancelled {
            // nothing to report
        } catch {
            lastError = error.localizedDescription
        }
    }

    /// A latchkey://paired link opened by the system, that is, not through the app's own sign-in
    /// window (whose callback goes straight to `pair`). Whether or not a pairing is in progress,
    /// it connects only after the Owner confirms a dialog naming the relay and the email of the
    /// account the code belongs to (FR-054), so a link from someone else can't quietly connect
    /// this Mac to their account.
    func open(_ url: URL) {
        guard let link = PairingFlow.parse(url), let relay = link.relay else {
            lastError = "That connection link is incomplete. Choose Connect to a Relay… again."
            return
        }
        if pairing.isOwn(link.code) { return }  // the sign-in window already delivered it
        Task {
            let email = try? await PairingFlow.preview(relay: relay, code: link.code)
            let ask = PairingConfirmation(
                relay: relay, email: email, current: isPaired ? relayURL : nil,
                hosted: PairingFlow.normalize(Self.hostedRelay))
            let alert = NSAlert()
            alert.messageText = ask.title
            alert.informativeText = ask.message
            if ask.canConnect {
                alert.addButton(withTitle: "Connect")
                alert.addButton(withTitle: "Cancel")
            } else {
                alert.addButton(withTitle: "OK")
            }
            NSApp.activate()
            guard alert.runModal() == .alertFirstButtonReturn, ask.canConnect else { return }
            Self.log.notice("Pairing link confirmed for \(relay.absoluteString, privacy: .public)")
            pairing.cancelPending()  // the sign-in window's pairing, if one is open, gives way
            do {
                let identity = try await PairingFlow.exchange(
                    relay: relay, code: link.code, macName: Host.current().localizedName ?? "Mac")
                relayURL = relay
                connect(identity)
            } catch {
                lastError = error.localizedDescription
                showSetup()
            }
        }
    }

    /// The hosted relay, offered by default in setup; self-hosters type their own.
    /// From the build setting LATCHKEY_DEFAULT_RELAY_HOST (set in the gitignored Local.xcconfig);
    /// empty in a build without one, so no relay address lives in the repository.
    static let hostedRelay: String = {
        let host = Bundle.main.object(forInfoDictionaryKey: "LatchkeyDefaultRelayHost") as? String ?? ""
        return host.isEmpty ? "" : "https://\(host)"
    }()

    /// Disconnect This Mac: the relay revokes it (goodbye user_disconnected) and the key is deleted.
    func disconnect() async {
        await connection?.stop(goodbye: .userDisconnected, state: agentState)
        connection = nil
        Self.log.notice("Disconnect This Mac: forgetting the pairing")
        DeviceIdentity.delete()
        status = .notPaired
    }

    private func connect(_ identity: DeviceIdentity) {
        if let old = connection { Task { await old.stop(goodbye: nil) } }
        lastError = nil
        let hooks = ConnectionHooks(
            state: { [weak self] in
                await MainActor.run { self?.agentState } ?? PowerReader.read().agentState(keepAwake: .offUser)
            },
            tools: { [weak self] in await MainActor.run { self?.capabilities.tools } ?? [] },
            call: { [weak self] call in await self?.handle(call) ?? .text("The app is shutting down.", isError: true) },
            status: { [weak self] s in await self?.connectionChanged(s) },
            notice: { [weak self] n in await self?.show(n) })
        let c = RelayConnection(identity: identity, hooks: hooks)
        connection = c
        Task { await c.start() }
    }

    private func connectionChanged(_ s: ConnectionStatus) {
        status = s
        if s == .revoked {  // 4002: delete the local key (agent-protocol.md)
            Self.log.notice("The relay revoked this Mac: forgetting the pairing")
            DeviceIdentity.delete()
            connection = nil
        }
    }

    /// Runs a call and records it in the local trace (FR-026).
    private func handle(_ call: Call) async -> ToolResult {
        let started = Date()
        busy += 1  // FR-132
        defer { busy -= 1 }
        let registry = capabilities
        let result = await registry.call(tool: call.tool, arguments: call.arguments)
        let entry = Activity(
            at: started, tool: call.tool, arguments: call.arguments.jsonText,
            result: result.content.jsonText, isError: result.isError,
            durationMS: Int(Date().timeIntervalSince(started) * 1000))
        try? trace?.record(entry)
        loadRecentActivity()
        if let activity = result.activity, !result.isError { Notifier.post(activity) }  // FR-130
        return result
    }

    // MARK: activity (FR-131, FR-132)

    /// Calls running now; the menu bar icon shows a dot while above zero.
    private(set) var busy = 0
    private(set) var recentActivity: [Activity] = []

    func loadRecentActivity() { recentActivity = (try? trace?.recent(limit: 10)) ?? [] }

    /// Account recovered (plan D5) or a Claude client given access: tell the Owner on this Mac.
    private func show(_ n: Notice) async {
        let content = UNMutableNotificationContent()
        let when = n.at.formatted(date: .abbreviated, time: .shortened)
        switch n.kind {
        case "account_recovered":
            content.title = "Your Latchkey account was recovered"
            content.body =
                "A new passkey was created on \(when). If this wasn't you, recover your account again and check your account page."
        case "client_authorized":
            content.title = "\(n.client ?? "Claude") can now use this Mac"
            content.body =
                "It was given access through Latchkey on \(when). If this wasn't you, remove it on your Latchkey account page."
        default:
            return
        }
        let center = UNUserNotificationCenter.current()
        _ = try? await center.requestAuthorization(options: [.alert, .sound])
        try? await center.add(
            UNNotificationRequest(identifier: "\(n.kind)-\(n.at.timeIntervalSince1970)", content: content, trigger: nil)
        )
    }

    // MARK: menu text

    var statusLine: String {
        switch status {
        case .notPaired: "Not connected to a relay"
        case .connecting: "Connecting…"
        case .connected: "Connected"
        case .waiting(let until):
            "Reconnecting in \(max(1, Int(until.timeIntervalSinceNow.rounded()))) s"
        case .signInAgain: "Sign in again: the relay didn't accept this Mac"
        case .revoked: "Disconnected from your account"
        case .replaced: "Replaced by another connection from this Mac"
        case .updateRequired: "Update Latchkey to connect"
        }
    }

    var batteryLine: String {
        guard power.hasBattery else { return "Power: plugged in (no battery)" }
        let source = power.charging ? "charging" : (power.powerSource == .battery ? "on battery" : "plugged in")
        return "Battery \(power.batteryPercent)%, \(source)"
    }

    var keepAwakeLine: String {
        switch keepAwake {
        case .on: "Keeping this Mac awake"
        case .offUser: "Keep-awake is off"
        case .offLowBattery: "Allowing sleep: battery at 15% or less"
        case .offTooHot: "Allowing sleep: Mac is too hot"
        case .offHelperUnavailable: "Keep-awake needs approval in System Settings"
        }
    }

    var isPaired: Bool { status != .notPaired && status != .revoked }

    var menuIcon: String { status == .connected ? "key.fill" : "key" }
}
