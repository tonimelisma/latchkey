import AppKit
import SwiftUI

/// Settings → Capabilities → WhatsApp: whether Latchkey is linked, and Link or Unlink (plan D3).
struct WhatsAppLinkRow: View {
    @State private var state: WhatsAppPageState = WhatsAppPage.shared.state
    @State private var hasStore = false

    var body: some View {
        LabeledContent {
            if linked {
                Button("Unlink…") { confirmUnlink() }
            } else {
                Button("Link WhatsApp…") { WhatsAppPage.shared.showForLinking() }
            }
        } label: {
            Text(title)
            Text(detail)
        }
        .task {
            WhatsAppPage.shared.onChange = { state = $0 }
            state = WhatsAppPage.shared.state
            hasStore = await WhatsAppPage.hasStore()
        }
        .onChange(of: state) { Task { hasStore = await WhatsAppPage.hasStore() } }
    }

    private var linked: Bool {
        switch state {
        case .connected, .connecting, .changed: true
        case .loading: hasStore
        case .notStarted: hasStore
        case .notLinked: false
        }
    }

    private var title: String {
        switch state {
        case .connected: "Linked"
        case .connecting: "Linked, connecting to WhatsApp…"
        case .loading: hasStore ? "Linked, starting…" : "Not Linked"
        case .notStarted: hasStore ? "Linked" : "Not Linked"
        case .notLinked: "Not Linked"
        case .changed: "Linked, but WhatsApp Web changed"
        }
    }

    private var detail: String {
        switch state {
        case .changed: "Latchkey needs an update before Claude can use WhatsApp again."
        default:
            linked
                ? "Latchkey is one of your phone’s linked devices, so Claude can send even while this Mac is locked."
                : "Link Latchkey as one of your phone’s linked devices so Claude can send WhatsApp messages."
        }
    }

    private func confirmUnlink() {
        let alert = NSAlert()
        alert.messageText = "Unlink WhatsApp?"
        alert.informativeText =
            "Latchkey logs out of WhatsApp and is removed from your phone’s linked devices. Claude can’t send WhatsApp messages until you link it again."
        alert.addButton(withTitle: "Unlink")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        Task {
            await WhatsAppPage.shared.unlink()
            hasStore = await WhatsAppPage.hasStore()
            state = WhatsAppPage.shared.state
        }
    }
}
