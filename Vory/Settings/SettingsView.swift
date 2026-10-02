import SwiftUI
import UserNotifications
import VoryCore

struct SettingsView: View {
    @Environment(AppModel.self) private var model
    /// The first-run "set up notifications" card: shown once, until it is tapped or dismissed.
    @AppStorage("notificationsSetupCardDone") private var setupCardDone = false
    @State private var search = ""

    private struct Row: Identifiable { let id: String; let title: String; let symbol: String; let color: Color; let destination: AnyView }

    private var hermesRows: [Row] {
        [
            Row(id: "profile", title: "Profile", symbol: "person.crop.circle", color: .indigo, destination: AnyView(ProfileView())),
            Row(id: "projects", title: "Projects", symbol: "folder.fill", color: .indigo, destination: AnyView(ProjectsView())),
            Row(id: "plugins", title: "Plugins", symbol: "puzzlepiece.extension.fill", color: .orange, destination: AnyView(PluginsView())),
            Row(id: "model", title: "Model", symbol: "cpu", color: .blue, destination: AnyView(ModelSettingsView())),
            Row(id: "config", title: "Config", symbol: "slider.horizontal.3", color: .gray, destination: AnyView(ConfigFormView())),
            Row(id: "env", title: "API Keys & Environment", symbol: "key.fill", color: .orange, destination: AnyView(EnvView())),
            Row(id: "tools", title: "Tools", symbol: "wrench.and.screwdriver", color: .teal, destination: AnyView(ToolsView())),
            Row(id: "skills", title: "Skills", symbol: "sparkles", color: .purple, destination: AnyView(SkillsView())),
            Row(id: "mcp", title: "MCP Servers", symbol: "point.3.connected.trianglepath.dotted", color: .mint, destination: AnyView(MCPView())),
            Row(id: "approvals", title: "Approvals", symbol: "checkmark.shield", color: .green, destination: AnyView(ApprovalsView())),
            Row(id: "cron", title: "Scheduled Tasks", symbol: "timer", color: .pink, destination: AnyView(CronView())),
            Row(id: "sessions", title: "Sessions", symbol: "list.bullet.rectangle", color: .cyan, destination: AnyView(SessionsView())),
            Row(id: "channels", title: "Channels", symbol: "antenna.radiowaves.left.and.right", color: .brown, destination: AnyView(ChannelsView())),
            Row(id: "system", title: "System", symbol: "server.rack", color: .secondary, destination: AnyView(SystemView())),
        ]
    }
    private var appRows: [Row] {
        [
            Row(id: "status", title: "Status", symbol: "waveform.path.ecg", color: .green, destination: AnyView(StatusView())),
            Row(id: "notifications", title: "Notifications", symbol: "bell.badge", color: .red, destination: AnyView(NotificationsView())),
            Row(id: "security", title: "Security", symbol: "faceid", color: .green, destination: AnyView(SecurityView())),
            Row(id: "icloud", title: "iCloud Sync", symbol: "icloud.fill", color: .cyan, destination: AnyView(CloudSyncView())),
            Row(id: "bots", title: "Bots", symbol: "cloud.fill", color: .indigo, destination: AnyView(BotsSettingsView())),
            Row(id: "appearance", title: "Appearance", symbol: "circle.lefthalf.filled", color: .black, destination: AnyView(AppearanceView())),
            Row(id: "home", title: "Home", symbol: "house.fill", color: .blue, destination: AnyView(HomeSettingsView())),
            Row(id: "summaries", title: "Vory Summaries", symbol: "sparkles", color: .purple, destination: AnyView(SummariesSettingsView())),
            Row(id: "companion", title: "Companion", symbol: "puzzlepiece.fill", color: .blue, destination: AnyView(CompanionView())),
            Row(id: "troubleshooting", title: "Troubleshooting", symbol: "wrench.and.screwdriver", color: .orange, destination: AnyView(TroubleshootingView())),
            Row(id: "about", title: "About", symbol: "info.circle", color: .blue, destination: AnyView(AboutView())),
        ]
    }

    @State private var confirmReset = false
    private func filtered(_ rows: [Row]) -> [Row] { search.isEmpty ? rows : rows.filter { $0.title.localizedCaseInsensitiveContains(search) } }
    @AppStorage(BotColors.storageKey) private var botColorsRaw = ""
    @AppStorage(BotAvatarStore.storageKey) private var botAvatarsRaw = ""
    @AppStorage(BotAvatarStore.glassAllKey) private var glassAll = false
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        NavigationStack {
            SettingsList {
                if search.isEmpty, !setupCardDone, model.runtime != nil, model.push.registeredAt == nil {
                    Section {
                        NavigationLink { CompanionView() } label: {
                            HStack(spacing: 12) {
                                BotFaceView(spec: AboutView.voryBot, size: 46, active: true)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text("Unlock Vory's full potential").font(.headline)
                                    Text("Install the Companion for \(DeviceWords.companionBrings).").font(.caption).foregroundStyle(.secondary)
                                }
                                Spacer()
                                Button { withAnimation(.snappy) { setupCardDone = true } } label: {
                                    Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                                }
                                .buttonStyle(.plain)
                                .accessibilityLabel("Dismiss")
                            }
                            .padding(.vertical, 4)
                        }
                        .simultaneousGesture(TapGesture().onEnded { setupCardDone = true })
                    }
                }
                if search.isEmpty {
                    Section {
                        NavigationLink { GatewaysView() } label: {
                            HStack(spacing: 12) {
                                GatewayTile()
                                VStack(alignment: .leading) {
                                    Text(model.runtime?.connection.name ?? "No gateway").font(.headline)
                                    Text(model.runtime?.connection.gateway.description ?? "Add a gateway").font(.caption).foregroundStyle(.secondary).lineLimit(1)
                                }
                                Spacer()
                                if let s = model.runtime?.socketState { ConnectionPill(state: s) }
                            }
                            .padding(.vertical, 4)
                        }
                        if let rt = model.runtime, !rt.profiles.isEmpty {
                            Picker("Profile", selection: Binding(get: { rt.selectedProfile ?? "" }, set: { rt.selectedProfile = $0 })) {
                                ForEach(rt.profiles) { p in
                                    Label { Text(p.label) } icon: { Image(uiImage: BotAvatarImage.make(profile: p.name, size: 24, scheme: colorScheme)).renderingMode(.original) }.tag(p.name)
                                }
                            }
                            // The menu's icons are rendered images; a new identity redraws them when a look changes.
                            .id("profile-picker|\(botColorsRaw)|\(botAvatarsRaw)|\(glassAll)|\(colorScheme == .light)")
                        }
                    } header: { Text("Gateway") }
                }
                Section("Hermes") {
                    ForEach(filtered(hermesRows)) { row in
                        NavigationLink { row.destination.untitledPage() } label: { SettingsLabel(row.title, row.symbol, row.color) }
                    }
                }
                .disabled(model.runtime == nil)
                Section("App") {
                    ForEach(filtered(appRows)) { row in
                        NavigationLink { row.destination.untitledPage() } label: {
                            HStack {
                                SettingsLabel(row.title, row.symbol, row.color)
                                Spacer(minLength: 8)
                                if row.id == "companion", model.companionUpdateAvailable { CountBadge(1) }
                            }
                        }
                    }
                }
                if search.isEmpty {
                    Section {
                        Button(role: .destructive) { confirmReset = true } label: { Label("Reset Vory…", systemImage: "arrow.counterclockwise").foregroundStyle(.red) }
                            .accessibilityIdentifier("settings.reset")
                    } footer: {
                        Text("Takes \(DeviceWords.this) back to the first screen, as if Vory had just been installed.")
                    }
                }
            }
            // An alert, not an action sheet: its Cancel is on screen on every device (a popover
            // hides it), which matters with an erase among the choices.
            .alert("Reset Vory on \(DeviceWords.this)?", isPresented: $confirmReset) {
                Button("Reset \(DeviceWords.ThisTitle)", role: .destructive) { Task { await model.resetApp(eraseCloud: false) } }
                Button("Reset and Erase iCloud Data", role: .destructive) { Task { await model.resetApp(eraseCloud: true) } }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("Every saved gateway and sign-in, every setting and every bot look is removed from \(DeviceWords.this), and it stops receiving notifications. Your chats and bots live on the gateway and are not touched. What is in iCloud stays, so Restore from iCloud can bring it back, unless you erase that too; your other devices then stop syncing until you turn it on again there.")
            }
            .navigationTitle("Settings")
            .tabRoot(.settings)
            .background(InteractivePopEnabler())
            .searchable(text: $search, placement: .navigationBarDrawer(displayMode: .automatic), prompt: "Search settings")
        }
    }
}

/// The gateway's icon in Settings: the Vory cloud on a tile like the other rows, since the
/// gateway is where the bots live.
struct GatewayTile: View {
    var body: some View {
        RoundedRectangle(cornerRadius: 7, style: .continuous).fill(Color.blue)
            .frame(width: 28, height: 28)
            .overlay { VoryOutlineIcon().foregroundStyle(.white).frame(width: 20, height: 17) }
            .accessibilityHidden(true)
    }
}

struct SettingsLabel: View {
    var title: String; var symbol: String; var color: Color
    init(_ t: String, _ s: String, _ c: Color) { title = t; symbol = s; color = c }
    var body: some View {
        #if os(macOS)
        // A Mac list sets no gap between a label's icon and its text; this is System Settings' row.
        HStack(spacing: 10) {
            Image(systemName: symbol).font(.system(size: 12, weight: .medium)).foregroundStyle(.white)
                .frame(width: 22, height: 22).background(color, in: .rect(cornerRadius: 5.5))
            Text(title)
        }
        .padding(.vertical, 2)
        #else
        Label {
            Text(title)
        } icon: {
            // One symbol size for every row (SF Symbols vary in weight and width), centred in the tile.
            Image(systemName: symbol).font(.system(size: 15, weight: .medium)).foregroundStyle(.white)
                .frame(width: 28, height: 28).background(color, in: .rect(cornerRadius: 7))
        }
        #endif
    }
}

// MARK: Gateways

struct GatewaysView: View {
    @Environment(AppModel.self) private var model
    @State private var showAdd = false
    @State private var pendingDelete: GatewayConnection?

    var body: some View {
        SettingsList {
            SettingsHeaderSection(title: "Gateways", symbol: "network", color: .blue, description: "The gateways \(DeviceWords.this) can reach, and which one is active.")
            Section {
                ForEach(model.store.connections) { c in
                    HStack {
                        Button { Task { await model.activate(c) } } label: {
                            HStack {
                                Image(systemName: model.store.activeConnectionID == c.id ? "checkmark.circle.fill" : "circle").foregroundStyle(.tint)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(c.name).font(.body)
                                    Text(c.gateway.description).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                                    // One line of text, not three columns: side by side the parts
                                    // each wrapped on their own.
                                    Text(([GatewayFormView.ConnectionKind(rawValue: c.connectionKind ?? "")?.title, c.authMode.title, c.hasAccessHeaders && c.connectionKind != "cloudflare" ? "Cloudflare Access" : nil, c.lastVersion.map { "Hermes \($0)" }].compactMap { $0 }).joined(separator: "  ·  "))
                                        .font(.caption2).foregroundStyle(.tertiary).lineLimit(2)
                                }
                            }
                        }
                        .buttonStyle(.plain)
                        Spacer()
                        NavigationLink { GatewayFormView(existing: c) } label: { EmptyView() }.frame(width: 20)
                    }
                    .rowActions { Button(role: .destructive) { pendingDelete = c } label: { Label("Delete", systemImage: "trash") } }
                }
            } footer: {
                Text("One saved gateway covers every profile on that machine; switch profiles from the Chats or Settings tab. Approvals always go to the gateway that owns the session.")
            }
            Section {
                Button { showAdd = true } label: { Label("Add Gateway", systemImage: "plus") }
                if let rt = model.runtime {
                    Button { Task { await rt.reconnectNow() } } label: { Label("Reconnect", systemImage: "arrow.clockwise") }
                    if case .authRejected(let why) = rt.socketState {
                        Text(why).font(.footnote).foregroundStyle(.red)
                        NavigationLink("Sign in again") { GatewayFormView(existing: rt.connection) }
                    }
                }
            }
        }
        .untitledPage()
        .sheet(isPresented: $showAdd) { NavigationStack { GatewayFormView() }.sheetFrame() }
        .alert("Remove gateway?", isPresented: Binding(get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } })) {
            Button("Remove", role: .destructive) { if let c = pendingDelete { Task { await model.deleteConnection(c.id) } } }
            Button("Cancel", role: .cancel) {}
        } message: { Text("Saved credentials for this gateway are deleted from the Keychain.") }
    }
}

// MARK: Profile

struct ProfileView: View {
    @Environment(AppModel.self) private var model
    @State private var showCreate = false
    @State private var newName = ""
    @State private var cloneFrom = ""
    @State private var error: String?
    @State private var pendingDelete: ProfileInfo?
    @State private var deleting = false

    var body: some View {
        SettingsList {
            SettingsHeaderSection(title: "Profile", symbol: "person.crop.circle", color: .indigo, description: "Which bot the Settings screens read and write, and new bots on this gateway.")
            if let rt = model.runtime {
                Section("Active profile in this app") {
                    ForEach(rt.profiles) { p in
                        Button { rt.selectedProfile = p.name } label: {
                            HStack(spacing: 12) {
                                BotAvatar(profile: p.name, size: 36)
                                VStack(alignment: .leading) {
                                    Text(p.label)
                                    Text([p.model, p.description].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · ")).font(.caption).foregroundStyle(.secondary)
                                }
                                Spacer()
                                if rt.selectedProfile == p.name { Image(systemName: "checkmark").foregroundStyle(.tint) }
                            }
                        }
                        .tint(.primary)
                        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                            // The default profile is the gateway's own home; Hermes refuses to delete it.
                            if p.isDefault != true, p.name != "default" {
                                Button(role: .destructive) { pendingDelete = p } label: { Label("Delete", systemImage: "trash") }
                            }
                        }
                        .contextMenu {
                            if p.isDefault != true, p.name != "default" {
                                Button(role: .destructive) { pendingDelete = p } label: { Label("Delete profile…", systemImage: "trash") }
                            }
                        }
                    }
                }
                Section {
                    Button { showCreate = true } label: { Label("Create Profile", systemImage: "plus") }
                    if let error { Text(error).foregroundStyle(.red).font(.footnote) }
                } footer: { Text("Profiles are separate Hermes homes on the gateway machine (config, skills, sessions). Settings screens read and write the profile selected here.") }
            }
        }
        .reloadable { await model.runtime?.loadProfiles() }
        .alert("Delete \(pendingDelete?.label ?? "profile")?", isPresented: Binding(get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } })) {
            Button(deleting ? "Deleting…" : "Delete", role: .destructive) { if let p = pendingDelete { Task { await delete(p) } } }.disabled(deleting)
            Button("Cancel", role: .cancel) { pendingDelete = nil }
        } message: {
            Text("This removes the profile's folder on the gateway: its config, skills, chats and API keys. Its gateway and bots are stopped first. This cannot be undone.")
        }
        .alert("New profile", isPresented: $showCreate) {
            TextField("Name", text: $newName)
            TextField("Clone from (optional)", text: $cloneFrom)
            Button("Create") { Task { await create() } }
            Button("Cancel", role: .cancel) {}
        }
    }

    private func delete(_ p: ProfileInfo) async {
        guard let rt = model.runtime else { return }
        deleting = true; defer { deleting = false; pendingDelete = nil }
        do {
            // Stopping the profile's gateway and backends can take ten seconds or more.
            let r: JSONValue = try await rt.api.send("DELETE", "/api/profiles/\(p.name)", json: .object([:]))
            if r["ok"]?.boolValue == false { throw HermesAPIError.transport(r["error"]?.stringValue ?? "The gateway refused") }
            for chat in rt.chats where chat.profileName == p.name { rt.closeChat(chat) }
            if rt.selectedProfile == p.name { rt.selectedProfile = "default" }
            await rt.loadProfiles()
            error = nil
        } catch { self.error = "Could not delete \(p.label): \(error.localizedDescription)" }
    }

    private func create() async {
        guard let rt = model.runtime else { return }
        var body: [String: JSONValue] = ["name": .string(newName)]
        if !cloneFrom.isEmpty { body["clone_from"] = .string(cloneFrom) }
        do {
            let _: JSONValue = try await rt.api.send("POST", "/api/profiles", json: .object(body))
            await rt.loadProfiles()
            newName = ""; cloneFrom = ""; error = nil
        } catch { self.error = error.localizedDescription }
    }
}

// MARK: Notifications / Security / Appearance / About

struct NotificationsView: View {
    @Environment(AppModel.self) private var model
    @AppStorage("liveActivitiesEnabled") private var liveActivities = true
    @AppStorage("hapticsEnabled") private var haptics = true
    @AppStorage(TypingHaptics.key) private var typingHaptics = false
    @AppStorage(PushRegistrar.enabledKey) private var notificationsOn = true
    @AppStorage(PushRegistrar.muteDesktopOriginKey) private var muteDesktopOrigin = false

    var body: some View {
        let push = model.push
        SettingsList {
            SettingsHeaderSection(title: "Notifications", symbol: "bell.badge", color: .red, description: "Permission\(!DeviceWords.isMac ? ", Live Activities and haptics" : "") on \(DeviceWords.this).")
            Section {
                Toggle("Notifications", isOn: $notificationsOn)
                    .onChange(of: notificationsOn) { _, on in
                        Task {
                            guard let rt = model.runtime else { return }
                            if on { await push.registerWithRelay(); await push.syncRegistration(runtime: rt) }
                            else { await push.removeRegistration(runtime: rt) }
                        }
                    }
            } footer: {
                Text(notificationsOn ? "\(DeviceWords.this.capitalized) is registered with the gateway for approvals, questions, finished turns and errors while Vory is closed." : "Off: \(DeviceWords.this) is removed from the gateway's device list, so the Companion sends it nothing. Turn it on to register again.")
            }
            #if os(iOS)
            Section {
                Toggle("Quiet for chats driven from a Mac", isOn: $muteDesktopOrigin)
                    .disabled(!notificationsOn)
                    .onChange(of: muteDesktopOrigin) { _, _ in Task { if let rt = model.runtime { await push.syncRegistration(runtime: rt) } } }
            } footer: {
                Text("With Vory for Mac on the same gateway: a chat whose last message was sent from the Mac notifies the Mac only. Send from \(DeviceWords.this) and the chat is \(DeviceWords.this)'s again. Needs Companion 1.0.35.")
            }
            #endif
            Section {
                LabeledContent("Status", value: statusText(push.authorization))
                if push.authorization == .notDetermined {
                    Button("Allow Notifications") { Task { _ = await push.requestAuthorization() } }
                } else if push.authorization == .denied {
                    #if os(iOS)
                    Link("Open Settings", destination: URL(string: UIApplication.openSettingsURLString)!)
                    #else
                    Link("Open System Settings", destination: URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension")!)
                    #endif
                }
                #if os(iOS)
                Toggle("Live Activity", isOn: $liveActivities)
                Toggle("Haptics", isOn: $haptics)
                Toggle(isOn: $typingHaptics) {
                    HStack(spacing: 6) {
                        Text("Typing haptics")
                        Text("BETA").font(.caption2.weight(.bold)).padding(.horizontal, 5).padding(.vertical, 1)
                            .background(Capsule().fill(Color.vory.opacity(0.15))).foregroundStyle(Color.vory)
                    }
                }
                .disabled(!haptics)
                #endif
            } header: { Text("Permission") } footer: {
                #if os(iOS)
                Text("Typing haptics: a soft tick under your thumb as the reply's text arrives, for the chat on screen. Beta.")
                #else
                Text("Running turns and waiting approvals also sit in the menu bar, with a badge on the Dock icon.")
                #endif
            }
            Section {
                NavigationLink { CompanionView() } label: { Label("Companion", systemImage: "puzzlepiece.extension") }
                    .disabled(model.runtime == nil)
            } footer: {
                Text("Approvals, questions, finished turns and errors while Vory is closed are delivered by the Companion on your gateway. In the foreground they arrive locally without it.")
            }
        }
        .task { await push.refreshAuthorization() }
    }

    private func statusText(_ s: UNAuthorizationStatus) -> String {
        switch s { case .authorized: return "Allowed"; case .denied: return "Denied"; case .provisional: return "Provisional"; case .ephemeral: return "Ephemeral"; default: return "Not asked" }
    }
}

struct SecurityView: View {
    @Environment(AppModel.self) private var model
    @AppStorage(ApprovalConfirm.modeKey) private var confirmMode = ApprovalConfirm.mode
    var body: some View {
        SettingsList {
            SettingsHeaderSection(title: "Security", symbol: "faceid", color: .green, description: "\(!DeviceWords.isMac ? "Face ID" : "Touch ID") lock, a second step for approvals, and how \(DeviceWords.this) keeps its credentials.")
            Section {
                Toggle("Require \(model.lock.biometryName)", isOn: Binding(get: { model.lock.isEnabled }, set: { model.lock.isEnabled = $0 }))
            } footer: { Text("\(DeviceWords.isMac ? "Locks the app when the Mac sleeps or its screen locks." : "Locks the app after it has been in the background.") Gateway credentials are stored in the Keychain (device-only).") }
            Section {
                Picker(DeviceWords.isMac ? "Confirm from notifications" : "Confirm from the Lock Screen", selection: $confirmMode) {
                    Text("Risky actions").tag("risky")
                    Text("Every approval").tag("all")
                    Text("Never").tag("off")
                }
                .onChange(of: confirmMode) { _, _ in LocalNotifier.registerCategories() }
            } header: { Text("Approvals") } footer: {
                Text("Approve or Deny on \(DeviceWords.isMac ? "a notification" : "the Live Activity or a notification") opens the chat and, for the actions that matter, asks once more before it counts. Risky actions are writes, deletes and spends: a command that removes or changes files, pushes or deploys, installs, escalates, sends or pays for something, plus anything the smart guardian flagged. Reads and lookups apply at once, so the second question stays rare enough to mean something. The card's own buttons in the chat never ask twice.")
            }
        }
    }
}

/// Settings › Bots: what applies to every bot at once. Each bot's own look lives in its Creator
/// Studio (Bots tab › bot › Profile).
struct BotsSettingsView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.colorScheme) private var colorScheme
    @AppStorage(BotAvatarStore.glassAllKey) private var glassAll = false
    #if os(iOS)
    @AppStorage(BotMotionSource.enabledKey) private var motion = true
    @AppStorage(BotMotionSource.tiltKey) private var tilt = false
    @AppStorage(BotMotionSource.styleKey) private var style = "lively"
    #endif
    @AppStorage(GatewayRuntime.defaultProfileKey) private var defaultProfile = ""

    var body: some View {
        SettingsList {
            SettingsHeaderSection(title: "Bots", symbol: "cloud.fill", color: .indigo, description: DeviceWords.isMac ? "What applies to every bot at once: the default bot and glass." : "What applies to every bot at once: the default bot, glass, motion and tilt.")
            if let rt = model.runtime {
                Section {
                    Picker("Default bot", selection: $defaultProfile) {
                        Text("Follow the gateway").tag("")
                        ForEach(rt.profiles) { p in
                            Label { Text(p.label) } icon: { Image(uiImage: BotAvatarImage.make(profile: p.name, scheme: colorScheme)).renderingMode(.original) }.tag(p.name)
                        }
                    }
                    .onChange(of: defaultProfile) { _, _ in rt.returnToDefaultProfile() }
                } footer: {
                    Text("The bot the app comes back to: on launch, and after a chat with another bot. Chats from other bots still open; the selection just does not stay on them. Follow the gateway keeps whatever bot is active there.")
                }
            }
            #if os(iOS)
            // Motion and tilt come from the phone's gyroscope; a Mac has none.
            Section {
                Toggle("Motion effects", isOn: $motion)
                    .onChange(of: motion) { _, _ in BotMotionSource.shared.apply() }
                Picker("Style", selection: $style) {
                    Text("Lively").tag("lively")
                    Text("Calm").tag("calm")
                    Text("Still").tag("still")
                }
                .pickerStyle(.segmented)
                .disabled(!motion)
                .onChange(of: style) { _, _ in BotMotionSource.shared.apply() }
                Toggle(isOn: $tilt) {
                    HStack(spacing: 6) {
                        Text("Tilt with \(DeviceWords.the)")
                        Text("BETA").font(.caption2.weight(.bold)).padding(.horizontal, 5).padding(.vertical, 1)
                            .background(Capsule().fill(Color.vory.opacity(0.15))).foregroundStyle(Color.vory)
                    }
                }
                .disabled(!motion)
                .onChange(of: tilt) { _, _ in BotMotionSource.shared.apply() }
            } footer: {
                Text("Lively is every turn, lean and glance. Calm is half of it. Still keeps only the poses and the blinks, so a bot still shows what it is doing. Bots look where you scroll. With tilt on, they also lean with \(DeviceWords.the) and, on the Bots page, follow its angle with their eyes.")
            }
            #endif
            Section {
                NavigationLink { MotionDemoView() } label: { Label("Preview motion", systemImage: "play.circle") }
            } footer: {
                Text("Every pose the bots know, side by side: working, thinking, using a tool, waiting for a yes, and the rest. \(DeviceWords.isMac ? "Click one to see it react" : "Tap one to see its tap").")
            }
            Section {
                Toggle(isOn: $glassAll) {
                    HStack(spacing: 6) {
                        Text("Liquid Glass for all bots")
                        Text("BETA").font(.caption2.weight(.bold)).padding(.horizontal, 5).padding(.vertical, 1)
                            .background(Capsule().fill(Color.vory.opacity(0.15))).foregroundStyle(Color.vory)
                    }
                }
                .accessibilityIdentifier("settings.bots.glassAll")
            } footer: {
                Text("Every bot becomes a piece of glass, like the app icon — in chats, \(DeviceWords.isMac ? "the menu bar and notifications" : "the Island, notifications and the reply window"). Off, each bot keeps the finish chosen in its Creator Studio.")
            }
            if let profiles = model.runtime?.profiles, !profiles.isEmpty {
                Section("Your bots") {
                    ForEach(profiles) { p in
                        HStack(spacing: 12) {
                            BotAvatar(profile: p.name, size: 34)
                            Text(p.label)
                            Spacer()
                            if glassAll || BotAvatarStore.choice(for: p.name).isGlass { Image(systemName: "sparkles").foregroundStyle(.secondary).accessibilityLabel("Glass") }
                        }
                    }
                }
            }
        }
        .onChange(of: glassAll) { _, _ in BotLooksMirror.mirror() }
    }
}

/// Settings › Vory Summaries: the on-device model's titles and previews for the chat list, each
/// on its own switch so one can be tried without the other.
struct SummariesSettingsView: View {
    @AppStorage(ChatSummarizer.titlesKey) private var titles = ChatSummarizer.titlesOn
    @AppStorage(ChatSummarizer.previewsKey) private var previews = ChatSummarizer.previewsOn
    #if os(iOS)
    @AppStorage(WatchSync.summariesToWatchKey) private var toWatch = false
    #endif
    @State private var cleared = false

    var body: some View {
        SettingsList {
            SettingsHeaderSection(title: "Vory Summaries", symbol: "sparkles", color: .purple, description: "Apple Intelligence, on \(DeviceWords.this), reads each chat and writes its line in the list.")
            Section {
                Toggle(isOn: $titles) {
                    HStack(spacing: 6) {
                        Text("Titles")
                        Text("BETA").font(.caption2.weight(.bold)).padding(.horizontal, 5).padding(.vertical, 1)
                            .background(Capsule().fill(Color.vory.opacity(0.15))).foregroundStyle(Color.vory)
                    }
                }
                Toggle(isOn: $previews) {
                    HStack(spacing: 6) {
                        Text("Previews")
                        Text("BETA").font(.caption2.weight(.bold)).padding(.horizontal, 5).padding(.vertical, 1)
                            .background(Capsule().fill(Color.vory.opacity(0.15))).foregroundStyle(Color.vory)
                    }
                }
            } header: { Text("What the model writes") } footer: {
                Text(ChatSummarizer.unavailableReason ?? "Titles: a short name for each chat in place of the gateway's. Previews: two lines on where the chat stands in place of the last message. Either can be on alone. Nothing leaves \(DeviceWords.your) and nothing changes on the gateway; off, the list shows the gateway's own titles and previews.")
            }
            .disabled(!ChatSummarizer.isAvailable)
            #if os(iOS)
            Section {
                Toggle(isOn: $toWatch) { Label("Send to Apple Watch", systemImage: "applewatch") }
                    .onChange(of: toWatch) { _, _ in WatchSync.shared.refresh() }
            } header: { Text("Apple Watch") } footer: {
                Text("The summaries this iPhone has made go to the watch, which shows them in its chat list in place of the gateway's titles and previews. The watch runs no model itself; nothing is made there.")
            }
            #endif
            Section {
                Button(cleared ? "Summaries forgotten" : "Forget all summaries") { ChatSummarizer.shared.forgetAll(); cleared = true }
                    .disabled(cleared)
            } footer: { Text("Rows go back to the gateway's text until new summaries are made.") }
        }
    }
}

struct AppearanceView: View {
    @Environment(AppModel.self) private var model
    @AppStorage("colorSchemePreference") private var scheme = "system"
    @AppStorage(TabLayout.storageKey) private var layoutRaw = ""
    @AppStorage(ChatStyle.showToolCalls) private var showToolCalls = true
    @AppStorage(ChatStyle.showReasoning) private var showReasoning = true
    @AppStorage(ChatStyle.showTurnStats) private var showTurnStats = true
    @AppStorage(ChatStyle.showSystemNotes) private var showSystemNotes = true
    @AppStorage(ChatStyle.showBots) private var showBots = false
    @AppStorage(ChatStyle.timeReveal) private var timeReveal = true
    @AppStorage(ChatStyle.collapseAfterTurn) private var collapseAfterTurn = false
    @AppStorage(ChatStyle.showToolOutput) private var showToolOutput = true
    @AppStorage(ChatStyle.compactTools) private var compactTools = false
    @AppStorage(ChatStyle.currentStepOnly) private var currentStepOnly = false
    @AppStorage(ChatStyle.wideReplies) private var wideReplies = false
    @AppStorage(ChatStyle.bubbleStyle) private var bubbleStyle = "tailed"
    @AppStorage(ChatStyle.botTint) private var botTint = false
    @AppStorage(ChatStyle.textSize) private var textSize = "default"
    @Environment(\.editMode) private var editMode

    private var layout: TabLayout { TabLayout.parse(layoutRaw) }

    @AppStorage(ChatStyle.headerShowsTitle) private var headerShowsTitle = false
    #if os(macOS)
    private func tabBinding(_ tab: AppModel.AppTab) -> Binding<Bool> {
        Binding(get: { layout.contains(tab) }, set: { on in var l = layout; l.set(tab, enabled: on); layoutRaw = l.encoded })
    }
    private func moveTab(_ tab: AppModel.AppTab, by step: Int) {
        var l = layout
        guard let i = l.tabs.firstIndex(of: tab) else { return }
        let to = i + step
        guard l.tabs.indices.contains(to) else { return }
        l.move(fromOffsets: IndexSet(integer: i), toOffset: step > 0 ? to + 1 : to)
        layoutRaw = l.encoded
    }
    #endif
    var body: some View {
        SettingsList {
            SettingsHeaderSection(title: "Appearance", symbol: "circle.lefthalf.filled", color: .black, description: "Theme, tabs, the chat header and what the transcript shows.")

            #if os(iOS)
            Section {
                Picker("Chat header shows", selection: $headerShowsTitle) {
                    Text("Bot name").tag(false)
                    Text("Chat title").tag(true)
                }
            } footer: { Text("What the pill under the bot leads with in a chat; the other is shown beneath it while the bot is idle.") }
            #endif
            Section {
                AccentPicker()
            } header: { Text("Accent") } footer: { Text("Buttons, the selected tab, links and your bubbles take this colour. Bots keep their own.") }
            Section {
                Picker("Theme", selection: $scheme) {
                    Text("System").tag("system")
                    Text("Light").tag("light")
                    Text("Dark").tag("dark")
                }
                .pickerStyle(.segmented)
            } header: { Text("Appearance") } footer: {
                Text("Liquid Glass intensity, Reduce Transparency, Increase Contrast, Bold Text, Dynamic Type and Reduce Motion follow \(DeviceWords.isMac ? "System Settings" : "\(DeviceWords.your)'s own settings").")
            }
            #if os(macOS)
            // The Mac's sidebar holds every page: a switch each, arrows for the order.
            Section {
                ForEach(layout.tabs, id: \.self) { tab in
                    HStack(spacing: 10) {
                        Label(tab.title, systemImage: tab.symbol)
                        Spacer()
                        Button { moveTab(tab, by: -1) } label: { Image(systemName: "chevron.up") }
                            .buttonStyle(.borderless).disabled(layout.tabs.first == tab).help("Move up")
                        Button { moveTab(tab, by: 1) } label: { Image(systemName: "chevron.down") }
                            .buttonStyle(.borderless).disabled(layout.tabs.last == tab).help("Move down")
                        Toggle("Show \(tab.title) in the sidebar", isOn: tabBinding(tab)).labelsHidden().disabled(TabLayout.required.contains(tab))
                    }
                }
                ForEach(AppModel.AppTab.allCases.filter { !layout.contains($0) }, id: \.self) { tab in
                    HStack(spacing: 10) {
                        Label(tab.title, systemImage: tab.symbol).foregroundStyle(.secondary)
                        Spacer()
                        Toggle("Show \(tab.title) in the sidebar", isOn: tabBinding(tab)).labelsHidden()
                    }
                }
            } header: { Text("Sidebar") } footer: {
                Text("Switch a page on to put it in the sidebar; the arrows set the order. Chats and Settings stay. ⌘1 to ⌘9 open the first nine.")
            }
            #else
            Section {
                ForEach(layout.tabs, id: \.self) { tab in
                    // Chats and Settings stay: no delete control, and no lock badge either.
                    Label(tab.title, systemImage: tab.symbol)
                        .deleteDisabled(TabLayout.required.contains(tab))
                }
                .onMove { from, to in var l = layout; l.move(fromOffsets: from, toOffset: to); layoutRaw = l.encoded }
                .onDelete { offsets in
                    var l = layout
                    for i in offsets.sorted(by: >) { l.set(l.tabs[i], enabled: false) }
                    layoutRaw = l.encoded
                }
            } header: {
                HStack { Text("Tab bar · \(layout.tabs.count) of \(TabLayout.maxTabs)"); Spacer(); EditButton().font(.caption) }
            } footer: {
                Text(editMode?.wrappedValue.isEditing == true
                     ? "Drag to reorder, swipe or − to remove. Chats and Settings can move but not go."
                     : "\(DeviceWords.Tap) Edit to reorder or add tabs. Four fit on the bar; New Chat floats beside it.")
            }
            // Hidden tabs only appear while editing, like the Messages/Music tab editors.
            if editMode?.wrappedValue.isEditing == true {
                Section {
                    let missing = AppModel.AppTab.allCases.filter { !layout.contains($0) }
                    if missing.isEmpty { Text("Everything is on the bar.").foregroundStyle(.secondary).font(.footnote) }
                    ForEach(missing, id: \.self) { tab in
                        Button { var l = layout; l.set(tab, enabled: true); layoutRaw = l.encoded } label: {
                            HStack {
                                Image(systemName: "plus.circle.fill").foregroundStyle(layout.isFull ? .gray : .green)
                                Label(tab.title, systemImage: tab.symbol)
                            }
                        }
                        .tint(.primary)
                        .disabled(layout.isFull)
                    }
                } header: { Text("Not on the bar") } footer: {
                    if layout.isFull { Text("Remove one to add another.") }
                }
            }
            #endif
            if let rt = model.runtime, !rt.profiles.isEmpty {
                Section {
                    ForEach(rt.profiles) { p in
                        BotColorRow(profile: p.name, label: p.label)
                    }
                } header: { Text("Bot colors") } footer: { Text("Shown in chat headers, the Bots list and \(DeviceWords.isMac ? "the menu bar" : "each bot's Live Activity"). Stored on this device.") }
            }
            Section {
                Toggle("Show tool calls", isOn: $showToolCalls)
                Toggle("Show reasoning", isOn: $showReasoning)
                Toggle("Show tokens per second", isOn: $showTurnStats)
                Toggle("Show system notes", isOn: $showSystemNotes)
                Toggle("Bot beside replies", isOn: $showBots)
                #if os(iOS)
                Toggle("Pull left for times", isOn: $timeReveal)
                #endif
            } header: { Text("Chat") } footer: {
                Text("Hidden rows are still received and kept; this only changes what the transcript draws. Approval cards are always shown. Pull left for times slides the thread aside to show when each message arrived; off, the thread never moves sideways.")
            }
            Section {
                Toggle("Fold tool cards and reasoning after the turn", isOn: $collapseAfterTurn)
                Toggle("Show tool output", isOn: $showToolOutput)
                Toggle("Compact tool cards", isOn: $compactTools)
                Toggle("Only the current step", isOn: $currentStepOnly)
            } header: { Text("Tool calls and reasoning") } footer: {
                Text("Only the current step keeps just the tool running now and the reasoning of the reply being written; finished steps disappear from the thread, as in ChatGPT. Everything is still kept, and turning it off brings it all back.")
            }
            Section {
                Picker("Bubbles", selection: $bubbleStyle) {
                    Text("Tailed").tag("tailed")
                    Text("Rounded").tag("rounded")
                    Text("Plain").tag("plain")
                }
                Toggle("Bot colour on replies", isOn: $botTint)
                Toggle("Wide replies", isOn: $wideReplies)
                Picker("Text size", selection: $textSize) {
                    Text("Small").tag("small")
                    Text("Default").tag("default")
                    Text("Large").tag("large")
                }
            } header: { Text("Reading") } footer: {
                Text("Wide replies let a reply run to the right edge instead of leaving a margin. Text size is one step down or up from \(DeviceWords.your)'s own text size, in chats only.")
            }
            Section {
                Button("Clear chat list cache") { SessionCache.clearAll() }
                Button("Reset to default") { layoutRaw = ""; scheme = "system"; showToolCalls = true; showReasoning = true; showTurnStats = true; showSystemNotes = true; collapseAfterTurn = false; showToolOutput = true; compactTools = false; currentStepOnly = false; wideReplies = false; textSize = "default"; bubbleStyle = "tailed"; botTint = false }
            } footer: { Text("The Chats tab remembers its last list so it opens instantly; clearing it just forces a fresh fetch.") }
        }
    }
}

struct AboutView: View {
    @Environment(AppModel.self) private var model
    @State private var taps = 0
    @State private var lastTap = Date.distantPast
    @State private var raining = false
    @State private var lifted = false
    @State private var relieved = false

    private var appVersion: String { (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?") + " (" + (Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "?") + ")" }
    static let voryBot = BotLookSpec.vory

    var body: some View {
        SettingsList {
            SettingsHeaderSection(title: "About", symbol: "info.circle", color: .blue, description: "Version, the Vory cloud, and what is installed.")
                .listSectionSpacing(8)
            Section {
                VStack(spacing: 6) {
                    ZStack(alignment: .top) {
                        if raining {
                            // Falls from under the cloud, not out of its middle.
                            RainOverlay().frame(width: 140, height: 64).offset(y: 118 - 30).allowsHitTesting(false).transition(.opacity)
                        }
                        BotFaceView(spec: Self.voryBot, size: 132, active: true, gaze: CGPoint(x: 0, y: raining ? 1 : 0))
                            .offset(y: lifted ? -30 : 0)
                            // The face has its own tap and holes in its hit shape; the taps
                            // must all land on the box around it, or five never add up.
                            .allowsHitTesting(false)
                        if relieved {
                            SpeechBubble(text: "Ahhhh…that's better.")
                                .offset(y: -44)
                                .transition(.scale(scale: 0.2, anchor: .bottom).combined(with: .opacity))
                        }
                    }
                    .frame(height: 140, alignment: .top)
                    // Room for the lift; the speech bubble may overlap the card above for a moment.
                    .padding(.top, 16)
                    .contentShape(Rectangle())
                    .onTapGesture { tapped() }
                    Text("Vory").font(.title.weight(.bold))
                    Text("Version \(appVersion)").font(.footnote).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 6)
                .listRowBackground(Color.clear)
                .listRowSeparator(.hidden)
            }
            // Close under the header card: the page then fits the cloud, the version and the
            // Installed list on one screen.
            .listSectionSpacing(8)
            Section {
                LabeledContent("Companion plugin", value: model.companionInstalledVersion.map { "v\($0)" } ?? "not installed")
                LabeledContent("Ships with this build", value: "v\(PushSetupModel.bundledPluginVersion)")
                LabeledContent("Push relay", value: PushRelay.isConfigured ? "configured" : "none")
                #if os(iOS)
                LabeledContent("Live Activity", value: appVersion)
                #endif
                LabeledContent("Notification extensions", value: appVersion)
            } header: { Text("Installed") } footer: {
                Text("What Vory puts on your gateway and inside this app. Updates arrive under Software Update.")
            }
            Section {
                Link(destination: URL(string: "mailto:matt@vory.dev?subject=Vory%20feedback")!) { Label("Send feedback", systemImage: "envelope") }
                Link(destination: URL(string: "https://vory.dev/privacy/")!) { Label("Privacy policy", systemImage: "hand.raised") }
                Link(destination: URL(string: "https://vory.dev")!) { Label("vory.dev", systemImage: "safari") }
            } header: { Text("Vory") } footer: {
                Text("A public beta. In TestFlight, take a screenshot to send feedback with it attached.")
            }
            Section {
                Link("Hermes Agent documentation", destination: URL(string: "https://hermes-agent.nousresearch.com/docs")!)
            }
        }
        .animation(.smooth, value: raining)
        .animation(.spring(response: 0.6, dampingFraction: 0.7), value: lifted)
        .animation(.spring(response: 0.4, dampingFraction: 0.6), value: relieved)
        .task { await model.refreshCompanionUpdateFlag() }
    }

    /// Five quick taps on the cloud and it rains for five seconds (and it watches the rain).
    private func tapped() {
        let now = Date()
        taps = now.timeIntervalSince(lastTap) < 1.5 ? taps + 1 : 1
        lastTap = now
        guard taps >= 5, !raining, !lifted else { return }
        taps = 0
        lifted = true
        Task {
            try? await Task.sleep(for: .milliseconds(650))
            raining = true
            try? await Task.sleep(for: .seconds(5))
            raining = false
            try? await Task.sleep(for: .milliseconds(350))
            lifted = false
            try? await Task.sleep(for: .milliseconds(500))
            relieved = true
            try? await Task.sleep(for: .seconds(3))
            relieved = false
        }
    }
}

/// A little speech bubble whose tail (bottom centre) is part of the same shape, pointing down at
/// whoever said it.
struct SpeechBubble: View {
    var text: String
    var body: some View {
        Text(text)
            .font(.subheadline.weight(.medium))
            .padding(.horizontal, 12).padding(.vertical, 8)
            .padding(.bottom, 8)
            .background(Color(.secondarySystemFill), in: SpeechBubbleShape())
            .fixedSize()
    }
}

/// Rain drops falling from the cloud: a couple of dozen streaks with their own speed and phase.
struct RainOverlay: View {
    struct Drop { var x: Double; var speed: Double; var phase: Double; var len: Double }
    private static let drops: [Drop] = (0..<28).map { (i: Int) -> Drop in
        let col: Double = Double(i % 9) / 9.0
        let jitter: Double = Double((i * 7) % 5) * 0.012
        let speed: Double = 0.9 + Double((i * 13) % 7) / 7.0 * 0.8
        let phase: Double = Double((i * 31) % 100) / 100.0
        let len: Double = 10.0 + Double((i * 5) % 4) * 4.0
        return Drop(x: 0.18 + col * 0.64 + jitter, speed: speed, phase: phase, len: len)
    }
    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 40)) { tl in
            let t = tl.date.timeIntervalSinceReferenceDate
            Canvas { ctx, size in
                for d in Self.drops {
                    let u = ((t * d.speed) + d.phase).truncatingRemainder(dividingBy: 1)
                    let y = u * size.height
                    let x = size.width * d.x
                    var p = Path()
                    p.move(to: CGPoint(x: x, y: y))
                    p.addLine(to: CGPoint(x: x - 2, y: y + d.len))
                    ctx.stroke(p, with: .color(Color(red: 0.45, green: 0.7, blue: 1).opacity(0.85 * (1 - u * 0.6))), style: StrokeStyle(lineWidth: 2, lineCap: .round))
                }
            }
        }
    }
}

/// Settings › Software Update: the companion plugin on the gateway, updated in place like an iOS update.
struct SoftwareUpdateView: View {
    @Environment(AppModel.self) private var model
    @State private var setup = PushSetupModel()

    var body: some View {
        SettingsList {
            SettingsHeaderSection(title: "Software Update", symbol: "arrow.down.circle", color: .gray, description: "The Companion version on the gateway, updated in place.")
            if let rt = model.runtime {
                Section {
                    if setup.companionCheckedAt == nil {
                        Label { Text("Checking for updates…") } icon: { ProgressView() }.foregroundStyle(.secondary)
                    } else if setup.installedVersion == nil {
                        NavigationLink { SetupWizardHost() } label: {
                            HStack(spacing: 12) {
                                BotFaceView(spec: AboutView.voryBot, size: 44, active: true)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text("Install the Vory Companion").font(.headline)
                                    Text("Unlocks \(DeviceWords.companionBrings) while Vory is closed.").font(.caption).foregroundStyle(.secondary)
                                }
                            }
                        }
                    } else if setup.updateAvailable || setup.updating || setup.showUpdateConsole || setup.updateOutcome != nil {
                        CompanionUpdateRows(setup: setup, runtime: rt)
                    } else {
                        VStack(spacing: 8) {
                            BotFaceView(spec: AboutView.voryBot, size: 56, mood: BotFaceView.Mood(profile: "vory-update", state: .guide, squint: setup.checkingCompanion))
                            Text("Vory Companion \(PushSetupModel.bundledPluginVersion)").font(.headline)
                            Text(setup.checkingCompanion ? "Checking for updates…" : "Your gateway is up to date.").font(.subheadline).foregroundStyle(.secondary)
                                .contentTransition(.numericText())
                        }
                        .frame(maxWidth: .infinity).padding(.vertical, 10)
                        .animation(.snappy, value: setup.checkingCompanion)
                    }
                } header: { sectionHeader("Vory Companion") } footer: {
                    Text("A small plugin on your gateway. It sends replies as notifications, \(DeviceWords.keepsActivity)and gets approval cards to \(DeviceWords.your) the moment a bot needs a yes. Installs in place; no restart unless it says so.")
                }
                Section {
                    LabeledContent("On the gateway", value: setup.installedVersion.map { "v\($0)" } ?? "—")
                    if let hb = setup.heartbeat { LabeledContent("Running", value: "v\(hb.version)") }
                    LabeledContent("This build ships", value: "v\(PushSetupModel.bundledPluginVersion)")
                    Button { Task { await setup.checkCompanion(runtime: rt) } } label: {
                        Label("Check again\(setup.companionCheckedAt.map { " (last \($0.formatted(date: .omitted, time: .shortened)))" } ?? "")", systemImage: "arrow.triangle.2.circlepath")
                    }
                    .disabled(setup.checkingCompanion)
                }
            } else {
                Text("Connect a gateway first.").foregroundStyle(.secondary)
            }
        }
        .listSectionSpacing(28)
        .animation(.smooth, value: setup.updateOutcome == nil)
        .task { if let rt = model.runtime { await setup.prepare(runtime: rt) } }
        .reloadable { if let rt = model.runtime { await setup.checkCompanion(runtime: rt) } }
        // The cloud squints while it checks and turns once the answer is in.
        .onChange(of: setup.checkingCompanion) { was, now in if was, !now { BotAmbient.shared.turnFinished(profile: "vory-update") } }
        .onChange(of: setup.companionCheckedAt) { _, _ in
            model.companionUpdateAvailable = setup.updateAvailable
            model.companionInstalledVersion = setup.installedVersion
        }
    }
}

/// The notifications wizard, opened straight from the first-run card in Settings.
struct SetupWizardHost: View {
    @Environment(AppModel.self) private var model
    @State private var setup = PushSetupModel()
    var body: some View {
        PushSetupView(setup: setup)
            .task { if let rt = model.runtime { await setup.prepare(runtime: rt) } }
    }
}

struct BotColorRow: View {
    var profile: String
    var label: String
    @AppStorage(BotColors.storageKey) private var raw = ""
    @State private var color: Color = .accentColor

    var body: some View {
        ColorPicker(selection: $color, supportsOpacity: false) {
            HStack(spacing: 10) { BotAvatar(profile: profile, size: 26); Text(label) }
        }
        .onAppear { color = BotColors.color(for: profile) }
        .onChange(of: color) { _, c in
            BotColors.set(c, for: profile)
            raw = String(data: (try? JSONEncoder().encode(BotColors.stored())) ?? Data(), encoding: .utf8) ?? raw
        }
    }
}


/// The red count circle the tab bar uses, for rows on the way to whatever needs attention.
struct CountBadge: View {
    var count: Int
    init(_ count: Int) { self.count = count }
    var body: some View {
        Text("\(count)")
            .font(.caption2.weight(.semibold)).monospacedDigit()
            .foregroundStyle(.white)
            .padding(.horizontal, count > 9 ? 6 : 0)
            .frame(minWidth: 20, minHeight: 20)
            .background(Capsule().fill(.red))
            .accessibilityLabel("\(count) waiting")
    }
}
