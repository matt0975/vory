#if os(iOS)
import ActivityKit
#endif
import SwiftUI
import UserNotifications
import VoryCore

/// Whether the system lets Vory show Live Activities; there are none on the Mac.
private var activitiesEnabled: Bool {
    #if os(iOS)
    ActivityAuthorizationInfo().areActivitiesEnabled
    #else
    false
    #endif
}

/// Settings › Status: one page that says, in plain words, whether each part of Vory is working:
/// the gateway, the sign-in, the Companion, notifications, the Live Activity and approval
/// requests. Green is fine, orange needs a look, red is broken. Each row opens the page that
/// fixes it.
struct StatusView: View {
    @Environment(AppModel.self) private var model
    @State private var setup = PushSetupModel()
    @State private var activitiesAllowed = activitiesEnabled

    enum Light { case good, warn, bad, off
        var color: Color { switch self { case .good: .green; case .warn: .orange; case .bad: .red; case .off: .secondary } }
    }

    var body: some View {
        let push = model.push
        SettingsList {
            SettingsHeaderSection(title: "Status", symbol: "waveform.path.ecg", color: .green, description: "Whether each part of Vory is working right now. \(DeviceWords.Tap) a row for the page that fixes it.")
            Section {
                if let rt = model.runtime {
                    let s = rt.socketState
                    row("Gateway", light: s.isOpen ? .good : (isFailed(s) ? .bad : .warn),
                        detail: s.isOpen ? "Connected to \(rt.connection.name)" : gatewayDetail(s, rt)) { GatewaysView() }
                    row("Sign-in", light: signInLight(s), detail: signInDetail(s, rt)) { GatewayFormView(existing: rt.connection) }
                } else {
                    row("Gateway", light: .off, detail: model.activationError ?? "No gateway connected") { GatewaysView() }
                }
            } header: { Text("Connection") }

            Section {
                if model.runtime != nil {
                    row("Companion", light: companionLight, detail: companionDetail) { CompanionView() }
                    row("Approval requests", light: approvalsLight, detail: approvalsDetail) { CompanionView() }
                } else {
                    row("Companion", light: .off, detail: "Connect a gateway first") { CompanionView() }
                }
            } header: { Text("On the gateway") } footer: {
                Text("The Companion is the plugin on your gateway that sends notifications\(DeviceWords.isMac ? " and approval cards" : ", approval cards and the Live Activity") while Vory is closed.")
            }

            Section {
                row("Notifications", light: notificationsLight(push), detail: notificationsDetail(push)) { NotificationsView() }
                #if os(iOS)
                row("Live Activity", light: liveActivityLight(push), detail: liveActivityDetail(push)) { NotificationsView() }
                #endif
            } header: { Text("On \(DeviceWords.this)") }

            Section {
                LabeledContent("Vory", value: "\(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?") (\(Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "?"))")
                LabeledContent("Companion this build ships", value: PushSetupModel.bundledPluginVersion)
                if let v = setup.installedVersion { LabeledContent("Companion on the gateway", value: v) }
            } header: { Text("Versions") }
        }
        .untitledPage()
        .task { if let rt = model.runtime { await setup.checkCompanion(runtime: rt) }; await model.push.refreshAuthorization(); activitiesAllowed = activitiesEnabled }
        .reloadable { if let rt = model.runtime { await setup.checkCompanion(runtime: rt) }; await model.push.refreshAuthorization() }
    }

    private func row<D: View>(_ title: String, light: Light, detail: String, @ViewBuilder destination: () -> D) -> some View {
        NavigationLink { destination().untitledPage() } label: {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Circle().fill(light.color).frame(width: 10, height: 10).padding(.top, 2)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                    Text(detail).font(.footnote).foregroundStyle(.secondary)
                }
            }
        }
        .accessibilityLabel("\(title): \(detail)")
    }

    // MARK: Connection

    private func isFailed(_ s: SocketState) -> Bool {
        if case .failed = s { return true }
        if case .authRejected = s { return true }
        return false
    }
    private func gatewayDetail(_ s: SocketState, _ rt: GatewayRuntime) -> String {
        switch s {
        case .connecting: return "Connecting to \(rt.connection.name)…"
        case .reconnecting(let n, _): return "Lost the connection; trying again (attempt \(n))"
        case .failed(let why): return "Cannot reach \(rt.connection.name): \(why)"
        case .authRejected: return "\(rt.connection.name) refused the sign-in"
        case .idle: return "Not connected yet"
        case .open: return "Connected"
        }
    }
    private func signInLight(_ s: SocketState) -> Light {
        if case .authRejected = s { return .bad }
        return s.isOpen ? .good : .warn
    }
    private func signInDetail(_ s: SocketState, _ rt: GatewayRuntime) -> String {
        if case .authRejected(let why) = s { return why.isEmpty ? "The gateway rejected the session. Sign in again." : why }
        switch rt.connection.authMode {
        case .sessionToken: return "Using the gateway's session token"
        case .password: return "Signed in with a username and password"
        case .oauth: return "Signed in with the browser"
        }
    }

    // MARK: Gateway side

    private var companionLight: Light {
        if setup.companionCheckError != nil { return .warn }
        guard setup.installedVersion != nil else { return .bad }
        if setup.companionHealthy { return .good }
        return .warn
    }
    private var companionDetail: String {
        if let e = setup.companionCheckError { return "Could not check: \(e)" }
        guard let v = setup.installedVersion else { return "Not installed. Settings › Companion installs it in one \(DeviceWords.tap)." }
        if setup.companionHealthy { return "Running, version \(v)" }
        if setup.needsRestart { return "Installed (\(v)) but the gateway has not restarted with it yet" }
        if setup.heartbeat == nil { return "Installed (\(v)) but it has not reported in. Restart the gateway." }
        if setup.runningOlderCode || !setup.installedScriptMatches { return "Running an older version than this build ships. Update it from Settings › Companion." }
        return "Installed (\(v)) but its last report is old. Is the gateway running?"
    }
    private var approvalsLight: Light {
        guard let rt = model.runtime else { return .off }
        if rt.serverRequestsAdvertised.isEmpty { return .warn }
        return .good
    }
    private var approvalsDetail: String {
        guard let rt = model.runtime else { return "" }
        if rt.serverRequestsAdvertised.isEmpty { return "The gateway has not agreed to send approval cards on this connection. Reconnect, or update Hermes on the gateway." }
        return rt.serverRequestsReceived == 0 ? "The gateway will send them; none have come yet on this connection" : "\(rt.serverRequestsReceived) received on this connection"
    }

    // MARK: Phone side

    private func notificationsLight(_ push: PushRegistrar) -> Light {
        if !push.notificationsEnabled { return .off }
        if push.authorization == .denied { return .bad }
        if push.authorization == .notDetermined { return .warn }
        if push.registeredAt == nil || push.lastError != nil || push.relayError != nil { return .warn }
        return .good
    }
    private func notificationsDetail(_ push: PushRegistrar) -> String {
        if !push.notificationsEnabled { return "Turned off in Settings › Notifications" }
        switch push.authorization {
        case .denied: return "Not allowed in \(DeviceWords.settings)"
        case .notDetermined: return "Not asked yet"
        default: break
        }
        if let e = push.relayError ?? push.lastError { return e }
        guard push.registeredAt != nil else { return "Allowed, but \(DeviceWords.this) is not registered with the gateway yet" }
        return PushRelay.isConfigured ? "Allowed and registered with the gateway and the relay" : "Allowed and registered with the gateway"
    }
    private func liveActivityLight(_ push: PushRegistrar) -> Light {
        if !LiveActivityController.isEnabled { return .off }
        if !activitiesAllowed { return .bad }
        return push.pushToStartToken == nil ? .warn : .good
    }
    private func liveActivityDetail(_ push: PushRegistrar) -> String {
        if !LiveActivityController.isEnabled { return "Turned off in Settings › Notifications" }
        if !activitiesAllowed { return "Not allowed for Vory in iOS Settings" }
        return push.pushToStartToken == nil ? "On. The gateway can update a running one; starting one while Vory is closed is not set up yet on \(DeviceWords.this)" : "On, and the gateway can start one while Vory is closed"
    }
}
