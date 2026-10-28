import AppKit
import ApplicationServices
import Contacts
import EventKit
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
    /// Pause Claude's Access (FR-602); read from storage at once, so it holds from the start.
    private(set) var paused = Pause.isPaused(.standard)

    /// The activity log, or why there is none for this launch (FR-201).
    let activityLog: ActivityLog
    var trace: TraceStore? { activityLog.store }
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
    private let links = OneAtATime()

    /// Pairing and uninstall events, readable with `log show --predicate 'subsystem == "net.melisma.latchkey"'`
    /// (a Debug build logs as "net.melisma.latchkey.dev").
    /// Events only, never arguments or results.
    static let log = Logger(subsystem: AppIdentity.current.logSubsystem, category: "lifecycle")
    static let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"

    /// Every capability, in menu order.
    static func makeCapabilities() -> [Capability] {
        [
            NotesCapability.make(), MessagesCapability.make(), FilesCapability.make(), ShellCapability.make(),
            BrowserCapability.make(), ComputerCapability.make(), CalendarCapability.make(),
            RemindersCapability.make(), ContactsCapability.make(), LocationCapability.make(),
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
        activityLog = ActivityLog.open()
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
        if let identity = DeviceIdentity.load() {
            Self.log.notice(
                "Started \(Self.version, privacy: .public), paired with \(identity.relayURL.absoluteString, privacy: .private(mask: .hash))"
            )
            relayURL = identity.relayURL
            // Paired from this moment, not from the connection's first report a moment later:
            // otherwise the setup check below opens its window on every start (FR-205).
            status = .atStart(paired: true)
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
            || needsContacts || needsCalendar || needsReminders || needsLocation
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
                    Diagnostics.power.notice(
                        "Going to sleep: keep-awake \(self.keepAwake.rawValue, privacy: .public), lid \(PowerReader.lidClosed().map { $0 ? "closed" : "open" } ?? "none", privacy: .public), sleep disabled \(PowerReader.sleepDisabled().map { "\($0)" } ?? "unknown", privacy: .public)"
                    )
                    Task { await self.connection?.sendGoodbye(reason) }
                }
            })
        observers.append(
            ws.addObserver(forName: NSWorkspace.willPowerOffNotification, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    Diagnostics.power.notice("The Mac is shutting down or restarting")
                    Task { await self.connection?.sendGoodbye(.systemShutdown) }
                }
            })
        observers.append(
            ws.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    Diagnostics.power.notice("Woke from sleep")
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
        if satisfied != lastPathSatisfied {
            Diagnostics.connection.notice("Network \(satisfied ? "available" : "unavailable")")
        }
        if satisfied, lastPathSatisfied != nil { await connection?.reconnectNow() }
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
        let source = power.powerSource == .ac ? "power adapter" : "battery"
        let lid = power.lidClosed.map { $0 ? "closed" : "open" } ?? "none"
        let line =
            "Keep-awake \(keepAwake.rawValue) (wanted \(decision.rawValue)); \(source); lid \(lid); thermal \(power.thermal.rawValue); sleep disabled \(PowerReader.sleepDisabled().map { "\($0)" } ?? "unknown")"
        logApprovals()
        if keepAwakeChanges.changed(line) {
            Diagnostics.keepAwake.notice("\(line, privacy: .public); battery \(self.power.batteryPercent)%")
        }
        await connection?.sendState()
    }

    /// The keep-awake line last logged (FR-620).
    private let keepAwakeChanges = Changes<String>()

    func approveHelper() { keepAwakeController.helper.openApprovalSettings() }

    var agentState: AgentState { power.agentState(keepAwake: keepAwake) }

    // MARK: capabilities

    func setLevel(_ id: String, _ level: AccessLevel) {
        capabilities.setLevel(id, level)
        defaults.set(capabilities.levels.mapValues(\.rawValue), forKey: Keys.levels)
        let registry = capabilities
        Task { [connection] in
            await connection?.sendTools()  // FR-062
            // FR-066, spec 004 FR-310: what the new levels no longer allow stops now.
            await LevelChange.stopWork(
                registry, calls: { reason in await connection?.stopCalls(reason) }, shell: ShellCapability.jobs)
        }
        if needsSetup { showSetup() }
    }

    // MARK: pause (FR-602 to FR-604)

    func setPaused(_ on: Bool) {
        paused = on
        Pause.set(on, defaults)
        Self.log.notice("\(on ? "Paused" : "Resumed", privacy: .public) Claude's access")
        guard on else { return }
        Task { [connection] in
            await Pause.stopWork(calls: { reason in await connection?.stopCalls(reason) }, shell: ShellCapability.jobs)
        }
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
        let granted = CGRequestScreenCaptureAccess()
        Diagnostics.permissions.notice("Asked for Screen Recording: \(granted)")
        if !granted { Permissions.openPrivacySettings("Privacy_ScreenCapture") }
        checkScreenPermissions()
    }

    func allowAccessibility() {
        let prompt = "AXTrustedCheckOptionPrompt"  // kAXTrustedCheckOptionPrompt, which Swift 6 rejects as shared state
        let trusted = AXIsProcessTrustedWithOptions([prompt: true] as CFDictionary)
        Diagnostics.permissions.notice("Asked for Accessibility: \(trusted)")
        if !trusted { Permissions.openPrivacySettings("Privacy_Accessibility") }
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
        Diagnostics.permissions.notice(
            "Asked to control \(app, privacy: .public): \(state.map { "\($0)" } ?? "unknown (app not running)", privacy: .public)"
        )
        if let state { setControl(app, state) }
    }

    private func setControl(_ app: String, _ state: Permissions.Automation) {
        appControl[app] = state
        defaults.set(appControl.filter { $0.value == .allowed }.keys.sorted(), forKey: Keys.appControl)
    }

    /// Contacts gives names to numbers in Messages (FR-111). Asked once in setup; after a "Don't
    /// Allow", messages show numbers and setup stops asking.
    private(set) var contactsStatus = CNContactStore.authorizationStatus(for: .contacts)

    /// Messages asks once and gets by without it; the Contacts capability needs it (spec 007 FR-745).
    var needsContacts: Bool {
        (capabilities.level(CapabilityRegistry.messages) != .off && contactsStatus == .notDetermined)
            || (capabilities.level(CapabilityRegistry.contacts) != .off && contactsStatus != .authorized)
    }

    func checkContacts() { contactsStatus = CNContactStore.authorizationStatus(for: .contacts) }

    // MARK: Calendar, Reminders, Location (spec 007 FR-742)

    private(set) var calendarStatus = EventKitBackend.status(.events)
    private(set) var remindersStatus = EventKitBackend.status(.reminders)
    private(set) var locationAccess = AppleMapsBackend.shared.locationAccess()

    var needsCalendar: Bool { capabilities.level(CapabilityRegistry.calendar) != .off && calendarStatus != .fullAccess }
    var needsReminders: Bool {
        capabilities.level(CapabilityRegistry.reminders) != .off && remindersStatus != .fullAccess
    }
    var needsLocation: Bool { capabilities.level(CapabilityRegistry.location) != .off && locationAccess != .allowed }

    func checkPersonalData() {
        calendarStatus = EventKitBackend.status(.events)
        remindersStatus = EventKitBackend.status(.reminders)
        locationAccess = AppleMapsBackend.shared.locationAccess()
    }

    /// macOS asks once; after a refusal, its page in System Settings opens instead.
    func allowEvents(_ kind: EventsKind) async {
        let page = kind == .events ? "Privacy_Calendars" : "Privacy_Reminders"
        let before = EventKitBackend.status(kind)
        Diagnostics.permissions.notice(
            "Asking for \(kind == .events ? "Calendars" : "Reminders", privacy: .public): status \(before.rawValue)")
        if before == .notDetermined {
            NSApp.activate()  // macOS shows the question only for an app in front
            let outcome = await EventKitBackend.requestAccess(kind)
            Diagnostics.permissions.notice(
                "Answer: \(outcome.granted), \(outcome.error ?? "no error", privacy: .public), status \(EventKitBackend.status(kind).rawValue)"
            )
            // No question appeared or it was refused: System Settings is the only way left.
            if !outcome.granted { Permissions.openPrivacySettings(page) }
        } else {
            Permissions.openPrivacySettings(page)
        }
        checkPersonalData()
    }

    func allowLocation() {
        Diagnostics.permissions.notice(
            "Asking for Location: \(String(describing: self.locationAccess), privacy: .public)")
        switch locationAccess {
        case .notAsked: LocationFixer.shared.requestAccess()
        case .servicesOff, .denied: Permissions.openPrivacySettings("Privacy_LocationServices")
        case .allowed: break
        }
        checkPersonalData()
    }

    func allowContacts() async {
        do {
            let granted = try await CNContactStore().requestAccess(for: .contacts)
            Diagnostics.permissions.notice("Asked for Contacts: \(granted)")
        } catch {
            Diagnostics.permissions.error("Asked for Contacts: \(error.localizedDescription, privacy: .public)")
        }
        checkContacts()
    }

    /// Every macOS approval and its state, for the Permissions tab (FR-606).
    var approvals: [Approval] {
        Approval.list(
            ApprovalFacts(
                helper: helperStatus == .enabled, fullDiskAccess: fullDiskAccess,
                notes: control(of: Permissions.notesApp), messages: control(of: Permissions.messagesApp),
                safari: control(of: Permissions.safariApp), contacts: contactsStatus,
                calendars: calendarStatus == .fullAccess, reminders: remindersStatus == .fullAccess,
                location: locationAccess,
                safariJavaScript: safariJavaScript, screenRecording: screenRecording, accessibility: accessibility,
                level: { [capabilities] in capabilities.level($0) }))
    }

    /// Re-reads every approval, to notice what the Owner changes in System Settings.
    func checkApprovals() async {
        await checkHelperApproval()
        checkFullDiskAccess()
        await checkAppControl()
        checkContacts()
        checkPersonalData()
        checkScreenPermissions()
        logApprovals()
    }

    private let approvalChanges = Changes<String>()

    /// One line with every approval's state, whenever one changes (FR-620).
    func logApprovals() {
        let line = approvals.map { "\($0.id) \(String(describing: $0.state))" }.joined(separator: ", ")
        if approvalChanges.changed(line) { Diagnostics.permissions.notice("Approvals: \(line, privacy: .public)") }
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
    /// this Mac to their account. One link at a time: links that arrive while one is being looked
    /// up, confirmed, or exchanged are dropped (FR-054a), so links can't pile up dialogs or
    /// requests. A link naming an unencrypted relay on this Mac is "incomplete" outside
    /// development builds (FR-054b).
    func open(_ url: URL) {
        guard let link = PairingFlow.parse(url), let relay = link.relay else {
            lastError = "That connection link is incomplete. Choose Connect to a Relay… again."
            return
        }
        if pairing.isOwn(link.code) { return }  // the sign-in window already delivered it
        Task {
            let handled = await links.run { await self.confirmAndPair(relay: relay, code: link.code) }
            if !handled { Self.log.notice("A pairing link arrived while another was being handled: ignored") }
        }
    }

    private func confirmAndPair(relay: URL, code: String) async {
        do {
            let email = try? await PairingFlow.preview(relay: relay, code: code)
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
            Self.log.notice("Pairing link confirmed for \(relay.absoluteString, privacy: .private(mask: .hash))")
            pairing.cancelPending()  // the sign-in window's pairing, if one is open, gives way
            let identity = try await PairingFlow.exchange(
                relay: relay, code: code, macName: Host.current().localizedName ?? "Mac")
            relayURL = relay
            connect(identity)
        } catch {
            lastError = error.localizedDescription
            showSetup()
        }
    }

    /// The hosted relay, offered by default in setup; self-hosters type their own.
    /// From the build setting LATCHKEY_DEFAULT_RELAY_HOST (set in the gitignored Local.xcconfig);
    /// empty in a build without one, so no relay address lives in the repository.
    static let hostedRelay: String = {
        let host = Bundle.main.object(forInfoDictionaryKey: "LatchkeyDefaultRelayHost") as? String ?? ""
        return host.isEmpty ? "" : "https://\(host)"
    }()

    /// Disconnect This Mac asks first: only pairing again undoes it (FR-605).
    func confirmDisconnect() {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Disconnect this Mac?"
        alert.informativeText =
            "Claude will no longer be able to reach this Mac. To use it again, you’ll need to connect it to your account again."
        let disconnect = alert.addButton(withTitle: "Disconnect")
        disconnect.hasDestructiveAction = true
        disconnect.keyEquivalent = ""  // Return must not disconnect; Escape cancels
        alert.addButton(withTitle: "Cancel")
        NSApp.activate()
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        Task { await self.disconnect() }
    }

    /// Disconnect This Mac: the relay revokes it (goodbye user_disconnected) and the key is deleted.
    func disconnect() async {
        await connection?.stop(goodbye: .userDisconnected, state: agentState)
        connection = nil
        finishRemovals(access.disconnected())
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
            notice: { [weak self] n in await self?.show(n) },
            clients: { [weak self] list in await self?.clientsChanged(list) })
        let c = RelayConnection(identity: identity, hooks: hooks)
        connection = c
        Task { await c.start() }
    }

    private func connectionChanged(_ s: ConnectionStatus) {
        status = s
        // The list is shown only while connected: after a drop it may have changed elsewhere.
        if s != .connected { finishRemovals(access.disconnected()) }
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
        let wasPaused = paused
        let result = wasPaused ? Pause.refused : await registry.call(tool: call.tool, arguments: call.arguments)
        // A call the Owner stopped by pausing or lowering the level is logged with what Claude was told.
        let told =
            !wasPaused && paused
            ? .text(Pause.stopped, isError: true)
            : LevelChange.recorded(result, tool: call.tool, before: registry, now: capabilities)
        let entry = Activity(
            at: started, tool: call.tool, arguments: call.arguments.jsonText,
            result: told.content.jsonText, isError: told.isError,
            durationMS: Int(Date().timeIntervalSince(started) * 1000))
        try? trace?.record(entry)
        loadRecentActivity()
        if let activity = result.activity, !result.isError { Notifier.post(activity) }  // FR-130
        return result
    }

    // MARK: Claude apps with access (FR-190 to FR-192)

    /// The list from the relay and the removals in flight; the rules are in `ClientAccess`.
    private(set) var access = ClientAccess()

    private func clientsChanged(_ list: [ClientEntry]) {
        finishRemovals(access.received(list, now: Date()))
    }

    /// Remove Access…: asks first, because it can't be undone from the Mac (FR-191).
    func confirmRemoval(of entry: ClientEntry) {
        let ask = RemovalConfirmation(entry)
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = ask.title
        alert.informativeText = ask.message
        let remove = alert.addButton(withTitle: RemovalConfirmation.confirm)
        remove.hasDestructiveAction = true
        remove.keyEquivalent = ""  // Return must not remove; Escape cancels
        alert.addButton(withTitle: RemovalConfirmation.cancel)
        NSApp.activate()
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        removeAccess(entry.id)
    }

    /// Sends one revoke_client and waits for the relay's new list; without one in time, or when
    /// the connection drops, the entry is restored and the Owner is told (FR-191).
    private func removeAccess(_ id: String) {
        guard let revoke = access.beginRemoval(id, now: Date()) else { return }
        Task { [connection] in
            guard await connection?.revokeClient(revoke) == true else {
                finishRemovals(access.notSent(id))
                return
            }
            try? await Task.sleep(for: .seconds(ClientAccess.removalTimeout))
            finishRemovals(access.expire(now: Date()))
        }
    }

    /// Writes each ended removal to the activity log, and says so when one didn't happen. No
    /// notification for a removal that worked: the Owner just clicked it.
    private func finishRemovals(_ outcomes: [RemovalOutcome]) {
        guard !outcomes.isEmpty else { return }
        for outcome in outcomes { try? trace?.record(outcome.activity(at: Date())) }
        loadRecentActivity()
        let failures = outcomes.compactMap { outcome -> String? in
            if case .failed(let entry, let why) = outcome { return why.message(for: entry) }
            return nil
        }
        guard !failures.isEmpty, !uninstalling else { return }
        Task {  // not inside the caller: a modal alert must not hold up the connection's callback
            let alert = NSAlert()
            alert.messageText = "Access wasn’t removed"
            alert.informativeText = failures.joined(separator: "\n")
            NSApp.activate()
            alert.runModal()
        }
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

    /// The menu's first line: whether Claude can reach this Mac (FR-070, FR-602).
    var statusLine: String {
        paused && status == .connected ? "Paused: Claude can’t use this Mac" : status.title()
    }
    var statusAdvice: String? { status.advice }

    /// Why keep-awake is off when the Owner didn't turn it off; nil otherwise (FR-070). Waiting
    /// for approval is the setup line's job.
    var keepAwakeProblem: String? {
        switch keepAwake {
        case .on, .offUser, .offHelperUnavailable: nil
        case .offLowBattery: "Allowing sleep: battery at 15% or less"
        case .offTooHot: "Allowing sleep: Mac is too hot"
        }
    }

    var isPaired: Bool { status.isPaired }

    var icon: MenuIcon { MenuIcon(status: status, paused: paused, needsSetup: needsSetup, busy: busy > 0) }
}
