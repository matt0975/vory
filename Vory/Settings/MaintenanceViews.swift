import Foundation
import SwiftUI
import VoryCore

/// Shown wherever the dashboard answers 503 "Restart required": the process is serving code
/// older than its checkout on disk and refuses risky imports until it is restarted.
struct RestartRequiredCallout: View {
    @Environment(AppModel.self) private var model
    var message: String

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("Hermes needs a restart", systemImage: "arrow.triangle.2.circlepath").font(.headline)
            Text(message).font(.footnote).foregroundStyle(.secondary)
            if let rt = model.runtime {
                MaintenanceButtons(runtime: rt, compact: true)
            }
        }
        .padding(.vertical, 4)
    }

    static func matches(_ error: String?) -> Bool { MaintenanceModel.isRestartRequired(error) }
}

/// Liquid Glass card pinned above the chat list while the dashboard reports stale code. Same
/// two actions as the System screen, so the fix is one tap from where you notice the problem.
struct RestartRequiredBanner: View {
    var runtime: GatewayRuntime
    var message: String
    @State private var confirmUpdate = false
    @State private var showDetail = false

    var body: some View {
        let m = runtime.maintenance
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "arrow.triangle.2.circlepath.circle.fill").font(.title2).foregroundStyle(.orange)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Hermes needs a restart").font(.subheadline.weight(.semibold))
                    Text("The dashboard is running code older than what is on disk, so the model picker is refused until it relaunches.")
                        .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
            }
            HStack(spacing: 8) {
                Button { confirmUpdate = true } label: { Text(m.isBusy ? "Updating…" : "Update Hermes").font(.subheadline.weight(.semibold)) }
                    .buttonStyle(.glassProminent).disabled(m.isBusy)
                    .accessibilityIdentifier("banner.update")
                Button { showDetail.toggle() } label: { Text(showDetail ? "Hide details" : "Details").font(.subheadline) }
                    .buttonStyle(.glass)
                Spacer(minLength: 0)
                if m.isBusy { ProgressView().controlSize(.small) }
            }
            if showDetail { Text(message).font(.caption2).foregroundStyle(.secondary).textSelection(.enabled) }
            if case .failed(let why) = m.phase { Text(why).font(.caption2).foregroundStyle(.red) }
        }
        .padding(14)
        .glassEffect(.regular, in: .rect(cornerRadius: 18))
        .alert("Update Hermes?", isPresented: $confirmUpdate) {
            Button("Update", role: .destructive) { Task { await m.update(runtime: runtime) } }
            Button("Cancel", role: .cancel) {}
        } message: { Text("Runs `hermes update` on the gateway machine and relaunches the dashboard, which clears this. It can take a few minutes; the app reconnects afterwards.") }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Hermes needs a restart")
    }
}

struct MaintenanceButtons: View {
    var runtime: GatewayRuntime
    var compact = false
    /// Just the restart row, for places that only need the gateway bounced.
    var restartOnly = false
    @State private var confirmRestart = false
    @State private var confirmUpdate = false

    var body: some View {
        let m = runtime.maintenance
        // Plain rows, like every other action in Settings: two prominent glass buttons side by
        // side wrapped their labels and hid the glyph on the tinted one.
        Group {
            if !restartOnly {
                Button { confirmUpdate = true } label: { Label("Update Hermes", systemImage: "arrow.down.circle") }
                    .disabled(m.isBusy || m.check?.canApply == false)
            }
            Button { confirmRestart = true } label: { Label("Restart gateway", systemImage: "arrow.clockwise") }
                .disabled(m.isBusy)
            switch m.phase {
            case .idle: EmptyView()
            case .running(let label): Label { Text(label) } icon: { ProgressView() }.font(.footnote).foregroundStyle(.secondary)
            case .finished(let text, _): Label(text, systemImage: "checkmark.circle").font(.footnote).foregroundStyle(.secondary)
            case .failed(let text): Label(text, systemImage: "xmark.octagon").font(.footnote).foregroundStyle(.red)
            }
            if !compact, !m.actionLog.isEmpty {
                Text(m.actionLog.suffix(12).joined(separator: "\n")).font(.caption2.monospaced()).foregroundStyle(.secondary).textSelection(.enabled)
            }
        }
        .alert("Restart the gateway?", isPresented: $confirmRestart) {
            Button("Restart", role: .destructive) { Task { await m.restartGateway(runtime: runtime) } }
            Button("Cancel", role: .cancel) {}
        } message: { Text("Runs `hermes gateway restart` on the gateway machine. Running turns are interrupted and this app reconnects when it is back.") }
        .alert("Update Hermes?", isPresented: $confirmUpdate) {
            Button("Update", role: .destructive) { Task { await m.update(runtime: runtime) } }
            Button("Cancel", role: .cancel) {}
        } message: { Text("Runs `hermes update` on the gateway machine and relaunches the dashboard, which also clears a \"restart required\" state. This can take a few minutes.") }
    }
}

// MARK: System

struct SystemView: View {
    @Environment(AppModel.self) private var model
    @State private var status: JSONValue?
    @State private var entries: [String] = []
    @State private var logError: String?
    @State private var error: String?
    @State private var doctor: String?
    @State private var showAllLog = false

    private let logPreview = 5

    var body: some View {
        SettingsList {
            SettingsHeaderSection(title: "System", symbol: "server.rack", color: .secondary, description: "Gateway health, logs, restarts and updates.")
            if let s = status {
                Section {
                    LabeledContent("Hermes", value: s["version"]?.stringValue ?? "?")
                    ForEach(StatusLight.lights(from: s, restartRequired: model.runtime?.restartRequired != nil)) { light in
                        NavigationLink { StatusDetailView(light: light) } label: {
                            HStack(spacing: 12) {
                                Circle().fill(light.color).frame(width: 12, height: 12)
                                Text(light.title)
                                Spacer()
                                Text(light.summary).font(.subheadline).foregroundStyle(.secondary)
                            }
                        }
                    }
                } header: { Text("Status") } footer: { Text("Green is fine. \(DeviceWords.Tap) anything red or amber to see what it means and what to do.") }
                if let rt = model.runtime { maintenance(rt) }
                Section {
                    Button("Run doctor") { Task { await runDoctor() } }
                    if let doctor { Text(doctor).font(.caption.monospaced()).textSelection(.enabled) }
                }
                Section {
                    if let logError { Text(logError).foregroundStyle(.red).font(.footnote) }
                    else if entries.isEmpty { Text("No log lines yet.").foregroundStyle(.secondary).font(.footnote) }
                    ForEach(Array(visibleEntries.enumerated()), id: \.offset) { _, e in
                        Text(e).font(.caption2.monospaced()).textSelection(.enabled)
                    }
                    if entries.count > logPreview {
                        Button(showAllLog ? "Show less" : "Show \(entries.count - logPreview) more") {
                            withAnimation { showAllLog.toggle() }
                        }
                    }
                } header: { Text("Recent log (agent) · newest first") }
            } else if let error { Text(error).foregroundStyle(.red) } else { ProgressView() }
        }
        .reloadable { await load() }
        .task { await load() }
    }

    private var visibleEntries: [String] { showAllLog ? entries : Array(entries.prefix(logPreview)) }

    @ViewBuilder private func maintenance(_ rt: GatewayRuntime) -> some View {
        let m = rt.maintenance
        Section {
            if let c = m.check {
                if let v = c.currentVersion, !v.isEmpty { LabeledContent("Installed", value: v) }
                if let im = c.installMethod, !im.isEmpty { LabeledContent("Install method", value: im) }
                if let behind = c.behind {
                    LabeledContent("Upstream", value: behind == 0 ? "up to date" : behind < 0 ? "newer version available" : "\(behind) commit\(behind == 1 ? "" : "s") behind")
                }
                if let msg = c.message, !msg.isEmpty { Text(msg).font(.footnote).foregroundStyle(.secondary) }
                if c.canApply == false, let cmd = c.updateCommand, !cmd.isEmpty {
                    Text("Update from the gateway machine: `\(cmd)`").font(.footnote).foregroundStyle(.secondary)
                }
                if let commits = c.commits, !commits.isEmpty {
                    DisclosureGroup("What's new (\(commits.count))") {
                        ForEach(commits, id: \.self) { c in
                            VStack(alignment: .leading, spacing: 2) {
                                Text(c.summary ?? "").font(.caption)
                                Text([c.sha.map { String($0.prefix(10)) }, c.author].compactMap { $0 }.joined(separator: " · ")).font(.caption2).foregroundStyle(.tertiary)
                            }
                        }
                    }
                }
            } else if let e = m.checkError {
                Text(e).font(.footnote).foregroundStyle(.red)
            }
            Button { Task { await m.checkForUpdate(runtime: rt, force: true) } } label: {
                if m.checking { Label { Text("Checking…") } icon: { ProgressView() } } else { Label("Check for updates", systemImage: "magnifyingglass") }
            }
            .disabled(m.checking)
            MaintenanceButtons(runtime: rt)
        } header: { Text("Maintenance") } footer: {
            Text("Restart runs `hermes gateway restart`; Update runs `hermes update` and relaunches the dashboard. Both happen on the gateway machine, and this app reconnects afterwards.")
        }
    }

    private func load() async {
        guard let rt = model.runtime else { return }
        do {
            status = try await rt.api.get("/api/status", profile: rt.selectedProfile, authenticated: true)
            error = nil
        } catch { self.error = error.localizedDescription; return }
        do {
            let raw: JSONValue = try await rt.api.get("/api/logs", query: [URLQueryItem(name: "file", value: "agent"), URLQueryItem(name: "lines", value: "200")], profile: rt.selectedProfile)
            let lines = raw["lines"]?.arrayValue?.map { $0.displayText }
                ?? (raw["content"]?.stringValue ?? raw["text"]?.stringValue ?? raw.displayText).components(separatedBy: "\n")
            entries = LogEntries.group(lines).reversed()
            logError = nil
        } catch { logError = error.localizedDescription }
        if rt.maintenance.check == nil { await rt.maintenance.checkForUpdate(runtime: rt, force: false) }
    }

    private func runDoctor() async {
        guard let rt = model.runtime else { return }
        do {
            let r: JSONValue = try await rt.api.send("POST", "/api/ops/doctor", profile: rt.selectedProfile, body: EmptyBody())
            doctor = r.displayText
            try? await Task.sleep(for: .seconds(3))
            let st: JSONValue = try await rt.api.get("/api/actions/doctor/status", profile: rt.selectedProfile)
            doctor = st["output"]?.stringValue ?? st["lines"]?.arrayValue?.map { $0.displayText }.joined(separator: "\n") ?? st.displayText
        } catch { doctor = error.localizedDescription }
    }
}

// MARK: Session store details (behind the Advanced cog on the Sessions screen)

struct SessionStoreSheet: View {
    var stats: JSONValue?
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            SettingsList {
                if let s = stats?.objectValue {
                    Section("Store") {
                        ForEach(["total", "active_store", "archived", "messages"], id: \.self) { k in
                            if let v = s[k] { LabeledContent(k.replacingOccurrences(of: "_", with: " ").capitalized, value: v.displayText) }
                        }
                        ForEach(s.keys.sorted().filter { !["total", "active_store", "archived", "messages", "by_source"].contains($0) }, id: \.self) { k in
                            LabeledContent(k.replacingOccurrences(of: "_", with: " ").capitalized, value: s[k]?.displayText ?? "")
                        }
                    }
                    if let by = s["by_source"]?.objectValue, !by.isEmpty {
                        Section("By source") {
                            ForEach(by.keys.sorted(), id: \.self) { k in
                                LabeledContent(k, value: by[k]?.displayText ?? "")
                            }
                        }
                    }
                } else {
                    ContentUnavailableView("No store statistics", systemImage: "internaldrive", description: Text("The gateway did not return /api/sessions/stats."))
                }
            }
            .navigationTitle("Advanced")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }
        .presentationDetents([.medium, .large])
    }
}


/// One traffic light on the System screen: what it is, what it says, and what to do about it.
struct StatusLight: Identifiable {
    enum Level { case ok, warn, bad }
    var id: String
    var title: String
    var summary: String
    var level: Level
    var explanation: String
    var advice: String
    var raw: String

    var color: Color { level == .ok ? .green : level == .warn ? .orange : .red }

    static func lights(from s: JSONValue, restartRequired: Bool) -> [StatusLight] {
        var out: [StatusLight] = []
        let gwState = s["gateway_state"]?.stringValue ?? (s["gateway_running"]?.boolValue == true ? "running" : "stopped")
        let gwOK = ["running", "ready", "ok", "up"].contains(gwState.lowercased())
        out.append(StatusLight(id: "gateway", title: "Gateway", summary: gwState.capitalized, level: gwOK ? .ok : .bad,
                               explanation: "The gateway is the Hermes process that runs your chats and talks to the model. Everything in this app goes through it.",
                               advice: gwOK ? "Nothing to do." : "Use Restart gateway below. If it stays down, check the machine it runs on.", raw: s["gateway"]?.displayText ?? gwState))
        out.append(StatusLight(id: "code", title: "Code", summary: restartRequired ? "Restart needed" : "Current", level: restartRequired ? .warn : .ok,
                               explanation: "Whether the running Hermes matches the code on disk. After an update the old process keeps running until it is relaunched.",
                               advice: restartRequired ? "\(DeviceWords.Tap) Update Hermes below; it relaunches the dashboard." : "Nothing to do.", raw: restartRequired ? "restart required" : "ok"))
        if let m = s["memory"] {
            let p = (m["pressure"]?.stringValue ?? "ok").lowercased()
            out.append(StatusLight(id: "memory", title: "Memory", summary: p.capitalized, level: p == "ok" || p == "normal" ? .ok : (p == "warning" || p == "elevated" ? .warn : .bad),
                                   explanation: "How much memory the gateway machine has left. Under pressure, turns slow down or fail.",
                                   advice: p == "ok" || p == "normal" ? "Nothing to do." : "Close other work on the gateway machine, or restart the gateway.", raw: m.displayText))
        }
        if let d = s["disk"] {
            let p = (d["pressure"]?.stringValue ?? "ok").lowercased(); let free = d["free_mb"]?.intValue ?? 0
            out.append(StatusLight(id: "disk", title: "Disk", summary: free >= 1024 ? "\(free / 1024) GB free" : "\(free) MB free", level: p == "ok" || p == "normal" ? .ok : (p == "warning" ? .warn : .bad),
                                   explanation: "Free space on the gateway machine. Sessions, logs and files all need room.",
                                   advice: p == "ok" || p == "normal" ? "Nothing to do." : "Free up space on the gateway machine.", raw: d.displayText))
        }
        let auth = s["auth_required"]?.boolValue == true
        out.append(StatusLight(id: "auth", title: "Sign-in gate", summary: auth ? "On" : "Off", level: .ok,
                               explanation: auth ? "The dashboard requires a sign-in (the gateway is reachable beyond this machine). This app signed in the way you chose when adding it." : "The dashboard is reachable without a sign-in gate, which is normal for a loopback-only gateway.",
                               advice: "Nothing to do.", raw: auth ? "auth_required: true" : "auth_required: false"))
        out.append(StatusLight(id: "sessions", title: "Active chats", summary: "\(s["active_sessions"]?.intValue ?? 0)", level: .ok,
                               explanation: "How many sessions the gateway currently has live.", advice: "Nothing to do.", raw: "\(s["active_sessions"]?.intValue ?? 0)"))
        return out
    }
}

struct StatusDetailView: View {
    var light: StatusLight
    var body: some View {
        SettingsList {
            Section {
                HStack(spacing: 12) { Circle().fill(light.color).frame(width: 14, height: 14); Text(light.summary).font(.headline) }
            }
            Section("What this is") { Text(light.explanation) }
            Section("What to do") { Text(light.advice) }
            Section("Raw") { Text(light.raw).font(.caption.monospaced()).textSelection(.enabled) }
        }
        .navigationTitle(light.title)
        .navigationBarTitleDisplayMode(.inline)
    }
}
