import EventKit
import SwiftUI

/// The menu bar menu: what the Owner checks or flips often (spec 001 FR-070, FR-601, FR-602).
struct MenuContent: View {
    @Bindable var model: AppModel
    @Environment(\.openWindow) private var openWindow
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        Text(model.statusLine)
        if let advice = model.statusAdvice { Text(advice) }
        if !model.isPaired {
            Button("Connect to a Relay…") { model.showSetup() }
        } else if model.needsSetup {
            Button("Finish Setting Up…") { model.showSetup() }
        }
        if let problem = model.keepAwakeProblem { Text(problem) }
        if let error = model.lastError { Text(error) }
        Divider()
        Toggle("Keep Mac Awake", isOn: $model.keepAwakeEnabled)
        Button(model.paused ? "Resume Claude’s Access" : "Pause Claude’s Access") { model.setPaused(!model.paused) }
        Section("Recent Activity") {  // a section brings its own separators
            if model.activityLog.problem != nil {
                Text("Activity Log Unavailable")
            } else if model.recentActivity.isEmpty {
                Text("Nothing yet")
            }
            ForEach(ActivityFormat.menuItems(model.recentActivity)) { ActivityItem(entry: $0) }
            Button("Show All Activity…") {
                openWindow(id: "activity")
                NSApp.activate()
            }
        }
        Button("Settings…") {
            // A menu-bar-only app opens no Settings window until it is a regular, active app;
            // WindowPresence returns it to the menu bar when the window closes.
            NSApp.setActivationPolicy(.regular)
            NSApp.activate()
            openSettings()
        }
        .keyboardShortcut(",")
        if model.updates.available {
            Button("Check for Updates…") { model.updates.checkForUpdates() }
        }
        Divider()
        Button("Quit Latchkey") { NSApp.terminate(nil) }
            .keyboardShortcut("q")
    }
}

/// One activity in the menu; it expands to the request and the result (spec 002 FR-131).
struct ActivityItem: View {
    let entry: Activity

    var body: some View {
        Menu(ActivityFormat.title(entry)) {
            Text("Asked: \(ActivityFormat.clip(entry.arguments))")
            Text("\(entry.isError ? "Failed" : "Result"): \(ActivityFormat.clip(entry.result))")
            Text("Took \(entry.durationMS) ms")
        }
    }
}

/// The menu bar icon: the key's shape says whether Claude can reach this Mac, and at most one
/// small mark beside it says paused, setup unfinished, or working (FR-600). Shape, never color.
struct MenuIcon: Equatable {
    let symbol: String
    let mark: String?
    let spoken: String

    init(status: ConnectionStatus, paused: Bool, needsSetup: Bool, busy: Bool) {
        let reachable = status == .connected
        symbol = reachable ? "key.fill" : "key.slash"
        let base = reachable ? "Claude can reach this Mac" : "Claude can’t reach this Mac"
        if paused {
            mark = "pause.fill"
            spoken = "Latchkey: paused"
        } else if needsSetup {
            mark = "exclamationmark"
            spoken = "Latchkey: \(base), setup unfinished"
        } else if busy && reachable {
            mark = "circle.fill"
            spoken = "Latchkey: \(base), working"
        } else {
            mark = nil
            spoken = "Latchkey: \(base)"
        }
    }
}

/// The Settings window: what the Owner changes rarely (FR-601). Changes apply at once.
struct SettingsView: View {
    @Bindable var model: AppModel

    var body: some View {
        TabView {
            Tab("What Claude Can Do", systemImage: "checklist") { CapabilitiesPane(model: model) }
            Tab("Permissions", systemImage: "lock.shield") { PermissionsPane(model: model) }
            Tab("Claude Apps", systemImage: "person.2") { AccessView(model: model) }
            Tab("Connection", systemImage: "network") { ConnectionPane(model: model) }
            Tab("General", systemImage: "gearshape") { GeneralPane(model: model) }
        }
        .frame(width: 560)
    }
}

struct CapabilitiesPane: View {
    let model: AppModel

    var body: some View {
        Form {
            ForEach(model.capabilities.capabilities) { cap in
                Picker(
                    selection: Binding(
                        get: { model.capabilities.level(cap.id) },
                        set: { model.setLevel(cap.id, $0) })
                ) {
                    ForEach(cap.levels, id: \.self) { Text(cap.title(for: $0)).tag($0) }
                } label: {
                    Text(cap.title)
                    Text(cap.summary)
                }
            }
        }
        .formStyle(.grouped)
    }
}

/// Every macOS approval Latchkey uses, with its state and a way to change it (FR-606).
struct PermissionsPane: View {
    let model: AppModel

    var body: some View {
        Form {
            Section {
                ForEach(model.approvals) { row($0) }
            } footer: {
                Text(
                    "macOS keeps these in System Settings → Privacy & Security. Changes there show here within a second."
                )
                .font(.footnote).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .task {
            while !Task.isCancelled {
                await model.checkApprovals()
                try? await Task.sleep(for: .seconds(1))
            }
        }
    }

    private func row(_ a: Approval) -> some View {
        LabeledContent {
            HStack {
                switch a.state {
                case .allowed:
                    Label("Allowed", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                case .missing:
                    Label("Not Allowed", systemImage: "exclamationmark.circle").foregroundStyle(.orange)
                case .notNeeded:
                    Text("Not Needed").foregroundStyle(.secondary)
                case .optional:
                    Text("Off").foregroundStyle(.secondary)
                }
                if a.state != .allowed { actions(a.id) }
            }
            .labelStyle(.titleAndIcon)
        } label: {
            Text(a.title)
            Text(a.purpose)
        }
    }

    /// The same actions as the setup window's steps.
    @ViewBuilder private func actions(_ id: String) -> some View {
        switch id {
        case "helper": Button("Allow…") { model.approveHelper() }
        case "disk": Button("Allow…") { Permissions.openFullDiskAccessSettings() }
        case "notes": control(Permissions.notesApp)
        case "messages": control(Permissions.messagesApp)
        case "safari": control(Permissions.safariApp)
        case "contacts":
            if model.contactsStatus == .notDetermined {
                Button("Allow…") { Task { await model.allowContacts() } }
            } else {
                Button("Allow…") { Permissions.openContactsSettings() }
            }
        case "calendars": Button("Allow…") { Task { await model.allowEvents(.events) } }
        case "reminders": Button("Allow…") { Task { await model.allowEvents(.reminders) } }
        case "location": Button("Allow…") { model.allowLocation() }
        case "safariJS":
            Button("Check") { Task { await model.checkSafariJavaScript() } }
        case "screen": Button("Allow…") { model.allowScreenRecording() }
        case "accessibility": Button("Allow…") { model.allowAccessibility() }
        default: EmptyView()
        }
    }

    @ViewBuilder private func control(_ app: String) -> some View {
        if model.control(of: app) == .denied {
            Button("Allow…") { Permissions.openAutomationSettings() }
        } else {
            Button("Allow…") { Task { await model.allowControl(of: app) } }
        }
    }
}

struct ConnectionPane: View {
    let model: AppModel

    var body: some View {
        Form {
            LabeledContent("Status", value: model.statusLine)
            if model.isPaired {
                if let relay = model.relayURL {
                    LabeledContent("Relay") { Text(verbatim: relay.host() ?? relay.absoluteString) }
                }
                LabeledContent("This Mac") {
                    Button("Disconnect This Mac") { model.confirmDisconnect() }
                }
            } else {
                LabeledContent("Relay") {
                    Button("Connect to a Relay…") { model.showSetup() }
                }
            }
        }
        .formStyle(.grouped)
    }
}

struct GeneralPane: View {
    let model: AppModel

    var body: some View {
        Form {
            Toggle("Start at Login", isOn: Binding(get: { model.startsAtLogin }, set: { model.setStartsAtLogin($0) }))
            LabeledContent("Version", value: AppModel.version)
            if model.updates.available {
                LabeledContent("Updates") {
                    Button("Check for Updates…") { model.updates.checkForUpdates() }
                }
            }
        }
        .formStyle(.grouped)
    }
}

/// The Claude apps with access, in the Settings window (FR-190, FR-601).
struct AccessView: View {
    let model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let entries = model.access.entries, model.status == .connected {
                if entries.isEmpty {
                    Text("No Claude app has access").foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    List(entries) { entry in row(entry) }
                }
            } else {
                Text("The list appears when this Mac is connected.").foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            if let failure = model.access.failure {
                Text(verbatim: failure).foregroundStyle(.red).padding([.horizontal, .top], 8)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Text(
                "Each entry is one approval you gave on Latchkey’s Allow page. Claude on the web, desktop, and phone share one entry; each sign-in from a program such as Claude Code has its own."
            )
            .font(.footnote).foregroundStyle(.secondary).padding(8)
            .fixedSize(horizontal: false, vertical: true)
        }
        .frame(minWidth: 520, minHeight: 320)
    }

    private func row(_ entry: ClientEntry) -> some View {
        let removing = model.access.isRemoving(entry.id)
        return HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: entry.title).font(.headline).lineLimit(1)
                Text(verbatim: entry.scopeLine.map { "\(entry.originLine). \($0)." } ?? entry.originLine)
                    .foregroundStyle(.secondary).lineLimit(1)
                Text(verbatim: "\(entry.approvedLine()) · \(entry.lastUsedLine(now: Date()))")
                    .foregroundStyle(.secondary).lineLimit(1)
            }
            .accessibilityElement(children: .combine)
            Spacer()
            if removing {
                ProgressView().controlSize(.small).accessibilityHidden(true)
                Text("Removing…").foregroundStyle(.secondary)
            } else {
                Button("Remove…") { model.confirmRemoval(of: entry) }
                    .accessibilityLabel(Text(verbatim: "Remove access for \(entry.title)"))
            }
        }
        .padding(.vertical, 4)
    }
}

/// The setup window shown at first launch and whenever a step is missing (FR-078).
struct SetupView: View {
    @Bindable var model: AppModel
    var close: () -> Void
    @State private var relay = ""
    @State private var working = false
    @State private var opened: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Set Up Latchkey").font(.title.bold())
                Text("A few steps, then Claude can reach this Mac from anywhere.").foregroundStyle(.secondary)
            }
            step("helper", "Let Latchkey keep this Mac awake") {
                Text(
                    "So Claude can reach your Mac with the lid closed. In System Settings, turn on Latchkey under Allow in the Background."
                )
                .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                Button("Open System Settings") { model.approveHelper() }
            }
            step("connect", "Connect to your account") {
                Text(
                    "Enter your relay's address. Your browser opens so you can sign in or create an account with a passkey."
                )
                .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                HStack {
                    TextField("Relay address", text: $relay, prompt: Text("https://relay.example.com"))
                        .textFieldStyle(.roundedBorder)
                        .onSubmit(connect)
                    Button("Connect", action: connect)
                        .disabled(relay.trimmingCharacters(in: .whitespaces).isEmpty || working)
                }
                if let error = model.lastError {
                    Text(error).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
                }
            }
            if model.capabilities.anyOn {
                step("disk", "Let Latchkey read your files, notes, and messages") {
                    Text(
                        "macOS needs you to switch this on yourself. In System Settings, turn on Latchkey under Full Disk Access."
                    )
                    .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    Button("Open System Settings") { Permissions.openFullDiskAccessSettings() }
                }
            }
            if level(CapabilityRegistry.notes) == .readWrite {
                controlStep(
                    "notes", "Let Latchkey change your notes", app: Permissions.notesApp, appName: "Notes",
                    purpose: "So Claude can create, edit, and delete notes.")
            }
            if model.capabilities.level(CapabilityRegistry.messages) == .readWrite {
                controlStep(
                    "messages", "Let Latchkey send messages", app: Permissions.messagesApp, appName: "Messages",
                    purpose: "So Claude can send messages for you.")
            }
            if level(CapabilityRegistry.contacts) != .off {
                step("contacts", "Let Claude see your contacts") {
                    if model.contactsStatus == .notDetermined {
                        Text(
                            "So Claude can look up, add, and change contacts, and show names in messages. When macOS asks about Contacts, click Allow."
                        )
                        .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                        Button("Continue") { Task { await model.allowContacts() } }
                    } else {
                        Text("In System Settings, turn on Latchkey under Contacts.")
                            .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                        Button("Open System Settings") { Permissions.openContactsSettings() }
                    }
                }
            } else if model.capabilities.level(CapabilityRegistry.messages) != .off {
                step("contacts", "Show names in Messages") {
                    if model.contactsStatus == .notDetermined {
                        Text(
                            "So Claude sees who wrote each message, not just phone numbers. When macOS asks about Contacts, click Allow."
                        )
                        .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                        Button("Continue") { Task { await model.allowContacts() } }
                    } else {
                        Text(
                            "Optional. Messages show phone numbers and email addresses. To show names, turn on Latchkey under Contacts in System Settings."
                        )
                        .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                        Button("Open System Settings") { Permissions.openContactsSettings() }
                    }
                }
            }
            if level(CapabilityRegistry.calendar) != .off {
                eventsStep(
                    "calendars", "Let Claude see your calendars", status: model.calendarStatus, kind: .events,
                    purpose: "So Claude can tell you what's coming up, find free time, and add or change events.",
                    pane: "Calendars")
            }
            if level(CapabilityRegistry.reminders) != .off {
                eventsStep(
                    "reminders", "Let Claude see your reminders", status: model.remindersStatus, kind: .reminders,
                    purpose: "So Claude can list, add, and complete reminders.", pane: "Reminders")
            }
            if level(CapabilityRegistry.location) != .off {
                step("location", "Let Claude see where this Mac is") {
                    switch model.locationAccess {
                    case .servicesOff:
                        Text(
                            "Location Services are off on this Mac. In System Settings, turn on Location Services, then turn on Latchkey in the list."
                        )
                        .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                        Button("Open System Settings") { model.allowLocation() }
                    case .denied:
                        Text("In System Settings, turn on Latchkey under Location Services.")
                            .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                        Button("Open System Settings") { model.allowLocation() }
                    default:
                        Text(
                            "So Claude can tell you where this Mac is and find places nearby. When macOS asks about your location, click Allow."
                        )
                        .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                        Button("Continue") { model.allowLocation() }
                    }
                }
            }
            if level(CapabilityRegistry.browser) != .off {
                controlStep(
                    "safari", "Let Latchkey use Safari", app: Permissions.safariApp, appName: "Safari",
                    purpose: "So Claude can open and read web pages, signed in as you.")
                step("safariJS", "Turn on Safari's setting for Latchkey") {
                    Text(
                        "In Safari, choose Safari → Settings. Under Advanced, turn on “Show features for web developers”. Then under Developer, turn on “Allow JavaScript from Apple Events”. Then click Check."
                    )
                    .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    if model.safariJavaScript == false {
                        Text("Safari's setting isn't on yet.").foregroundStyle(.red)
                    }
                    HStack {
                        Button("Open Safari") { Permissions.open(app: Permissions.safariApp) }
                        Button("Check") { Task { await model.checkSafariJavaScript() } }
                    }
                }
            }
            if level(CapabilityRegistry.computer) != .off {
                step("screen", "Let Claude see the screen") {
                    Text(
                        "For computer control, while the Mac is unlocked. In System Settings, turn on Latchkey under Screen & System Audio Recording."
                    )
                    .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    Button("Continue") { model.allowScreenRecording() }
                }
                step("accessibility", "Let Claude use the mouse and keyboard") {
                    Text("In System Settings, turn on Latchkey under Accessibility.")
                        .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    Button("Continue") { model.allowAccessibility() }
                }
            }
            HStack {
                Text("Latchkey lives in the menu bar. To uninstall, move it to the Trash.")
                    .font(.footnote).foregroundStyle(.secondary)
                Spacer()
                Button(model.needsSetup ? "Later" : "Done", action: close)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(width: 480)
        .onAppear { relay = model.relayURL?.absoluteString ?? AppModel.hostedRelay }
        .task {
            while !Task.isCancelled {  // notice the approvals in System Settings
                await model.checkApprovals()
                try? await Task.sleep(for: .seconds(1))
            }
        }
    }

    private func level(_ id: String) -> AccessLevel { model.capabilities.level(id) }

    /// The setup steps showing now, so they're numbered without gaps.
    private var visibleSteps: [String] {
        var steps = ["helper", "connect"]
        if model.capabilities.anyOn { steps.append("disk") }
        if level(CapabilityRegistry.notes) == .readWrite { steps.append("notes") }
        if level(CapabilityRegistry.messages) == .readWrite { steps.append("messages") }
        if level(CapabilityRegistry.messages) != .off || level(CapabilityRegistry.contacts) != .off {
            steps.append("contacts")
        }
        if level(CapabilityRegistry.calendar) != .off { steps.append("calendars") }
        if level(CapabilityRegistry.reminders) != .off { steps.append("reminders") }
        if level(CapabilityRegistry.location) != .off { steps.append("location") }
        if level(CapabilityRegistry.browser) != .off { steps += ["safari", "safariJS"] }
        if level(CapabilityRegistry.computer) != .off { steps += ["screen", "accessibility"] }
        return steps
    }

    private func n(_ step: String) -> Int { (visibleSteps.firstIndex(of: step) ?? 0) + 1 }

    /// Calendars or Reminders: macOS asks once, then only System Settings can change it.
    private func eventsStep(
        _ key: String, _ title: String, status: EKAuthorizationStatus, kind: EventsKind, purpose: String, pane: String
    ) -> some View {
        step(key, title) {
            if status == .notDetermined {
                Text("\(purpose) When macOS asks about \(pane), click Allow.")
                    .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                Button("Continue") { Task { await model.allowEvents(kind) } }
            } else {
                Text("In System Settings, open \(pane) and set Latchkey to Full Access.")
                    .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                Button("Open System Settings") { Task { await model.allowEvents(kind) } }
            }
        }
    }

    private func controlStep(_ key: String, _ title: String, app: String, appName: String, purpose: String) -> some View
    {
        step(key, title) {
            if model.control(of: app) == .denied {
                Text(
                    "Latchkey isn't allowed to control \(appName). In System Settings, open Automation and turn on \(appName) under Latchkey."
                )
                .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                Button("Open System Settings") { Permissions.openAutomationSettings() }
            } else {
                Text("\(purpose) When macOS asks whether Latchkey may control \(appName), click Allow.")
                    .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                Button("Continue") { Task { await model.allowControl(of: app) } }
            }
        }
    }

    private func isDone(_ key: String) -> Bool {
        switch key {
        case "helper": model.helperStatus == .enabled
        case "connect": model.isPaired
        case "disk": model.fullDiskAccess
        case "notes": model.control(of: Permissions.notesApp) == .allowed
        case "messages": model.control(of: Permissions.messagesApp) == .allowed
        case "contacts": model.contactsStatus == .authorized
        case "calendars": model.calendarStatus == .fullAccess
        case "reminders": model.remindersStatus == .fullAccess
        case "location": model.locationAccess == .allowed
        case "safari": model.control(of: Permissions.safariApp) == .allowed
        case "safariJS": model.safariJavaScript == true
        case "screen": model.screenRecording
        case "accessibility": model.accessibility
        default: false
        }
    }

    /// The step shown in full: the one the Owner opened, else the first one not done. The others
    /// are one line each, so the window fits any screen.
    private var current: String? {
        if let opened, visibleSteps.contains(opened), !isDone(opened) { return opened }
        return visibleSteps.first { !isDone($0) }
    }

    @ViewBuilder
    private func step<Content: View>(_ key: String, _ title: String, @ViewBuilder content: () -> Content) -> some View {
        let n = n(key)
        let done = isDone(key)
        let open = key == current
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: done ? "checkmark.circle.fill" : "\(n).circle")
                .font(.title2)
                .foregroundStyle(done ? .green : open ? .primary : .secondary)
                .accessibilityLabel(done ? "Done" : "Step \(n)")
            VStack(alignment: .leading, spacing: 8) {
                if done || open {
                    Text(title).font(.headline)
                } else {
                    Button {
                        opened = key
                    } label: {
                        Text(title).font(.headline).foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .accessibilityHint("Shows this step")
                }
                if open { content() }
            }
        }
    }

    private func connect() {
        working = true
        Task {
            await model.pair(relayText: relay)
            working = false
        }
    }
}

/// Hosts SetupView in an ordinary window (the app has no Dock icon).
@MainActor
final class SetupWindow {
    private var window: NSWindow?

    func show(model: AppModel) {
        if window == nil {
            let w = NSWindow(
                contentRect: .zero, styleMask: [.titled, .closable], backing: .buffered, defer: false)
            w.title = "Latchkey"
            w.isReleasedWhenClosed = false
            w.contentViewController = NSHostingController(rootView: SetupView(model: model) { [weak w] in w?.close() })
            w.center()
            window = w
        }
        NSApp.setActivationPolicy(.regular)  // in the Dock and Cmd-Tab while open (FR-079)
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate()
    }
}

/// How an activity appears in the menu.
enum ActivityFormat {
    /// "time  Capability: target": what was acted on, not just the tool (spec 002 FR-131).
    static func title(_ e: Activity) -> String {
        let time = e.at.formatted(date: .omitted, time: .shortened)
        return "\(time)  \(action(e))\(e.isError ? " (failed)" : "")"
    }

    static let capabilityNames = [
        "shell": "Shell", "files": "Files", "notes": "Notes", "messages": "Messages", "browser": "Browser",
        "computer": "Computer", "calendar": "Calendar", "reminders": "Reminders", "contacts": "Contacts",
        "location": "Location", "maps": "Maps",
    ]
    /// The argument that names what was acted on, first found wins.
    static let targetKeys = [
        "command", "path", "url", "query", "to", "title", "given_name", "organization", "address", "app", "action",
    ]

    private static func action(_ e: Activity) -> String {
        let parts = e.tool.split(separator: "_", maxSplits: 1).map(String.init)
        guard parts.count == 2, let capability = capabilityNames[parts[0]] else {
            return e.tool.replacingOccurrences(of: "_", with: " ")
        }
        let args = (try? JSONSerialization.jsonObject(with: Data(e.arguments.utf8))) as? [String: Any] ?? [:]
        let target = targetKeys.lazy.compactMap { args[$0] as? String }.first { !$0.isEmpty }
        return "\(capability): \(target.map { clip($0, 40) } ?? parts[1].replacingOccurrences(of: "_", with: " "))"
    }

    /// The newest five, for the menu; the rest are in the Activity window (spec 002 FR-131).
    static func menuItems(_ recent: [Activity]) -> [Activity] { Array(recent.prefix(5)) }

    /// The Activity window's line about stored entries that can't be read (FR-203).
    static func unreadableNote(_ count: Int) -> String? {
        switch count {
        case ..<1: nil
        case 1: "1 older entry can’t be read because its key is no longer in the Keychain."
        default: "\(count) older entries can’t be read because their key is no longer in the Keychain."
        }
    }

    /// One line, at most `limit` characters, for a menu item.
    static func clip(_ s: String, _ limit: Int = 80) -> String {
        let line = s.replacingOccurrences(of: "\n", with: " ")
        return line.count > limit ? String(line.prefix(limit - 1)) + "…" : line
    }
}
