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
    /// Clears day-old Messages attachment copies (spec 002 plan D3).
    private var attachmentSweeper: Task<Void, Never>?
    /// Ends Shell leases and closes Claude's idle Safari window, every minute (spec 004 FR-314,
    /// spec 005 FR-411).
    private var leftoverTimer: Task<Void, Never>?
    /// Changes to launch agents, login items, and shell startup files (spec 004 FR-325).
    private var permanentWatch: PermanentWatch?
    /// macOS's monthly screen question, brought on while the Owner is here (FR-624).
    private var screenReminder: Task<Void, Never>?
    /// A permission or setting that goes off while the app runs (FR-626).
    private var permissionWatch: Task<Void, Never>?
    private var losses = PermissionLoss()
    private(set) var relayURL: URL?
    /// The name the Owner chose for this Mac in Settings; empty means the computer's name (spec 010
    /// FR-1002).
    private(set) var machineName = UserDefaults.standard.string(forKey: Keys.machineName) ?? ""
    /// The name the relay kept for this Mac at the last welcome (unique among the account's
    /// machines), nil before the first.
    private(set) var shownName: String?
    private(set) var helperStatus: SMAppService.Status = .notRegistered
    /// What went wrong, as the Owner is shown it; each one is an event too (FR-633).
    var lastError: String? {
        didSet {
            if let lastError, lastError != oldValue {
                EventLog.shared.record(.app, "Shown to the Owner: \(lastError)", error: true)
            }
        }
    }

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
    /// The calls running now, each with a mark on disk until its entry is written, so a quit or
    /// a crash never leaves a call out of the log (FR-666, FR-667).
    let inFlight: CallsInFlight
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
            NotesCapability.make(), MessagesCapability.make(), WhatsAppCapability.make(), MailCapability.make(),
            FilesCapability.make(),
            ShellCapability.make(),
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
        static let localNetwork = LocalNetwork.defaultsKey
        static let screenAccess = "screenAccessConfirmed"
        static let machineName = "machineName"
    }

    /// The name this Mac asks to be shown by to Claude.
    var nameForClaude: String {
        let n = machineName.trimmingCharacters(in: .whitespacesAndNewlines)
        return n.isEmpty ? (Host.current().localizedName ?? "Mac") : n
    }

    /// Changes the name shown to Claude; the connection starts again so the relay hears it at once.
    func setMachineName(_ name: String) {
        let n = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard n != machineName else { return }
        machineName = n
        UserDefaults.standard.set(n, forKey: Keys.machineName)
        event(.pairing, "The name shown to Claude changed to \"\(nameForClaude)\"")
        Task { await connection?.reconnectNow() }
    }

    /// This Mac's device ID, when it is paired with the given relay: pairing again there replaces
    /// it rather than listing the Mac twice (spec 010).
    private func ownDevice(on relay: URL) -> String? {
        guard isPaired, let current = relayURL,
            PairingConfirmation.name(current) == PairingConfirmation.name(relay)
        else { return nil }
        return device
    }

    init() {
        let d = UserDefaults.standard
        keepAwakeEnabled = d.object(forKey: Keys.keepAwake) as? Bool ?? true
        var levels = CapabilityRegistry.defaultLevels  // FR-121
        for (id, raw) in d.dictionary(forKey: Keys.levels) as? [String: String] ?? [:] {
            if let level = AccessLevel(rawValue: raw) { levels[id] = level }
        }
        activityLog = ActivityLog.open()
        inFlight = CallsInFlight(
            marks: activityLog.store.map {
                CallMarks(
                    directory: AppIdentity.current.supportDirectory.appending(
                        path: CallMarks.folderName, directoryHint: .isDirectory),
                    key: $0.reader.key)
            })
        // Latchkey's own log for Claude, whatever the levels (FR-662); from the activity log,
        // or this launch's lines when it can't be opened (FR-665).
        let log = LatchkeyLog.entry(
            source: activityLog.store.map { LatchkeyLog.reading($0.reader) },
            fallback: LatchkeyLog.memory(EventLog.shared), version: Self.version)
        capabilities = CapabilityRegistry(
            capabilities: Self.makeCapabilities(), levels: levels, always: [log])
        // The app's own events go into the same log (FR-633); without one there is nowhere to
        // keep them, and macOS's log still has their lines (FR-620).
        if let store = activityLog.store {
            EventLog.shared.attach { try store.record($0) }
        } else {
            EventLog.shared.discard()
        }
    }

    private func event(_ category: EventCategory, _ text: String, error: Bool = false) {
        EventLog.shared.record(category, text, error: error)
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
        // Core Location reports the permission in a callback just after its manager is made;
        // until then it is unknown (FR-621).
        LocationFixer.shared.onAccessChange = { [weak self] _ in self?.checkPersonalData() }
        watchSystem()
        attachmentSweeper = MessagesCapability.sweepCopies(in: MessagesCapability.staging)
        // Spec 012 FR-1207: what Latchkey's withdrawn WhatsApp device stored goes, once.
        if ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil {
            Task { await WhatsAppOldDevice.removeOnce() }
        }
        leftoverTimer = Self.tidyEveryMinute()
        if ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil {
            Task { await sendQueuedMail() }  // queued before a restart, and the Mac is unlocked now
            screenReminder = remindScreenWhileHere()
            permissionWatch = watchPermissions()
            permanentWatch = PermanentWatch(home: .homeDirectory) { url in
                Task {
                    let jobs = ShellCapability.jobs
                    guard await jobs.unexplained(url) else { return }
                    jobs.setup.report(
                        "\(Leftovers.short(url, home: .homeDirectory)) changed while a command Claude ran was running or kept, and no command declared it",
                        true)
                }
            }
        }
        // The first state the relay hears is the one about to be applied, not the default "off"
        // (each start used to record two needless keep-awake changes, 2026-10-27).
        keepAwake = KeepAwakePolicy.atStart(
            KeepAwakeInputs(
                powerSource: power.powerSource, batteryPercent: power.batteryPercent, thermal: power.thermal,
                userEnabled: keepAwakeEnabled, helperAvailable: keepAwakeController.helperApproved))
        if let identity = DeviceIdentity.load() {
            Self.log.notice(
                "Started \(Self.version, privacy: .public), paired with \(identity.relayURL.absoluteString, privacy: .private(mask: .hash))"
            )
            EventLog.shared.record(
                .app, "Started \(Self.version), paired with \(identity.relayURL.absoluteString)", systemLog: false)
            relayURL = identity.relayURL
            // Paired from this moment, not from the connection's first report a moment later:
            // otherwise the setup check below opens its window on every start (FR-205).
            status = .atStart(paired: true)
            connect(identity)
        } else {
            Self.log.notice(
                "Started \(Self.version, privacy: .public), not paired (\(DeviceIdentity.missing, privacy: .public))")
            EventLog.shared.record(
                .app, "Started \(Self.version), not paired (\(DeviceIdentity.missing))", systemLog: false)
        }
        recordLogProblems()
        recordCallsLeftRunning()
        Task { await refresh() }
        loadRecentActivity()
        decideSetupAtStart()
    }

    /// Calls the app was running when it last stopped without quitting (FR-667), recorded before
    /// the first comparison with the relay's audit.
    private func recordCallsLeftRunning() {
        guard let trace, let marks = inFlight.marks else { return }
        let n = CallsInFlight.recover(marks: marks, logged: { try trace.reader.logged($0) }) {
            try trace.record($0)
        }
        if n > 0 {
            event(
                .activity,
                n == 1
                    ? "Recorded 1 call that was running when Latchkey last stopped without quitting"
                    : "Recorded \(n) calls that were running when Latchkey last stopped without quitting")
        }
    }

    /// What the start found about the activity log's own record (FR-613), as an event.
    private func recordLogProblems() {
        switch trace?.latestState {
        case .missing:
            event(.activity, "The record of the newest activity entry is missing from the Keychain", error: true)
        case .unreadable(let why):
            event(.activity, "The record of the newest activity entry can't be read: \(why)", error: true)
        case .ok, nil: break
        }
    }

    /// An unpaired Mac sees setup at once. A paired one waits until macOS has said what every
    /// permission is (at most 5 seconds), then opens setup only for steps that are certainly not
    /// done, and logs them (FR-621; the window opened over a finished setup on 2026-10-27).
    private func decideSetupAtStart() {
        guard isPaired else {
            event(.setup, "Opening setup: not paired")
            return showSetup()
        }
        Task {
            var waited = 0
            while !SetupDecision.settled(setupSteps) && waited < 20 {
                try? await Task.sleep(for: .milliseconds(250))
                waited += 1
            }
            await checkApprovals()
            _ = losses.update(approvals)  // what is on now; losses are told from here (FR-626)
            let steps = setupSteps
            let missing = SetupDecision.missing(steps)
            let unknown = SetupDecision.unknown(steps)
            if !unknown.isEmpty {
                event(
                    .setup, "Still unknown after 5 s, not counted as missing: \(unknown.joined(separator: ", "))",
                    error: true)
            }
            if missing.isEmpty {
                event(.setup, "Setup is finished")
            } else {
                event(.setup, "Opening setup: missing \(missing.joined(separator: ", "))")
                showSetup()
            }
        }
    }

    /// The setup window: approve keep-awake, connect to a relay (FR-078).
    func showSetup() { setupWindow.show(model: self) }

    var needsSetup: Bool { !missingSetup.isEmpty }

    /// The setup steps certainly not done, by name.
    var missingSetup: [String] { SetupDecision.missing(setupSteps) }

    /// Every setup step and whether it's done, not done, or not known yet (FR-621).
    var setupSteps: [(String, SetupStep)] {
        let known: [(String, Bool)] = [
            ("connect", !isPaired), ("keep-awake", helperStatus != .enabled),
            ("full disk access", !fullDiskAccess), ("app control", needsAppControl),
            ("Safari JavaScript", needsSafariJavaScript), ("screen recording", needsScreenRecording),
            ("accessibility", needsAccessibility), ("contacts", needsContacts), ("calendars", needsCalendar),
            ("reminders", needsReminders), ("screen access", needsScreenAccess),
        ]
        func step(_ allowed: Bool?) -> SetupStep { allowed == nil ? .unknown : allowed == true ? .done : .missing }
        let location = step(locationAccess == .unknown ? nil : locationAccess == .allowed)
        let notified = step(notifications == .unknown ? nil : notifications == .allowed)
        return known.map { ($0.0, $0.1 ? SetupStep.missing : .done) } + [
            ("location", location), ("notifications", notified), ("local network", step(localNetwork)),
            ("Claude", AddToClaude.step(entries: access.entries)),  // FR-627
        ]
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
        event(.app, "The app was moved to the Trash; waiting to see whether it was replaced")
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
        event(.app, "Not replaced: uninstalling")
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
        event(.app, "Uninstalling: removing the local files, the activity log included")
        EventLog.shared.discard()  // nothing more can be kept once the log is gone
        LocalData().remove()
        NSApp.terminate(nil)
    }

    /// Quit: tell the relay, restore sleep (FR-035).
    func shutdown() async {
        if uninstalling { return }
        await connection?.stop(goodbye: .userQuit, state: agentState)
        // Nothing more can be answered: every call still running is recorded as cut off (FR-666).
        if let trace, inFlight.recordQuit(record: { try trace.record($0) }) > 0 { loadRecentActivity() }
        await ShellCapability.jobs.stopAll()  // spec 004 FR-309
        await keepAwakeController.restore()
    }

    /// Sends the email queued while the Mac was locked (spec 008 FR-837), once it is unlocked and
    /// while Mail is Read & write, telling the Owner about each. A message whose try sent nothing
    /// is tried again in five minutes, or at the next unlock (FR-838).
    func sendQueuedMail() async {
        guard mayStillSendQueuedMail, !sendingQueuedMail else { return }
        sendingQueuedMail = true
        defer { sendingQueuedMail = false }
        queuedMailRetry?.cancel()
        // A moment for the unlocked session to settle before Mail opens windows.
        try? await Task.sleep(for: .seconds(3))
        let retry = Locked(false)
        await MailCapability.sendQueued(allowed: { [weak self] in
            await MainActor.run { self?.mayStillSendQueuedMail ?? false }
        }) {
            [weak self] item, outcome in
            let note = Self.queuedMailNote(item, outcome)
            if case .willRetry = outcome { retry.mutate { $0 = true } }
            await MainActor.run {
                // Names the recipients and subject: kept out of macOS's public log and so out
                // of latchkey_log, which Claude reads even with Mail off (security review 2026-11-03).
                EventLog.shared.record(.app, "\(note.title): \(note.body)", error: outcome != .sent, systemLog: false)
                Diagnostics.lifecycle.notice("\(note.title, privacy: .public): \(note.body, privacy: .private)")
            }
            let content = UNMutableNotificationContent()
            content.title = note.title
            content.body = note.body
            try? await UNUserNotificationCenter.current().add(
                UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
        }
        if retry.value {
            queuedMailRetry = Task { [weak self] in
                try? await Task.sleep(for: .seconds(300))
                guard !Task.isCancelled else { return }
                await self?.sendQueuedMail()
            }
        }
    }
    private var sendingQueuedMail = false
    private var queuedMailRetry: Task<Void, Never>?

    /// The Owner's notification about a queued message, in plain sentences (FR-838).
    nonisolated static func queuedMailNote(_ item: MailQueue.Item, _ outcome: MailCapability.QueuedOutcome)
        -> (title: String, body: String)
    {
        switch outcome {
        case .sent:
            return ("Queued email sent", item.summary.prefix(1).uppercased() + item.summary.dropFirst())
        case .willRetry(let why):
            return (
                "Queued email not sent yet",
                "\(item.summary): \(reason(why)) Latchkey tries again in five minutes, or the next time you unlock the Mac."
            )
        case .dropped(let why):
            let gaveUp = (item.failed ?? 0) >= MailQueue.tries ? " after \(MailQueue.tries) tries" : ""
            return (
                "Queued email not sent",
                "\(item.summary): \(reason(why)) It is no longer queued\(gaveUp); Claude can send it again."
            )
        }
    }

    /// "Nothing was sent: Mail didn't open …" becomes "Mail didn't open …", ending with a full stop.
    nonisolated private static func reason(_ why: String) -> String {
        var s = why
        let prefix = "Nothing was sent: "
        if s.hasPrefix(prefix) { s.removeFirst(prefix.count) }
        s = s.prefix(1).uppercased() + s.dropFirst()
        return s.hasSuffix(".") ? s : s + "."
    }

    /// Checked before each queued message (security review 2026-11-02): paired, not paused, Mail
    /// still Read & write, and unlocked. Otherwise the queue waits.
    private var mayStillSendQueuedMail: Bool {
        isPaired && !paused && capabilities.level(CapabilityRegistry.mail) == .readWrite && !SystemScreen().isLocked()
    }

    private func watchSystem() {
        observers.append(
            DistributedNotificationCenter.default().addObserver(
                forName: .init("com.apple.screenIsUnlocked"), object: nil, queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated {
                    // The browser used while locked goes at once, with its copy of Safari's cookies
                    // (spec 005 FR-422; security review 2026-11-02).
                    BrowserCapability.lockedBrowser.discard()
                    Task { await self?.sendQueuedMail() }
                }
            })
        let ws = NSWorkspace.shared.notificationCenter
        observers.append(
            ws.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    let reason = KeepAwakePolicy.sleepReason(self.keepAwake)
                    self.event(
                        .power,
                        "Going to sleep: keep-awake \(self.keepAwake.rawValue), lid \(PowerReader.lidClosed().map { $0 ? "closed" : "open" } ?? "none"), sleep disabled \(PowerReader.sleepDisabled().map { "\($0)" } ?? "unknown")"
                    )
                    Task { await self.connection?.sendGoodbye(reason) }
                }
            })
        observers.append(
            ws.addObserver(forName: NSWorkspace.willPowerOffNotification, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.event(.power, "The Mac is shutting down or restarting")
                    Task { await self.connection?.sendGoodbye(.systemShutdown) }
                }
            })
        observers.append(
            ws.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.event(.power, "Woke from sleep")
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
            event(.connection, "Network \(satisfied ? "available" : "unavailable")")
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
        // A helper that just ended itself after an install is restarted by launchd only after its
        // 10-second wait (seen 2026-10-27), so try again a little later, a few times.
        if decision == .on && !ok && keepAwakeRetries < 5 {
            keepAwakeRetries += 1
            Task {
                try? await Task.sleep(for: .seconds(12))
                await refresh()
            }
        } else if ok {
            keepAwakeRetries = 0
        }
        let source = power.powerSource == .ac ? "power adapter" : "battery"
        let lid = power.lidClosed.map { $0 ? "closed" : "open" } ?? "none"
        let line =
            "Keep-awake \(keepAwake.rawValue) (wanted \(decision.rawValue)); \(source); lid \(lid); thermal \(power.thermal.rawValue); sleep disabled \(PowerReader.sleepDisabled().map { "\($0)" } ?? "unknown")"
        logApprovals()
        if keepAwakeChanges.changed(line) {
            event(.keepAwake, "\(line); battery \(power.batteryPercent)%")
        }
        await connection?.sendState()
    }

    /// The keep-awake line last logged (FR-620).
    private let keepAwakeChanges = Changes<String>()
    /// Retries after keep-awake failed to take effect, since the last success.
    private var keepAwakeRetries = 0

    func approveHelper() { keepAwakeController.helper.openApprovalSettings() }

    var agentState: AgentState { power.agentState(keepAwake: keepAwake) }

    // MARK: capabilities

    func setLevel(_ id: String, _ level: AccessLevel) {
        capabilities.setLevel(id, level)
        if id == CapabilityRegistry.browser { BrowserCapability.lockedBrowser.discard() }
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
        if on { BrowserCapability.lockedBrowser.discard() }
        Pause.set(on, defaults)
        event(.pause, "\(on ? "Paused" : "Resumed") Claude's access")
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

    func control(of app: String) -> Permissions.Automation { appControl[app] ?? .notAsked }

    /// Asked in setup for every scripted app, whatever the levels, so no question waits on an
    /// unattended Mac (FR-140, FR-623).
    func needsControl(of app: String) -> Bool { control(of: app) != .allowed }

    /// Safari's "Allow JavaScript from Apple Events" (spec 005 FR-406): only a test shows it.
    private(set) var safariJavaScript: Bool? =
        UserDefaults.standard.object(forKey: Keys.safariJavaScript) as? Bool == true ? true : nil

    var needsSafariJavaScript: Bool { safariJavaScript != true }

    /// Computer control (spec 006 FR-506): Screen Recording to see, Accessibility to act.
    private(set) var screenRecording = CGPreflightScreenCaptureAccess()
    private(set) var accessibility = AXIsProcessTrusted()

    // Every approval is asked for at first run, whatever the levels (FR-623, Toni 2026-10-31).
    var needsScreenRecording: Bool { !screenRecording }
    /// Computer control, and writing email in Mail's window (spec 008).
    var needsAccessibility: Bool { !accessibility }

    /// macOS's second question, at the first screenshot (direct screen access), answered in setup.
    private(set) var screenAccess = UserDefaults.standard.bool(forKey: Keys.screenAccess)
    var needsScreenAccess: Bool { !(screenRecording && screenAccess) }

    func confirmScreenAccess() async {
        guard screenRecording else { return allowScreenRecording() }
        NSApp.activate()
        let done = await ScreenCapture.confirm()
        event(.permissions, "Took a first screenshot: \(done)")
        screenAccess = done
        defaults.set(done, forKey: Keys.screenAccess)
    }

    /// Every minute: when macOS's monthly "continue to allow" question is due and the Owner is
    /// at the Mac, one throwaway screenshot brings it on now (FR-624, plan D21).
    private func remindScreenWhileHere() -> Task<Void, Never> {
        Task { [weak self] in
            var lastTry: Date?
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(60))
                guard let self, self.screenRecording, let due = ScreenReminder.dueNow(lastTry: lastTry) else {
                    continue
                }
                lastTry = Date()
                let done = await ScreenCapture.confirm()
                self.event(
                    .permissions,
                    "macOS's screen question was due \(due.formatted()); took a screenshot while the Owner is here: \(done)"
                )
            }
        }
    }

    /// Every minute (Local Network every ten, its check takes up to 2 s), and after a call that
    /// failed: what was on and is now off is told to the Owner once, in a notification that
    /// opens setup; the menu bar icon shows its mark meanwhile (FR-626, plan D23).
    private func watchPermissions() -> Task<Void, Never> {
        Task { [weak self] in
            var pass = 0
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(60))
                guard let self else { return }
                pass += 1
                await self.lookForLosses(network: pass % 10 == 0)
            }
        }
    }

    private func lookForLosses(network: Bool = false) async {
        guard permissionWatch != nil else { return }  // not under unit tests
        if network { await checkLocalNetwork(force: true) }
        await checkApprovals()
        let lost = losses.update(approvals)
        guard let notice = PermissionLoss.notice(lost) else { return }
        event(.permissions, "Told the Owner these are off: \(lost.map(\.title).joined(separator: ", "))", error: true)
        let content = UNMutableNotificationContent()
        content.title = notice.title
        content.body = notice.body
        content.categoryIdentifier = PermissionLoss.category
        // Asked in setup, never here (FR-623).
        try? await UNUserNotificationCenter.current().add(
            UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
    }

    func checkScreenPermissions() {
        screenRecording = CGPreflightScreenCaptureAccess()
        accessibility = AXIsProcessTrusted()
    }

    /// Asks macOS to show its prompt the first time; after that, opens System Settings.
    func allowScreenRecording() {
        let granted = CGRequestScreenCaptureAccess()
        event(.permissions, "Asked for Screen Recording: \(granted)")
        if !granted { Permissions.openPrivacySettings("Privacy_ScreenCapture") }
        checkScreenPermissions()
    }

    func allowAccessibility() {
        let prompt = "AXTrustedCheckOptionPrompt"  // kAXTrustedCheckOptionPrompt, which Swift 6 rejects as shared state
        let trusted = AXIsProcessTrustedWithOptions([prompt: true] as CFDictionary)
        event(.permissions, "Asked for Accessibility: \(trusted)")
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

    var needsAppControl: Bool { Permissions.scriptedApps.contains { needsControl(of: $0) } }

    func checkAppControl() async {
        for app in Permissions.scriptedApps {
            let state = await Permissions.automation(of: app, ask: false)
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
        let state = await Permissions.automation(of: app, ask: true)
        event(.permissions, "Asked to control \(app): \(state.map { "\($0)" } ?? "unknown (app not running)")")
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
    var needsContacts: Bool { contactsStatus != .authorized }

    func checkContacts() { contactsStatus = CNContactStore.authorizationStatus(for: .contacts) }

    // MARK: Calendar, Reminders, Location (spec 007 FR-742)

    private(set) var calendarStatus = EventKitBackend.status(.events)
    private(set) var remindersStatus = EventKitBackend.status(.reminders)
    private(set) var locationAccess = AppleMapsBackend.shared.locationAccess()

    var needsCalendar: Bool { calendarStatus != .fullAccess }
    var needsReminders: Bool { remindersStatus != .fullAccess }
    /// Certainly needed: "not known yet" doesn't count (FR-621).
    var needsLocation: Bool { locationAccess != .allowed && locationAccess != .unknown }

    // MARK: Notifications and Local Network (FR-623)

    private(set) var notifications = NotificationAccess.unknown

    func checkNotifications() async {
        let status = await UNUserNotificationCenter.current().notificationSettings().authorizationStatus
        notifications =
            switch status {
            case .authorized, .provisional, .ephemeral: .allowed
            case .denied: .denied
            case .notDetermined: .notAsked
            @unknown default: .denied
            }
    }

    func allowNotifications() async {
        if notifications == .denied { return Permissions.openNotificationSettings() }
        NSApp.activate()
        let granted = (try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]))
        event(.permissions, "Asked for Notifications: \(granted.map { "\($0)" } ?? "no answer")")
        await checkNotifications()
        if notifications == .denied { Permissions.openNotificationSettings() }
    }

    /// Remembered between starts: the check takes up to 2 seconds.
    private(set) var localNetwork: Bool? =
        UserDefaults.standard.object(forKey: Keys.localNetwork) as? Bool == true ? true : nil
    private var localNetworkCheckedAt: ContinuousClock.Instant?

    /// Looks again at most every 10 seconds while it isn't allowed.
    func checkLocalNetwork(force: Bool = false) async {
        if !force, localNetwork == true { return }
        if !force, let at = localNetworkCheckedAt, ContinuousClock.now - at < .seconds(10) { return }
        localNetworkCheckedAt = .now
        setLocalNetwork(await LocalNetwork.check())
    }

    /// Starting the check is what makes macOS ask; waits up to a minute for the answer.
    func allowLocalNetwork() async {
        let before = await LocalNetwork.check()
        if before { return setLocalNetwork(true) }
        NSApp.activate()
        let allowed = await LocalNetwork.check(wait: .seconds(60))
        event(.permissions, "Asked for Local Network: \(allowed)")
        setLocalNetwork(allowed)
        if !allowed { Permissions.openPrivacySettings("Privacy_LocalNetwork") }
    }

    private func setLocalNetwork(_ allowed: Bool) {
        localNetwork = allowed
        defaults.set(allowed, forKey: Keys.localNetwork)
    }

    // MARK: Allow All (FR-623)

    private(set) var allowingAll = false

    /// Every question macOS asks with its own dialog, one after another, each waiting for its
    /// answer; then System Settings for the first approval only it can give. Run at first
    /// pairing and from setup's Allow All, so nothing is asked later on an unattended Mac.
    func allowAll() async {
        guard !allowingAll else { return }
        allowingAll = true
        defer { allowingAll = false }
        event(.permissions, "Allow All: started")
        await checkApprovals()
        if notifications == .notAsked { await allowNotifications() }
        if contactsStatus == .notDetermined { await allowContacts() }
        if calendarStatus == .notDetermined { await allowEvents(.events) }
        if remindersStatus == .notDetermined { await allowEvents(.reminders) }
        if locationAccess == .notAsked {
            allowLocation()
            for _ in 0..<600 where AppleMapsBackend.shared.locationAccess() == .notAsked {
                try? await Task.sleep(for: .milliseconds(100))
            }
            checkPersonalData()
        }
        for app in Permissions.scriptedApps where control(of: app) == .notAsked { await allowControl(of: app) }
        if localNetwork != true { await allowLocalNetwork() }
        await checkApprovals()
        event(.permissions, "Allow All: questions done, missing \(missingSetup.joined(separator: ", "))")
        openSwitches()
    }

    /// The questions macOS asks in its own dialog, for setup's checklist: all allowed means the
    /// step is done. A refused one shows its own way to System Settings.
    var questionsAnswered: Bool {
        notifications == .allowed && contactsStatus == .authorized && calendarStatus == .fullAccess
            && remindersStatus == .fullAccess && locationAccess == .allowed && localNetwork == true
            && Permissions.scriptedApps.allSatisfy { control(of: $0) == .allowed }
    }

    /// The switches only the Owner can turn on, in System Settings, in the order setup opens them.
    enum Switch: CaseIterable { case keepAwake, disk, screen, accessibility }

    func isOn(_ s: Switch) -> Bool {
        switch s {
        case .keepAwake: helperStatus == .enabled
        case .disk: fullDiskAccess
        case .screen: screenRecording && screenAccess
        case .accessibility: accessibility
        }
    }

    func open(_ s: Switch) {
        switch s {
        case .keepAwake: approveHelper()
        case .disk: Permissions.openFullDiskAccessSettings()
        case .screen: if screenRecording { Task { await confirmScreenAccess() } } else { allowScreenRecording() }
        case .accessibility: allowAccessibility()
        }
    }

    var switchesOn: Bool { Switch.allCases.allSatisfy(isOn) }

    /// While true, turning one switch on opens the page of the next (FR-623): one click for all.
    private(set) var openingSwitches = false
    private var openedSwitch: Switch?
    private var screenConfirmed = false

    func openSwitches() {
        openingSwitches = true
        openedSwitch = nil
        screenConfirmed = false
        advanceSwitches()
    }

    /// Called after every look at the approvals.
    private func advanceSwitches() {
        guard openingSwitches else { return }
        guard let next = Switch.allCases.first(where: { !isOn($0) }) else {
            openingSwitches = false
            return
        }
        if next == .screen, screenRecording, !screenConfirmed, openedSwitch == .screen {
            // Just turned on: macOS's second question comes with the first screenshot (once).
            screenConfirmed = true
            Task { await confirmScreenAccess() }
            return
        }
        guard next != openedSwitch else { return }
        openedSwitch = next
        open(next)
    }

    func checkPersonalData() {
        calendarStatus = EventKitBackend.status(.events)
        remindersStatus = EventKitBackend.status(.reminders)
        locationAccess = AppleMapsBackend.shared.locationAccess()
    }

    /// macOS asks once; after a refusal, its page in System Settings opens instead.
    func allowEvents(_ kind: EventsKind) async {
        let page = kind == .events ? "Privacy_Calendars" : "Privacy_Reminders"
        let before = EventKitBackend.status(kind)
        event(.permissions, "Asking for \(kind == .events ? "Calendars" : "Reminders"): status \(before.rawValue)")
        if before == .notDetermined {
            NSApp.activate()  // macOS shows the question only for an app in front
            let outcome = await EventKitBackend.requestAccess(kind)
            event(
                .permissions,
                "Answer: \(outcome.granted), \(outcome.error ?? "no error"), status \(EventKitBackend.status(kind).rawValue)"
            )
            // No question appeared or it was refused: System Settings is the only way left.
            if !outcome.granted { Permissions.openPrivacySettings(page) }
        } else {
            Permissions.openPrivacySettings(page)
        }
        checkPersonalData()
    }

    func allowLocation() {
        event(.permissions, "Asking for Location: \(String(describing: locationAccess))")
        switch locationAccess {
        case .notAsked: LocationFixer.shared.requestAccess()
        case .servicesOff, .denied: Permissions.openPrivacySettings("Privacy_LocationServices")
        case .allowed, .unknown: break
        }
        checkPersonalData()
    }

    func allowContacts() async {
        do {
            let granted = try await CNContactStore().requestAccess(for: .contacts)
            event(.permissions, "Asked for Contacts: \(granted)")
        } catch {
            event(.permissions, "Asked for Contacts: \(error.localizedDescription)", error: true)
        }
        checkContacts()
    }

    /// Every macOS approval and its state, for the Permissions tab (FR-606).
    var approvals: [Approval] {
        Approval.list(
            ApprovalFacts(
                helper: helperStatus == .enabled, fullDiskAccess: fullDiskAccess,
                notes: control(of: Permissions.notesApp), messages: control(of: Permissions.messagesApp),
                mail: control(of: Permissions.mailApp),
                safari: control(of: Permissions.safariApp), contacts: contactsStatus,
                calendars: calendarStatus == .fullAccess, reminders: remindersStatus == .fullAccess,
                location: locationAccess,
                safariJavaScript: safariJavaScript, screenRecording: screenRecording, accessibility: accessibility,
                notifications: notifications, localNetwork: localNetwork, screenAccess: screenAccess))
    }

    /// Re-reads every approval, to notice what the Owner changes in System Settings.
    func checkApprovals() async {
        await checkHelperApproval()
        checkFullDiskAccess()
        await checkAppControl()
        checkContacts()
        checkPersonalData()
        checkScreenPermissions()
        await checkNotifications()
        await checkLocalNetwork()
        logApprovals()
        advanceSwitches()
    }

    private let approvalChanges = Changes<String>()

    /// One line with every approval's state, whenever one changes (FR-620).
    func logApprovals() {
        let line = approvals.map { "\($0.id) \(String(describing: $0.state))" }.joined(separator: ", ")
        if approvalChanges.changed(line) { event(.permissions, "Approvals: \(line)") }
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
            let identity = try await pairing.pair(relay: relay, macName: nameForClaude, replaces: ownDevice(on: relay))
            EventLog.shared.record(
                .pairing, "Paired with \(relay.absoluteString) as \(identity.deviceID)", systemLog: false)
            Self.log.notice("Paired through the sign-in window")
            relayURL = relay
            connect(identity)
            Task { await allowAll() }  // FR-623: every question now, while the Owner is here
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
            if !handled { self.event(.pairing, "A pairing link arrived while another was being handled: ignored") }
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
            EventLog.shared.record(.pairing, "Pairing link confirmed for \(relay.absoluteString)", systemLog: false)
            pairing.cancelPending()  // the sign-in window's pairing, if one is open, gives way
            let identity = try await PairingFlow.exchange(
                relay: relay, code: code, macName: nameForClaude, replaces: ownDevice(on: relay))
            EventLog.shared.record(
                .pairing, "Paired with \(relay.absoluteString) as \(identity.deviceID)", systemLog: false)
            Self.log.notice("Paired through a pairing link")
            relayURL = relay
            connect(identity)
            Task { await allowAll() }  // FR-623: every question now, while the Owner is here
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
        event(.pairing, "Disconnect This Mac: forgetting the pairing")
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
            clients: { [weak self] list in await self?.clientsChanged(list) },
            connected: { [weak self] in await self?.checkAudit() },
            name: { [weak self] in await MainActor.run { self?.nameForClaude } },
            welcomed: { [weak self] name in await MainActor.run { self?.shownName = name } })
        device = identity.deviceID
        let c = RelayConnection(identity: identity, hooks: hooks)
        connection = c
        Task { await c.start() }
    }

    private func connectionChanged(_ s: ConnectionStatus) {
        status = s
        // The list is shown only while connected: after a drop it may have changed elsewhere.
        if s != .connected { finishRemovals(access.disconnected()) }
        if s == .revoked {  // 4002: delete the local key (agent-protocol.md)
            event(.pairing, "The relay revoked this Mac: forgetting the pairing", error: true)
            DeviceIdentity.delete()
            connection = nil
        }
    }

    /// Runs a call and records it in the local trace (FR-026).
    private func handle(_ call: Call) async -> ToolResult {
        if let refused = CallCheck.refusal(callID: call.id) {
            EventLog.shared.record(
                .audit, "Refused a call of \(AuditComparison.clip(call.tool)): its id isn't of the allowed form",
                error: true)
            return refused
        }
        let started = Date()
        busy += 1  // FR-132
        defer { busy -= 1 }
        // Relay-supplied names (tool, call id, Claude app) are bounded before they're kept.
        let tool = AuditComparison.clip(call.tool)
        let client = call.client.flatMap { $0.isEmpty ? nil : AuditComparison.clip($0) }
        inFlight.begin(
            CallMark(
                callID: call.id, at: started, tool: tool, arguments: call.arguments.jsonText, device: device,
                client: client))
        let registry = capabilities
        let wasPaused = paused
        var result = wasPaused ? Pause.refused : await registry.call(tool: call.tool, arguments: call.arguments)
        if let line = await ShellCapability.jobs.statusLine() { result.appendText(line) }  // spec 004 FR-322
        // A call the Owner stopped by pausing or lowering the level is logged with what Claude was told.
        let told =
            !wasPaused && paused
            ? .text(Pause.stopped, isError: true)
            : LevelChange.recorded(result, tool: call.tool, before: registry, now: capabilities)
        // The quit recorded it as cut off already (FR-666): the app is going, nothing more to do.
        guard inFlight.end(call.id) else { return result }
        let entry = Activity(
            at: started, tool: tool, arguments: call.arguments.jsonText,
            result: told.content.jsonText, isError: told.isError,
            durationMS: Int(Date().timeIntervalSince(started) * 1000), callID: call.id,
            device: device, client: client)
        try? trace?.record(entry)
        inFlight.recorded(call.id)
        loadRecentActivity()
        if let activity = result.activity, !result.isError { Notifier.post(activity) }  // FR-130
        if let also = result.alsoDone { Notifier.post(also) }
        if result.isError { Task { await lookForLosses() } }  // a permission may be why (FR-626)
        if let made = result.made, !result.isError {  // FR-641
            let by = entry.client.map { " (\($0))" } ?? ""
            EventLog.shared.record(.leftovers, "Claude made \(made)\(by)", systemLog: false)
        }
        return result
    }

    /// At start, what earlier runs left; then every minute, the leases that ended and Claude's
    /// idle Safari tab or window (spec 004 FR-314, FR-324, spec 005 FR-411).
    private static func tidyEveryMinute() -> Task<Void, Never> {
        Task.detached(priority: .utility) {
            await ShellCapability.jobs.selfCheck()  // spec 004 FR-330
            await ShellCapability.jobs.recoverEarlier()
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(60))
                await ShellCapability.jobs.tidy()
                _ = await BrowserCapability.browser.closeIfIdle()  // notes what it closed
            }
        }
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

    // MARK: the comparison with the relay's audit (FR-634)

    /// The device ID of the pairing in use, stored with each call (FR-632).
    private var device: String?
    /// The last comparison's result, for the Activity window; nil before one finished.
    private(set) var audit: AuditComparison?
    /// The last comparison's event text, or why it couldn't be made.
    private(set) var auditLine: String?
    private(set) var auditing = false

    /// Compares this Mac's log with the relay's audit of this Mac, records the result as an
    /// event (and in macOS's log, where the installer reads it), and keeps it for the window.
    /// Runs after each connection and from the Activity window's button.
    func checkAudit() async {
        guard !auditing else { return }
        auditing = true
        defer { auditing = false }
        guard let trace else {
            return finishAudit(nil, "Audit check not possible: the activity log is unavailable")
        }
        guard let connection, let device else { return finishAudit(nil, AuditFetch.notConnected.problem ?? "") }
        let fetched = await connection.fetchAudit()
        guard case .entries(let relay) = fetched else { return finishAudit(nil, fetched.problem ?? "") }
        let reader = trace.reader
        let now = Date()
        let outcome = await Task.detached { () -> (AuditComparison, String)? in
            guard let mine = try? reader.calls() else { return nil }
            var c = AuditComparison.compare(
                relay: relay, mac: mine.calls, macWithoutIDs: mine.withoutIDs, device: device, now: now)
            // A call missing on the Mac may have been cut off by an older app's quit (FR-668):
            // look for such quits in those calls' times only, and compare again.
            if !c.missingOnMac.isEmpty {
                guard let quits = try? reader.oldQuits(in: c.missingOnMac.map(AuditComparison.quitWindow))
                else { return nil }
                if !quits.isEmpty {
                    c = AuditComparison.compare(
                        relay: relay, mac: mine.calls, macWithoutIDs: mine.withoutIDs, device: device, now: now,
                        oldQuits: quits)
                }
            }
            let tools = (try? reader.tools(of: Set(c.missingOnRelay.map(\.callID)))) ?? [:]
            return (c, c.summary(tools: tools))
        }.value
        guard let outcome else {
            return finishAudit(nil, "Audit check not possible: the activity log couldn't be read")
        }
        finishAudit(outcome.0, outcome.1)
    }

    private func finishAudit(_ comparison: AuditComparison?, _ line: String) {
        audit = comparison
        auditLine = line
        event(.audit, line, error: comparison?.allMatch != true)
    }

    // MARK: activity (FR-131, FR-132)

    /// Calls running now; the menu bar icon shows a dot while above zero.
    private(set) var busy = 0
    private(set) var recentActivity: [Activity] = []

    private var recentLoads = 0

    /// Reads the menu's newest entries off the main thread (after every call, they decrypt up to
    /// a few dozen entries, screenshots included); the newest load wins.
    func loadRecentActivity() {
        guard let reader = trace?.reader else {
            recentActivity = []
            return
        }
        recentLoads += 1
        let load = recentLoads
        Task {
            let entries = await Task.detached { (try? reader.recent(limit: 10)) ?? [] }.value
            if load == recentLoads { recentActivity = entries }
        }
    }

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
        let center = UNUserNotificationCenter.current()  // asked in setup, never here (FR-623)
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

#if DEBUG
    extension AppModel {
        /// A Mac with every approval given and connected, for the README's pictures
        /// (ReadmeShotTests); not in Release builds.
        func showEverythingAllowed() {
            status = .connected
            helperStatus = .enabled
            fullDiskAccess = true
            for app in Permissions.scriptedApps { appControl[app] = .allowed }
            safariJavaScript = true
            screenRecording = true
            accessibility = true
            screenAccess = true
            contactsStatus = .authorized
            calendarStatus = .fullAccess
            remindersStatus = .fullAccess
            locationAccess = .allowed
            notifications = .allowed
            localNetwork = true
        }
    }
#endif
