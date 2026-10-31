import SwiftUI
import VoryCore
import WatchKit

/// A small settings pane: which gateway, how the watch reaches it, and a way to re-pull the
/// credentials from the phone.
struct WatchSettingsView: View {
    @Environment(WatchModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                if let rt = model.runtime {
                    Section("Gateway") {
                        LabeledContent("Name", value: rt.connection.name)
                        LabeledContent("Link", value: model.socketUsable ? "Direct, live" : model.throughPhone ? "Through iPhone" : "Direct")
                        if model.route != .relayOnly { LabeledContent("Status", value: rt.socketState.label) }
                        LabeledContent("Bot", value: model.listProfile == "*" ? "All bots" : (model.listProfile ?? rt.selectedProfile ?? "—"))
                        LabeledContent("Summaries", value: model.summaries.isEmpty ? "off on iPhone" : "\(model.summaries.count) from iPhone")
                    }
                    if model.store.connections.count > 1 {
                        // More than one saved gateway: the watch can move between them itself.
                        Section("Gateways") {
                            ForEach(model.store.connections) { c in
                                Button { Task { await model.activate(c); dismiss() } } label: {
                                    HStack {
                                        Text(c.name).lineLimit(1)
                                        Spacer()
                                        if c.id == rt.connection.id { Image(systemName: "checkmark") }
                                    }
                                }
                            }
                        }
                    }
                    Section {
                        Picker("Connect through", selection: Binding(get: { model.route }, set: { r in Task { await model.setRoute(r) } })) {
                            Text("Automatic").tag(GatewayRoute.automatic)
                            Text("iPhone only").tag(GatewayRoute.relayOnly)
                        }
                    } footer: {
                        Text(model.route == .relayOnly
                             ? "Everything goes through your iPhone, so it needs to be nearby. Use this when the watch's own Wi-Fi cannot reach the gateway."
                             : "The watch uses its own connection while the gateway answers there, and goes through your iPhone when it does not.")
                    }
                    Section {
                        if model.route != .relayOnly {
                            Button { Task { await rt.reconnectNow() } } label: { Label("Reconnect", systemImage: "arrow.clockwise") }
                        }
                    } footer: { Text("Sending and approving go through the iPhone unless the watch has a live connection of its own. Summaries and bot looks come from the iPhone.") }
                } else {
                    Section { Text("Open Vory on the iPhone once; it hands the gateway to the watch.").font(.footnote) }
                }
                Section {
                    LabeledContent("Version", value: (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?") + " (" + (Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "?") + ")")
                }
            }
            .navigationTitle("Settings")
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }
    }
}
