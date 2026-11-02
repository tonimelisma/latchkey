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
                Diagnostics.activity.notice("Show All Activity chosen")
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
            if let client = entry.client { Text(verbatim: "From \(client)") }  // FR-637; text from the network
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
    /// Where Claude's Safari pages open (spec 005 FR-412); takes effect at the next page.
    @AppStorage(BrowserPlace.key) private var browserPlace: BrowserPlace = .tab

    var body: some View {
        Form {
            Section {
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
            Section("Browser") {
                Picker(selection: $browserPlace) {
                    Text("A Tab in Your Safari Window").tag(BrowserPlace.tab)
                    Text("A Window of Its Own").tag(BrowserPlace.window)
                } label: {
                    Text("Claude Opens Pages In")
                    Text("A tab opens behind the one you’re using, so you can keep working.")
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
                case .checking:
                    Text("Checking…").foregroundStyle(.secondary)
                }
                if a.state != .allowed && a.state != .checking { actions(a.id) }
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
        case "notifications": Button("Allow…") { Task { await model.allowNotifications() } }
        case "localNetwork": Button("Allow…") { Task { await model.allowLocalNetwork() } }
        case "screenAccess": Button("Allow…") { Task { await model.confirmScreenAccess() } }
        case "notes": control(Permissions.notesApp)
        case "messages": control(Permissions.messagesApp)
        case "mail": control(Permissions.mailApp)
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
    @State private var name = ""

    var body: some View {
        Form {
            LabeledContent("Status", value: model.statusLine)
            if model.isPaired {
                if let relay = model.relayURL {
                    LabeledContent("Relay") { Text(verbatim: relay.host() ?? relay.absoluteString) }
                }
                // Spec 010 FR-1002: the name Claude knows this Mac by among the account's machines.
                Section {
                    TextField(
                        "Name shown to Claude", text: $name,
                        prompt: Text(verbatim: Host.current().localizedName ?? "Mac")
                    )
                    .onSubmit { model.setMachineName(name) }
                } footer: {
                    if let shown = model.shownName, shown != model.nameForClaude {
                        Text(
                            verbatim:
                                "Claude knows this Mac as “\(shown)”: another machine on the account has that name.")
                    } else {
                        Text("Claude uses it to tell this Mac from your other machines. Press Return to save.")
                    }
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
        .onAppear { name = model.machineName }
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
            if AddToClaude.step(entries: model.access.entries) == .missing {
                AddToClaudeSteps(model: model, showsDone: false).padding([.horizontal, .top], 8)
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

/// Add Latchkey to Claude (FR-627, FR-628): the button, what to click in Claude, and the way by
/// hand in case the button doesn't work. In setup's last step and the Claude Apps tab.
struct AddToClaudeSteps: View {
    let model: AppModel
    var showsDone = true
    /// The relay address shown in place of the paired one, for pictures.
    var relayShown: String?
    @State private var copied = false

    var body: some View {
        if let relay = relayShown.flatMap(URL.init(string:)) ?? model.relayURL {
            VStack(alignment: .leading, spacing: 8) {
                Button("Add to Claude") { AddToClaude.open(relay: relay) }
                    .keyboardShortcut(.defaultAction)
                numbered(
                    1,
                    "Claude opens in your browser (sign in to Claude if it asks) with a form titled “Add custom connector”, already filled in. Claude cautions that the details came from a link; that’s expected, since the link came from Latchkey."
                )
                numbered(
                    2,
                    "Check that the address is \(AddToClaude.connector(relay: relay)), then click Add. Claude shows the settings it found: change nothing, click Add once more, then Connect.")
                numbered(
                    3,
                    "A Latchkey page opens: sign in with your Latchkey passkey (the one you made when you created your account), then click Allow. That lets Claude use this Mac and your other machines."
                )
                if showsDone {
                    Text("This step gets a checkmark when Claude is connected. Claude on your phone then has it too.")
                        .font(.footnote).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                DisclosureGroup("If Add to Claude doesn’t work") {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(
                            "On claude.ai, click Customize in the column on the left, then Connectors, then Add custom connector. For the name, type Latchkey. For the address, click Copy Address and paste it. Then click Add and go on as in the steps above."
                        )
                        .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                        HStack {
                            Text(verbatim: AddToClaude.connector(relay: relay)).textSelection(.enabled)
                                .font(.callout.monospaced())
                            Button("Copy Address") {
                                AddToClaude.copy(relay: relay)
                                copied = true
                            }
                            .controlSize(.small)
                            if copied { Label("Copied", systemImage: "checkmark").foregroundStyle(.secondary) }
                        }
                    }
                    .padding(.top, 4)
                }
                .font(.callout)
            }
        } else {
            Text("Connect to your account first.").foregroundStyle(.secondary)
        }
    }

    private func numbered(_ n: Int, _ text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text(verbatim: "\(n).").foregroundStyle(.secondary).monospacedDigit()
            Text(text).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// The setup window shown at first launch and whenever a step is missing (FR-078).
struct SetupView: View {
    @Bindable var model: AppModel
    var close: () -> Void
    @State private var relay = ""
    @State private var working = false
    @State private var opened: String?
    @State private var copiedRequest = false
    /// A step shown open whatever its state, for the size test.
    var showing: String?
    /// The relay address shown in place of the default, for pictures (the default is private).
    var relayShown: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Set Up Latchkey").font(.title.bold())
                Text("Five steps, then Claude can reach this Mac from anywhere, even while you’re away.")
                    .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            step("connect", "Connect to your account") {
                Text(
                    "Enter your relay’s address. Your browser opens so you can sign in or create an account with a passkey."
                )
                .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                HStack {
                    TextField("Relay address", text: $relay, prompt: Text("https://relay.example.com"))
                        .textFieldStyle(.roundedBorder)
                        .onSubmit(connect)
                    Button("Connect", action: connect)
                        .keyboardShortcut(.defaultAction)
                        .disabled(relay.trimmingCharacters(in: .whitespaces).isEmpty || working)
                }
                if let error = model.lastError {
                    Text(error).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
                }
                // Spec 009 FR-903: Claude Code sets up a relay by following the guide.
                Text(
                    "Don’t have a relay? Claude Code can set one up for you on a free server. Copy this request and paste it into Claude Code, in Claude Desktop’s Code tab."
                )
                .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                HStack {
                    Button("Copy Request") {
                        SetupRequest.copy()
                        copiedRequest = true
                    }
                    if copiedRequest {
                        Label("Copied", systemImage: "checkmark").foregroundStyle(.secondary)
                    }
                }
            }
            step("questions", "Answer macOS’s questions") {
                Text(
                    "macOS asks before Latchkey can use each part of your Mac. Latchkey asks them all now, one after another, so nothing waits for you later. Click Allow in each."
                )
                .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                checklist(questionRows, columns: 2)
                HStack {
                    Button("Ask Now") { Task { await model.allowAll() } }
                        .keyboardShortcut(.defaultAction)
                        .disabled(model.allowingAll)
                    if model.allowingAll {
                        ProgressView().controlSize(.small)
                        Text("Asking…").foregroundStyle(.secondary)
                    }
                }
            }
            step("switches", "Turn on Latchkey in System Settings") {
                Text(
                    "Only you can turn these on. Latchkey opens each page in turn; turn on Latchkey there, and the next page opens."
                )
                .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                checklist(switchRows, columns: 1)
                Button("Open System Settings") { model.openSwitches() }
                    .keyboardShortcut(.defaultAction)
            }
            step("safari", "Turn on Safari’s setting for Latchkey") {
                Text(
                    "In Safari, choose Safari → Settings. Under Advanced, turn on “Show features for web developers”. Then under Developer, turn on “Allow JavaScript from Apple Events”, and click Check."
                )
                .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                if model.safariJavaScript == false {
                    Text("Safari’s setting isn’t on yet.").foregroundStyle(.red)
                }
                HStack {
                    Button("Open Safari") { Permissions.open(app: Permissions.safariApp) }
                    Button("Check") { Task { await model.checkSafariJavaScript() } }
                        .keyboardShortcut(.defaultAction)
                }
            }
            step("claude", "Add Latchkey to Claude") {
                AddToClaudeSteps(model: model, relayShown: relayShown)
            }
            Divider()
            HStack {
                Text(
                    "Latchkey lives in the menu bar (the key icon), which shows an exclamation mark until setup is finished. To uninstall, move the app to the Trash."
                )
                .font(.footnote).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                Spacer()
                Button(model.needsSetup ? "Finish Later" : "Done", action: close)
                    .keyboardShortcut(model.needsSetup ? .cancelAction : .defaultAction)
            }
        }
        .padding(24)
        .frame(width: 500)
        .onAppear { relay = relayShown ?? model.relayURL?.absoluteString ?? AppModel.hostedRelay }
        .task {
            while !Task.isCancelled {  // notice the approvals in System Settings
                await model.checkApprovals()
                try? await Task.sleep(for: .seconds(1))
            }
        }
    }

    private static let steps = ["connect", "questions", "switches", "safari", "claude"]

    /// One line of a step's checklist: done, or what to do about it.
    private struct Row: Identifiable {
        let id: String
        let title: String
        let done: Bool
        /// Shown when macOS was answered "Don't Allow": only System Settings can change it now.
        var fix: (() -> Void)?
    }

    private var questionRows: [Row] {
        let control: (String, String) -> Row = { app, name in
            Row(
                id: app, title: name, done: model.control(of: app) == .allowed,
                fix: model.control(of: app) == .denied ? { Permissions.openAutomationSettings() } : nil)
        }
        return [
            Row(
                id: "notifications", title: "Notifications", done: model.notifications == .allowed,
                fix: model.notifications == .denied ? { Permissions.openNotificationSettings() } : nil),
            Row(
                id: "contacts", title: "Contacts", done: model.contactsStatus == .authorized,
                fix: model.contactsStatus != .notDetermined
                    ? { Permissions.openContactsSettings() } : nil),
            Row(
                id: "calendars", title: "Calendars", done: model.calendarStatus == .fullAccess,
                fix: model.calendarStatus == .notDetermined ? nil : { Task { await model.allowEvents(.events) } }),
            Row(
                id: "reminders", title: "Reminders", done: model.remindersStatus == .fullAccess,
                fix: model.remindersStatus == .notDetermined ? nil : { Task { await model.allowEvents(.reminders) } }),
            Row(
                id: "location",
                title: model.locationAccess == .servicesOff ? "Location (Location Services off)" : "Location",
                done: model.locationAccess == .allowed,
                fix: [.denied, .servicesOff].contains(model.locationAccess) ? { model.allowLocation() } : nil),
            Row(
                id: "localNetwork", title: "Local network", done: model.localNetwork == true,
                fix: model.localNetwork == false ? { Task { await model.allowLocalNetwork() } } : nil),
            control(Permissions.notesApp, "Notes"),
            control(Permissions.messagesApp, "Messages"),
            control(Permissions.mailApp, "Mail"),
            control(Permissions.safariApp, "Safari"),
        ]
    }

    private var switchRows: [Row] {
        [
            Row(id: "keepAwake", title: "Allow in the Background (keeps this Mac awake)", done: model.isOn(.keepAwake)),
            Row(id: "disk", title: "Full Disk Access", done: model.isOn(.disk)),
            Row(id: "screen", title: "Screen & System Audio Recording", done: model.isOn(.screen)),
            Row(id: "accessibility", title: "Accessibility", done: model.isOn(.accessibility)),
        ]
    }

    /// Short lines in columns, each ticked when done; a refused one offers System Settings.
    private func checklist(_ rows: [Row], columns: Int) -> some View {
        LazyVGrid(
            columns: Array(repeating: GridItem(.flexible(), alignment: .leading), count: columns), alignment: .leading,
            spacing: 4
        ) {
            ForEach(rows) { row in
                HStack(spacing: 6) {
                    Image(systemName: row.done ? "checkmark.circle.fill" : "circle")
                        .foregroundStyle(row.done ? .green : .secondary)
                        .accessibilityLabel(row.done ? "Allowed" : "Not allowed yet")
                    Text(row.title).foregroundStyle(row.done ? .secondary : .primary)
                    if let fix = row.fix {
                        Button("Open…", action: fix).controlSize(.small)
                            .accessibilityLabel(Text("Open System Settings for \(row.title)"))
                    }
                }
            }
        }
    }

    private func isDone(_ key: String) -> Bool {
        switch key {
        case "connect": model.isPaired
        case "questions": model.questionsAnswered
        case "switches": model.switchesOn
        case "safari": model.safariJavaScript == true
        case "claude": AddToClaude.step(entries: model.access.entries) == .done
        default: false
        }
    }

    /// The step shown in full: the one the Owner opened, else the first one not done. The others
    /// are one line each. Nothing after connecting opens before the Mac is paired.
    private var current: String? {
        if let showing { return showing }
        if let opened, Self.steps.contains(opened), !isDone(opened), model.isPaired || opened == "connect" {
            return opened
        }
        return Self.steps.first { !isDone($0) }
    }

    @ViewBuilder
    private func step<Content: View>(_ key: String, _ title: String, @ViewBuilder content: () -> Content) -> some View {
        let n = (Self.steps.firstIndex(of: key) ?? 0) + 1
        let done = isDone(key)
        let open = key == current
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: done ? "checkmark.circle.fill" : "\(n).circle")
                .font(.title2)
                .foregroundStyle(done ? .green : open ? .primary : .secondary)
                .accessibilityLabel(done ? "Done" : "Step \(n)")
            VStack(alignment: .leading, spacing: 8) {
                if done || open || !model.isPaired {
                    Text(title).font(.headline).foregroundStyle(done || open ? .primary : .secondary)
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
        "location": "Location", "maps": "Maps", "mail": "Mail",
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
    /// Only the start of the text is looked at, so a screenshot's megabyte of base64 costs nothing.
    static func clip(_ s: String, _ limit: Int = 80) -> String {
        let scalars = s.unicodeScalars
        let head = scalars.prefix(limit * 4)
        let cut = head.endIndex != scalars.endIndex
        let line = String(String.UnicodeScalarView(head)).replacingOccurrences(of: "\n", with: " ")
        return line.count > limit || cut ? String(line.prefix(limit - 1)) + "…" : line
    }
}
