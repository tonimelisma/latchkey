import SwiftUI

struct MenuContent: View {
    @Bindable var model: AppModel
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Text(model.statusLine)
        Text(model.batteryLine)
        Text(model.keepAwakeLine)
        if model.keepAwake == .offHelperUnavailable {
            Button("Approve Keep-Awake in System Settings…") { model.approveHelper() }
        }
        if let error = model.lastError { Text(error) }
        Divider()
        Toggle("Keep Mac Awake", isOn: $model.keepAwakeEnabled)
        Menu("Tools for Claude") {
            ForEach(CapabilityRegistry.all) { cap in
                Toggle(
                    "\(cap.title) (\(cap.summary.lowercased()))",
                    isOn: Binding(
                        get: { model.capabilities.enabled.contains(cap.id) },
                        set: { model.setCapability(cap.id, enabled: $0) }))
            }
        }
        Divider()
        if model.isPaired {
            if let relay = model.relayURL { Text("Relay: \(relay.host() ?? relay.absoluteString)") }
            Button("Disconnect This Mac") { Task { await model.disconnect() } }
        } else {
            Button("Connect to a Relay…") {
                openWindow(id: "connect")
                NSApp.activate()
            }
        }
        Button("Activity…") {
            openWindow(id: "activity")
            NSApp.activate()
        }
        Toggle("Start at Login", isOn: Binding(get: { model.startsAtLogin }, set: { model.setStartsAtLogin($0) }))
        Divider()
        Button("Quit Latchkey") { NSApp.terminate(nil) }
            .keyboardShortcut("q")
    }
}

struct ConnectView: View {
    @Bindable var model: AppModel
    @State private var relay = ""
    @State private var working = false
    @Environment(\.dismissWindow) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Connect this Mac to your account").font(.title2.bold())
            Text(
                "Enter the address of your Latchkey relay. Your browser opens so you can sign in with your passkey and confirm."
            )
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
            TextField("Relay address", text: $relay, prompt: Text("https://relay.example.com"))
                .textFieldStyle(.roundedBorder)
                .onSubmit(connect)
            if let error = model.lastError {
                Text(error).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                Spacer()
                Button("Cancel") { dismiss(id: "connect") }
                    .keyboardShortcut(.cancelAction)
                Button("Connect", action: connect)
                    .keyboardShortcut(.defaultAction)
                    .disabled(relay.trimmingCharacters(in: .whitespaces).isEmpty || working)
            }
        }
        .padding(20)
        .frame(width: 420)
        .onAppear { relay = model.relayURL?.absoluteString ?? relay }
    }

    private func connect() {
        working = true
        Task {
            await model.pair(relayText: relay)
            working = false
            if model.isPaired { dismiss(id: "connect") }
        }
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
