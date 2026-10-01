import SwiftUI
import VoryCore

/// Settings › Plugins: what is installed on the gateway, Vory's own companion first.
struct PluginsView: View {
    @Environment(AppModel.self) private var model
    @State private var hub: PluginsHub?
    @State private var error: String?
    @State private var loading = false

    private var runtime: GatewayRuntime? { model.runtime }
    private var companion: PluginsHub.Plugin? { hub?.plugins.first { $0.name == "vory-push" } }
    private var others: [PluginsHub.Plugin] { (hub?.plugins ?? []).filter { $0.name != "vory-push" && $0.userHidden != true }.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending } }

    var body: some View {
        List {
            SettingsHeaderSection(title: "Plugins", symbol: "puzzlepiece.extension.fill", color: .orange,
                                  description: "Everything the gateway loads beside the agent itself: Vory's companion, the plugins you installed, and the ones Hermes ships with.")
            Section {
                if let c = companion {
                    PluginRow(plugin: c, highlight: true)
                    let bundled = PushSetupModel.bundledPluginVersion
                    if let v = c.version, v != bundled {
                        Label("This build carries companion \(bundled); Settings › Notifications updates it.", systemImage: "arrow.down.circle")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                } else if hub != nil {
                    Label("Vory's companion is not on this gateway. Settings › Notifications installs it.", systemImage: "bell.slash")
                        .font(.footnote).foregroundStyle(.secondary)
                }
            } header: { Text("Vory") }
            Section {
                if loading, hub == nil { ProgressView() }
                if let error { Text(error).font(.footnote).foregroundStyle(.red) }
                ForEach(others) { p in PluginRow(plugin: p, highlight: false) }
                if hub != nil, others.isEmpty { Text("No other plugins.").foregroundStyle(.secondary) }
            } header: { Text("On the gateway") } footer: {
                Text("Enabling, disabling and installing happen on the gateway (hermes plugins …) or its dashboard; the list here follows.")
            }
        }
        .navigationTitle("").navigationBarTitleDisplayMode(.inline)
        .refreshable { await load() }
        .task(id: runtime?.connection.id) { await load() }
    }

    private func load() async {
        guard let rt = runtime else { return }
        loading = true; defer { loading = false }
        do {
            hub = try await rt.api.get("/api/dashboard/plugins/hub", profile: rt.selectedProfile)
            error = nil
        } catch {
            if let e = error as? HermesAPIError, case .http(let code, _) = e, code == 404 { self.error = "This gateway has no plugins hub yet (it needs a newer Hermes)." }
            else { self.error = error.localizedDescription }
        }
    }
}

struct PluginRow: View {
    var plugin: PluginsHub.Plugin
    var highlight: Bool

    private var status: (text: String, color: Color) {
        switch plugin.runtimeStatus ?? "" {
        case "enabled": return ("Enabled", .green)
        case "disabled": return ("Disabled", .secondary)
        case "bundled": return ("Bundled", .blue)
        default: return (plugin.removedReason == nil ? "Unknown" : "Removed", .orange)
        }
    }

    var body: some View {
        NavigationLink { PluginDetailView(plugin: plugin) } label: {
            HStack(spacing: 12) {
                Image(systemName: highlight ? "bell.badge.fill" : plugin.hasDashboardManifest == true ? "rectangle.on.rectangle" : "puzzlepiece.extension")
                    .foregroundStyle(highlight ? Color.vory : .secondary).frame(width: 24)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(plugin.name).font(.body.weight(highlight ? .semibold : .regular))
                        if let v = plugin.version, !v.isEmpty { Text(v).font(.caption).foregroundStyle(.secondary) }
                    }
                    if let d = plugin.description, !d.isEmpty { Text(d).font(.caption).foregroundStyle(.secondary).lineLimit(2) }
                }
                Spacer()
                Text(status.text).font(.caption2.weight(.semibold)).foregroundStyle(status.color)
                    .padding(.horizontal, 7).padding(.vertical, 3)
                    .background(status.color.opacity(0.12), in: Capsule())
            }
        }
    }
}

struct PluginDetailView: View {
    var plugin: PluginsHub.Plugin

    var body: some View {
        List {
            Section {
                LabeledContent("Name", value: plugin.name)
                if let v = plugin.version, !v.isEmpty { LabeledContent("Version", value: v) }
                LabeledContent("Status", value: (plugin.runtimeStatus ?? "").isEmpty ? "unknown" : plugin.runtimeStatus!)
                if let s = plugin.source, !s.isEmpty { LabeledContent("Source", value: s) }
                if let p = plugin.path, !p.isEmpty { LabeledContent("Path") { Text(p).font(.caption.monospaced()).textSelection(.enabled).multilineTextAlignment(.trailing) } }
            }
            if let d = plugin.description, !d.isEmpty { Section("About") { Text(d) } }
            Section("Can") {
                Label(plugin.hasDashboardManifest == true ? "Adds a page to the dashboard" : "Agent-side only", systemImage: plugin.hasDashboardManifest == true ? "rectangle.on.rectangle" : "cpu")
                if plugin.canUpdateGit == true { Label("Updates from its git checkout", systemImage: "arrow.triangle.branch") }
                if plugin.authRequired == true {
                    Label("Needs a sign-in on the gateway", systemImage: "person.badge.key")
                    if let c = plugin.authCommand, !c.isEmpty { Text(c).font(.caption.monospaced()).textSelection(.enabled) }
                }
            }
            if let r = plugin.removedReason, !r.isEmpty { Section("Removed") { Text(r).foregroundStyle(.orange) } }
        }
        .navigationTitle(plugin.name).navigationBarTitleDisplayMode(.inline)
    }
}
