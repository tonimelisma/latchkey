import SwiftUI

struct MenuContent: View {
    @Bindable var model: AppModel
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Text(model.statusLine)
        Text(model.batteryLine)
        Text(model.keepAwakeLine)
        if model.keepAwake == .offHelperUnavailable {
            Button("Finish Setting Up…") { model.showSetup() }
        }
        if let error = model.lastError { Text(error) }
        Divider()
        Toggle("Keep Mac Awake", isOn: $model.keepAwakeEnabled)
        Section("What Claude Can Do") {
            ForEach(model.capabilities.capabilities) { cap in
                Picker(
                    "\(cap.title): \(model.capabilities.level(cap.id).title)",
                    selection: Binding(
                        get: { model.capabilities.level(cap.id) },
                        set: { model.setLevel(cap.id, $0) })
                ) {
                    ForEach(AccessLevel.allCases, id: \.self) { Text($0.title).tag($0) }
                }
            }
        }
        Divider()
        Section("Recent Activity") {
            if model.recentActivity.isEmpty {
                Text("Nothing yet")
            }
            ForEach(model.recentActivity) { entry in
                Menu(ActivityFormat.title(entry)) {
                    Text("Asked: \(ActivityFormat.clip(entry.arguments))")
                    Text("\(entry.isError ? "Failed" : "Result"): \(ActivityFormat.clip(entry.result))")
                    Text("Took \(entry.durationMS) ms")
                }
            }
            Button("Show All Activity…") {
                openWindow(id: "activity")
                NSApp.activate()
            }
        }
        Divider()
        if model.isPaired {
            if let relay = model.relayURL { Text("Relay: \(relay.host() ?? relay.absoluteString)") }
            Button("Disconnect This Mac") { Task { await model.disconnect() } }
        } else {
            Button("Connect to a Relay…") { model.showSetup() }
        }
        Toggle("Start at Login", isOn: Binding(get: { model.startsAtLogin }, set: { model.setStartsAtLogin($0) }))
        if model.updates.available {
            Button("Check for Updates…") { model.updates.checkForUpdates() }
        }
        Divider()
        Button("Quit Latchkey") { NSApp.terminate(nil) }
            .keyboardShortcut("q")
    }
}

/// The setup window shown at first launch and whenever a step is missing (FR-078).
struct SetupView: View {
    @Bindable var model: AppModel
    var close: () -> Void
    @State private var relay = ""
    @State private var working = false

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Set Up Latchkey").font(.title.bold())
                Text("A few steps, then Claude can reach this Mac from anywhere.").foregroundStyle(.secondary)
            }
            step(1, "Let Latchkey keep this Mac awake", done: model.helperStatus == .enabled) {
                Text(
                    "So Claude can reach your Mac with the lid closed. In System Settings, turn on Latchkey under Allow in the Background."
                )
                .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                Button("Open System Settings") { model.approveHelper() }
            }
            step(2, "Connect to your account", done: model.isPaired) {
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
                step(3, "Let Latchkey read Notes and Messages", done: model.fullDiskAccess) {
                    Text(
                        "macOS needs you to switch this on yourself. In System Settings, turn on Latchkey under Full Disk Access."
                    )
                    .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    Button("Open System Settings") { Permissions.openFullDiskAccessSettings() }
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
                await model.checkHelperApproval()
                model.checkFullDiskAccess()
                try? await Task.sleep(for: .seconds(1))
            }
        }
    }

    @ViewBuilder
    private func step<Content: View>(_ n: Int, _ title: String, done: Bool, @ViewBuilder content: () -> Content)
        -> some View
    {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: done ? "checkmark.circle.fill" : "\(n).circle")
                .font(.title2)
                .foregroundStyle(done ? .green : .secondary)
                .accessibilityLabel(done ? "Done" : "Step \(n)")
            VStack(alignment: .leading, spacing: 8) {
                Text(title).font(.headline)
                if !done { content() }
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

struct ActivityView: View {
    let model: AppModel
    @State private var entries: [TraceEntry] = []
    @State private var selection: TraceEntry.ID?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Table(entries, selection: $selection) {
                TableColumn("When") { Text($0.at.formatted(date: .abbreviated, time: .standard)) }
                TableColumn("Tool") { Text($0.tool).monospaced() }
                TableColumn("Result") { Text($0.isError ? "Error" : "OK") }
                TableColumn("Time taken") { Text("\($0.durationMS) ms") }
            }
            if let id = selection, let e = entries.first(where: { $0.id == id }) {
                Divider()
                VStack(alignment: .leading, spacing: 6) {
                    Text("Arguments").font(.headline)
                    Text(e.arguments).monospaced().textSelection(.enabled)
                    Text("Result").font(.headline)
                    Text(e.result).monospaced().textSelection(.enabled)
                }
                .padding(12)
            }
            Text("Every tool Claude ran on this Mac in the last 90 days. This log stays on this Mac.")
                .font(.footnote).foregroundStyle(.secondary).padding(8)
        }
        .frame(minWidth: 560, minHeight: 320)
        .onAppear(perform: load)
    }

    private func load() { entries = (try? model.trace?.recent(limit: 500)) ?? [] }
}

/// How an activity appears in the menu.
enum ActivityFormat {
    static func title(_ e: TraceEntry) -> String {
        let time = e.at.formatted(date: .omitted, time: .shortened)
        let name = e.tool.replacingOccurrences(of: "_", with: " ")
        return "\(time)  \(name)\(e.isError ? " (failed)" : "")"
    }

    /// One line, at most 80 characters, for a menu item.
    static func clip(_ s: String) -> String {
        let line = s.replacingOccurrences(of: "\n", with: " ")
        return line.count > 80 ? String(line.prefix(79)) + "…" : line
    }
}
