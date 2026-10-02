import CryptoKit
import SwiftUI
import UniformTypeIdentifiers
import UserNotifications
import VoryCore

/// Step-by-step setup for the `hermes-push` companion: one card per step, swiped or stepped
/// through. A later card only opens once everything before it is done; the last one shows the whole
/// picture and sends a test notification through the real path.
struct PushSetupView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @Bindable var setup: PushSetupModel
    @State private var step: SetupStep = .apple
    @State private var showKeyPicker = false
    @State private var showCompanionSignIn = false
    @State private var confirmStartOver = false
    @State private var confirmQuit = false

    private var rt: GatewayRuntime? { model.runtime }

    enum SetupStep: Int, CaseIterable, Identifiable {
        case apple, address, signIn, install, start, overview
        var id: Int { rawValue }
        var title: String {
            switch self {
            case .apple: return "Apple push"
            case .address: return "Gateway address"
            case .signIn: return "Companion sign-in"
            case .install: return "Put it on the Gateway"
            case .start: return "Start the companion"
            case .overview: return "Overview & test"
            }
        }
        var subtitle: String {
            switch self {
            case .apple: return "Permission, relay and \(DeviceWords.this)'s device file"
            case .address: return "Where the companion reaches Hermes"
            case .signIn: return "The companion's own login"
            case .install: return "Config, companion and plugin in one go"
            case .start: return "Heartbeat straight from the gateway"
            case .overview: return "Summary, then a real test notification"
            }
        }
        /// A different Vory character keeps each step company.
        var avatar: String {
            switch self {
            case .apple: return "pip"
            case .address: return "halo"
            case .signIn: return "prism"
            case .install: return "ember"
            case .start: return "wisp"
            case .overview: return "nimbus"
            }
        }
        var symbol: String {
            switch self {
            case .apple: return "bell.badge"
            case .address: return "link"
            case .signIn: return "person.badge.key"
            case .install: return "arrow.up.doc"
            case .start: return "play.circle"
            case .overview: return "checkmark.seal"
            }
        }
        var next: SetupStep? { SetupStep(rawValue: rawValue + 1) }
        var previous: SetupStep? { SetupStep(rawValue: rawValue - 1) }
    }

    /// While files are going up or the gateway is restarting, the cards stay put: no swiping, no
    /// buttons, until the companion is back and reporting in.
    private var locked: Bool {
        setup.installing || setup.updating || setup.restarting || (rt?.maintenance.isBusy ?? false)
    }

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var forward = true
    /// Measured from whichever page is showing; the next page starts from it instead of a guess.
    @State private var headerHeight: CGFloat = 270
    /// True a moment after the last step completes, once the bot has finished its hop.
    @State private var doneSettled = false

    /// What Vory says: the step's guidance, or a nudge onward once it is done.
    private var says: String {
        if isDone(step) { return step == .overview ? "That's it! \(DeviceWords.CompanionBrings) are all yours." : "That's done — \(DeviceWords.tap) Continue." }
        return hint(for: step)
    }
    /// A turn on each new step, and again the moment a step completes.
    private var turnKey: String { "\(step.rawValue)-\(isDone(step))" }

    var body: some View {
        ZStack {
            StepPage(step: step, done: isDone(step), headerHeight: $headerHeight) {
                if let rt { content(for: step, runtime: rt) } else { Text("Connect a gateway first.").foregroundStyle(.secondary) }
            } header: {
                VoryGuide(says: says, key: turnKey, turnKey: turnKey, thinking: locked || awaitingCompanion, done: isDone(step), reduceMotion: reduceMotion, size: 88)
            }
            .id(step)
            .transition(.asymmetric(insertion: .move(edge: forward ? .trailing : .leading).combined(with: .opacity),
                                    removal: .move(edge: forward ? .leading : .trailing).combined(with: .opacity)))
        }
        .overlay(alignment: .bottom) { bottomBar }
        .overlay(alignment: .topLeading) {
            if let p = step.previous {
                Button { go(to: p) } label: {
                    Image(systemName: "chevron.left").font(.body.weight(.semibold)).frame(width: 40, height: 40)
                }
                .buttonStyle(.glass).buttonBorderShape(.circle)
                .disabled(locked)
                .padding(.leading, 16).padding(.top, 10)
                .accessibilityLabel("Back")
                .transition(.opacity)
            }
        }
        .background(Color(.systemGroupedBackground))
        .toolbar(.hidden, for: .navigationBar)
        .hidesTabBar()
        .navigationBarBackButtonHidden(true)
        .fileImporter(isPresented: $showKeyPicker, allowedContentTypes: [UTType(filenameExtension: "p8") ?? .data, .data]) { result in
            if case .success(let url) = result { setup.importKey(url) }
        }
        .sheet(isPresented: $showCompanionSignIn) {
            if let rt { CompanionSignInSheet(runtime: rt) { secrets in setup.companionSecrets = secrets; setup.rememberCompanionSecrets(for: rt) }.sheetFrame() }
        }
        .alert("Cancel setup?", isPresented: $confirmQuit) {
            Button("Cancel setup", role: .destructive) { if let rt { setup.startOver(runtime: rt) }; dismiss() }
            Button("Keep going", role: .cancel) {}
        } message: {
            Text("This clears the address, the companion sign-in and your progress on \(DeviceWords.this). Nothing on the gateway changes. You'll start from the first step next time.")
        }
        .alert("Start over?", isPresented: $confirmStartOver) {
            Button("Start over", role: .destructive) { if let rt { setup.startOver(runtime: rt); withAnimation(.snappy) { step = .apple } } }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Clears the address, the companion sign-in and \(DeviceWords.this)'s progress. Nothing on the gateway changes until you install again.")
        }
        .task {
            if setup.teamID.isEmpty { setup.teamID = ProvisioningProfile.teamID ?? "" }
            guard let rt else { return }
            await setup.prepare(runtime: rt)
            // The check needs the profile's folder, known once the socket is up: a second
            // phone opening the wizard right after connecting would otherwise see nothing installed.
            if rt.profileHome == nil {
                for _ in 0..<6 where rt.profileHome == nil { try? await Task.sleep(for: .seconds(1)) }
                if rt.profileHome != nil { await setup.checkCompanion(runtime: rt) }
            }
            // Always from the first step: done steps show their green state and Continue moves on.
        }
        .onChange(of: isDone(.overview)) { _, now in
            doneSettled = false
            if now { Task { try? await Task.sleep(for: .milliseconds(900)); doneSettled = true } }
        }
        .task(id: step) {
            // The companion's heartbeat is the proof for these two steps: keep it fresh while they are on screen.
            guard step == .start || step == .overview, let rt else { return }
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(5))
                guard !Task.isCancelled else { return }
                await setup.checkCompanion(runtime: rt)
            }
        }
    }

    /// What the mascot says on a card that is not finished yet.
    private func hint(for s: SetupStep) -> String {
        switch s {
        case .apple: return "Allow notifications, then \(DeviceWords.tap) Register."
        case .address: return "Where the companion finds Hermes — usually \(DeviceWords.this)'s URL."
        case .signIn: return "Its own login — same account as the dashboard."
        case .install: return setup.installedOnGateway ? "Installed. Restart when the timer ends, or \(DeviceWords.tap) Restart now." : "One \(DeviceWords.tap) puts everything on the Gateway."
        case .start: return locked ? "Hold on, the Gateway is restarting…" : "Waiting for the companion's first heartbeat."
        case .overview: return setup.companionHealthy ? "All set. Send a test to prove the chain." : "The companion isn't reporting in — go back a step."
        }
    }

    private func isDone(_ s: SetupStep) -> Bool {
        guard let rt else { return false }
        switch s {
        case .apple: return setup.appleReady(push: model.push)
        case .address: return setup.addressValid
        case .signIn: if setup.alreadyServing { return true }; if case .needsSignIn = setup.credential(for: rt) { return false } else { return true }
        case .install: return (setup.installedOnGateway || setup.alreadyServing) && !setup.restartPending
        case .start: return setup.companionHealthy
        case .overview: return setup.companionHealthy && setup.testPassed
        }
    }

    /// Earlier cards are always open; a later one only once everything before it is done.
    private func canOpen(_ s: SetupStep) -> Bool {
        SetupStep.allCases.filter { $0.rawValue < s.rawValue }.allSatisfy { isDone($0) }
    }

    private func go(to s: SetupStep) {
        guard !locked, canOpen(s), s != step else { return }
        forward = s.rawValue > step.rawValue
        withAnimation(.smooth(duration: 0.4)) { step = s }
    }

    /// On the start step, the gateway has restarted and we are waiting for the companion to report in.
    private var awaitingCompanion: Bool {
        step == .start && !isDone(.start) && setup.installedOnGateway && !setup.restartPending && (setup.restarting || setup.heartbeat != nil)
    }

    /// Continue, and under it Exit (on the first step) or Cancel setup (after that, which wipes
    /// this phone's progress). Like the first-run tour: no step marks, no arrows.
    private var bottomBar: some View {
        VStack(spacing: 10) {
            if step == .overview {
                Button { if let rt { setup.markCompleted(for: rt) }; dismiss() } label: {
                    Text("Done").font(.headline).frame(maxWidth: .infinity).padding(.vertical, 6)
                }
                .buttonStyle(.glassProminent)
                .disabled(locked || !isDone(.overview) || !doneSettled)
                .accessibilityIdentifier("setup.done")
            } else {
                Button { if let n = step.next { go(to: n) } } label: {
                    ZStack {
                        Text("Continue").font(.headline).opacity(locked || awaitingCompanion ? 0 : 1)
                        if locked || awaitingCompanion { ProgressView().tint(.white) }
                    }
                    .frame(maxWidth: .infinity).padding(.vertical, 6)
                }
                .buttonStyle(.glassProminent)
                .disabled(!isDone(step) || locked)
                .accessibilityIdentifier("setup.continue")
            }
            if step == .apple {
                Button("Exit") { dismiss() }
                    .font(.subheadline).foregroundStyle(.secondary)
                    .accessibilityIdentifier("setup.exit")
            } else if step != .overview {
                Button("Cancel setup") { confirmQuit = true }
                    .font(.subheadline).foregroundStyle(.secondary)
                    .disabled(locked)
                    .accessibilityIdentifier("setup.cancel")
            } else {
                Text(" ").font(.subheadline)
            }
        }
        #if os(macOS)
        // A button the size of a button, under the form's column; the second one reads as a link.
        .buttonStyle(.borderless)
        .frame(maxWidth: 340)
        .frame(maxWidth: .infinity)
        #endif
        .padding(.horizontal, 24).padding(.top, 28).padding(.bottom, 16)
        .background(
            // Solid behind the buttons, fading out above them so the form scrolls under.
            LinearGradient(stops: [.init(color: Color(.systemGroupedBackground).opacity(0), location: 0), .init(color: Color(.systemGroupedBackground), location: 0.3)], startPoint: .top, endPoint: .bottom)
                .ignoresSafeArea()
        )
        .animation(.snappy, value: step)
    }

    // MARK: Steps

    @ViewBuilder private func content(for s: SetupStep, runtime rt: GatewayRuntime) -> some View {
        switch s {
        case .apple: appleStep(rt)
        case .address: addressStep(rt)
        case .signIn: signInStep(rt)
        case .install: installStep(rt)
        case .start: startStep(rt)
        case .overview: overviewStep(rt)
        }
    }

    @ViewBuilder private func appleStep(_ rt: GatewayRuntime) -> some View {
        let push = model.push
        if !PushRelay.isConfigured {
            Section {
                if let name = setup.keyFileName {
                    LabeledContent("Key file", value: name)
                    LabeledContent("Key ID", value: setup.keyID)
                } else {
                    Button { showKeyPicker = true } label: { Label("Choose AuthKey_….p8", systemImage: "key") }
                }
                TextField("Team ID", text: $setup.teamID)
                    .textInputAutocapitalization(.characters).autocorrectionDisabled()
                    .font(.body.monospaced())
            } header: { sectionHeader("APNs key") } footer: {
                Text("This build has no push relay, so it needs your own APNs key: developer.apple.com › Keys with the Apple Push Notifications service capability. The Key ID comes from the filename; the Team ID is read from this build's provisioning profile.")
            }
        }
        Section {
            LabeledContent("Notifications", value: Self.statusText(push.authorization))
            if push.authorization == .notDetermined {
                Button("Allow notifications") { Task { _ = await push.requestAuthorization() } }
            } else if push.authorization == .denied {
                #if os(iOS)
                Link("Open Settings", destination: URL(string: UIApplication.openSettingsURLString)!)
                #else
                Link("Open System Settings", destination: URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension")!)
                #endif
            }
            if PushRelay.isConfigured {
                LabeledContent("Push relay", value: push.relayRegisteredAt.map { "registered " + $0.formatted(date: .omitted, time: .shortened) } ?? "not registered yet")
            }
            LabeledContent("Device file on gateway", value: push.registeredAt.map { "published " + $0.formatted(date: .omitted, time: .shortened) } ?? "not published yet")
            // Approval and clarify cards arrive as server→client requests on this socket; this
            // says whether the gateway agreed to send them and whether any have come.
            LabeledContent("Approval requests") {
                VStack(alignment: .trailing, spacing: 2) {
                    Text(rt.serverRequestsAdvertised.isEmpty ? "not acknowledged by the gateway" : "\(rt.serverRequestsReceived) received")
                    Text(rt.lastServerRequest ?? (rt.serverRequestsAdvertised.isEmpty ? "reconnect, or update Hermes on the gateway" : "none yet on this connection; only actions the gateway's approval mode holds for a person reach \(DeviceWords.the)"))
                        .font(.caption).foregroundStyle(.secondary)
                }
                .multilineTextAlignment(.trailing)
            }
            if let e = push.relayError ?? push.lastError ?? push.registrationFailure { Label(e, systemImage: "xmark.octagon").font(.footnote).foregroundStyle(.red) }
            Button {
                Task { await setup.registerPhone(push: push, runtime: rt) }
            } label: {
                if setup.registering { Label { Text("Registering…") } icon: { ProgressView() } }
                else { Label("Register \(DeviceWords.this)", systemImage: "arrow.up.circle") }
            }
            .disabled(setup.registering)
            if let r = setup.registerOutcome {
                Label(r, systemImage: r.hasPrefix("Failed") ? "xmark.octagon" : "checkmark.circle")
                    .font(.footnote).foregroundStyle(r.hasPrefix("Failed") ? Color.red : Color.secondary)
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
        } header: { sectionHeader("\(DeviceWords.This)") } footer: {
            Text(PushRelay.isConfigured
                 ? "Registers with Vory's relay and publishes \(DeviceWords.this)'s device file to the Gateway. Content is encrypted with a key only \(DeviceWords.this) holds."
                 : "Publishes \(DeviceWords.this)'s device file to the Gateway.")
        }
    }

    @ViewBuilder private func addressStep(_ rt: GatewayRuntime) -> some View {
        Section {
            HStack {
                TextField("Address", text: $setup.gatewayURL, prompt: Text(verbatim: "https://hermes.example.com"))
                    .textInputAutocapitalization(.never).autocorrectionDisabled().keyboardType(.URL)
                if !setup.gatewayURL.isEmpty {
                    Button { withAnimation(.snappy) { setup.gatewayURL = "" } } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary) }
                        .buttonStyle(.plain).accessibilityLabel("Clear")
                }
            }
            Button { withAnimation(.snappy) { setup.gatewayURL = rt.connection.gateway.description } } label: { Label("Use \(DeviceWords.this)'s address", systemImage: DeviceWords.symbol) }
            if let inUse = setup.urlInUse, inUse != setup.gatewayURL {
                Text("The companion is using \(inUse) right now; installing again switches it.").font(.footnote).foregroundStyle(.secondary)
            }
            if !setup.gatewayURL.isEmpty, !setup.addressValid {
                Label("Enter a full address starting with http:// or https://.", systemImage: "exclamationmark.circle").font(.footnote).foregroundStyle(.orange)
            }
        } header: { sectionHeader("Address") } footer: {
            Text("The companion connects to exactly this address. Loopback (http://127.0.0.1:9119) works if the dashboard listens there; otherwise use \(DeviceWords.this)'s URL.")
        }
    }

    @ViewBuilder private func signInStep(_ rt: GatewayRuntime) -> some View {
        Section {
            switch setup.credential(for: rt) {
            case .sessionToken:
                Label("Uses this gateway's session token", systemImage: "checkmark.circle").foregroundStyle(.secondary)
            case .needsSignIn:
                Button { showCompanionSignIn = true } label: { Label("Sign in for the companion", systemImage: "person.badge.key") }
                Text("This gateway has its auth gate on, so the session token is refused. The companion gets its own sign-in — separate from \(DeviceWords.this)'s — and refreshes it itself.")
                    .font(.footnote).foregroundStyle(.secondary)
            case .ready(let provider):
                Label("Signed in\(provider.map { " via \($0)" } ?? "")\(setup.companionSecrets?.userId.map { " as \($0)" } ?? "")", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                Button { showCompanionSignIn = true } label: { Label("Sign in again", systemImage: "person.badge.key") }
                Button(role: .destructive) { withAnimation(.snappy) { setup.signOutCompanion(runtime: rt) } } label: { Label("Sign out the companion", systemImage: "person.slash") }
            }
        } header: { sectionHeader("Credentials") } footer: {
            Text("Same account as the dashboard. Written into the companion's config at install.")
        }
    }

    @ViewBuilder private func installStep(_ rt: GatewayRuntime) -> some View {
        Section {
            if setup.alreadyServing, !setup.installedOnGateway, let v = setup.installedVersion {
                Label("Already on the gateway: companion v\(v) is running and connected. Nothing to install and no restart; \(DeviceWords.this) only needs to register (step 1).", systemImage: "checkmark.circle.fill")
                    .font(.footnote).foregroundStyle(Color.readableGreen)
            }
            Button {
                Task { await setup.installOnGateway(runtime: rt) }
            } label: {
                if setup.installing { Label { Text("Installing…") } icon: { ProgressView() } }
                else { Label(setup.installedOnGateway || setup.alreadyServing ? "Install again" : "Install on the gateway", systemImage: "arrow.up.doc") }
            }
            .disabled(setup.installing)
            if !setup.installedFiles.isEmpty {
                InstalledFilesWindow(files: setup.installedFiles, finished: setup.installedOnGateway)
                    .listRowInsets(EdgeInsets(top: 8, leading: 12, bottom: 8, trailing: 12))
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
            if let e = setup.error { Label(e, systemImage: "xmark.octagon").font(.footnote).foregroundStyle(.red) }
            if setup.installedOnGateway, let at = setup.installedAt {
                Label("Installed at \(at.formatted(date: .omitted, time: .shortened)): companion v\(PushSetupModel.bundledPluginVersion), config and plugin are on the gateway and the plugin is enabled.", systemImage: "checkmark.circle.fill")
                    .font(.footnote).foregroundStyle(Color.readableGreen)
                    .transition(.scale(scale: 0.9).combined(with: .opacity))
            }
        } header: { sectionHeader("Install") } footer: {
            Text("Writes the companion, its config and the plugin to the Gateway and enables the plugin.")
        }
        if setup.restartCountdownEnd != nil || setup.restartPending {
            Section {
                RestartCountdownRows(setup: setup, runtime: rt)
            } header: { sectionHeader("Restart") }
        } else if !setup.installedOnGateway, !setup.alreadyServing {
            Section {
                Label("A Gateway restart finishes the install — you'll get a 90-second countdown. Running turns pause for a few seconds.", systemImage: "info.circle")
                    .font(.footnote).foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder private func startStep(_ rt: GatewayRuntime) -> some View {
        Section {
            CompanionStatusRows(setup: setup, runtime: rt, showInstall: false)
        } header: { sectionHeader("Companion") } footer: {
            Text("Heartbeat read from the Gateway every few seconds.")
        }
        Section {
            Label(setup.startAdvice, systemImage: setup.companionHealthy ? "checkmark.circle.fill" : "info.circle")
                .font(.footnote).foregroundStyle(setup.companionHealthy ? Color.green : Color.secondary)
                .contentTransition(.opacity)
            MaintenanceButtons(runtime: rt, compact: true, restartOnly: true)
        } footer: {
            Text("Restart once so Hermes loads the plugin, and after updates. Address and sign-in changes apply within seconds.")
        }
    }

    @ViewBuilder private func overviewStep(_ rt: GatewayRuntime) -> some View {
        let push = model.push
        Section {
            overviewRow("Gateway", symbol: "server.rack", ok: true,
                        primary: setup.gatewayURL.replacingOccurrences(of: "https://", with: "").replacingOccurrences(of: "http://", with: ""),
                        secondary: setup.credentialText(for: rt), fullValue: setup.gatewayURL)
            overviewRow("Companion", symbol: "puzzlepiece.extension", ok: setup.companionHealthy,
                        primary: setup.installedVersion.map { "v\($0)" } ?? "not installed",
                        secondary: setup.companionHealthy ? "connected · \(setup.heartbeat?.devices ?? 0) device\(setup.heartbeat?.devices == 1 ? "" : "s")" : "not connected")
            overviewRow("\(DeviceWords.This)", symbol: DeviceWords.symbol, ok: push.registeredAt != nil && push.authorization == .authorized,
                        primary: push.registeredAt != nil ? "registered" : "not registered",
                        secondary: "notifications \(PushSetupView.statusText(push.authorization).lowercased())")
        } header: { sectionHeader("Overview") }
        Section {
            Button {
                Task { await setup.sendTest(runtime: rt) }
            } label: {
                if case .waiting = setup.testPhase, let started = setup.testStartedAt {
                    Label {
                        VStack(alignment: .leading, spacing: 2) {
                            HStack { Text("Waiting for the notification…"); Text(timerInterval: started...Date.distantFuture, countsDown: false).monospacedDigit().foregroundStyle(.secondary) }
                            Text(setup.testStage).font(.footnote).foregroundStyle(.secondary).contentTransition(.opacity)
                        }
                    } icon: { ProgressView() }
                } else { Label("Send a test notification", systemImage: "bell.badge") }
            }
            .disabled(setup.testPhase.isWaiting || !setup.companionHealthy)
            if case .done(let ok, let text) = setup.testPhase {
                Label(text, systemImage: ok ? "checkmark.circle.fill" : "xmark.octagon").font(.footnote).foregroundStyle(ok ? Color.green : Color.red)
                    .transition(.scale(scale: 0.9).combined(with: .opacity))
            }
        } header: { sectionHeader("Test") } footer: {
            Text("One real notification: companion → relay → Apple → \(DeviceWords.this).")
        }
        Section {
            Button(role: .destructive) { confirmStartOver = true } label: {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Image(systemName: "arrow.counterclockwise").font(.footnote.weight(.medium))
                    Text("Start over").font(.footnote)
                }
            }
        }
        .listRowBackground(Color.clear)
    }

    private func overviewRow(_ title: String, symbol: String, ok: Bool, primary: String, secondary: String, fullValue: String? = nil) -> some View {
        HStack(spacing: 12) {
            Image(systemName: symbol).font(.body).foregroundStyle(.secondary).frame(width: 24)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.subheadline.weight(.medium))
                Text(secondary).font(.caption).foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            PeekableValue(text: primary, full: fullValue)
            Image(systemName: ok ? "checkmark.circle.fill" : "exclamationmark.circle.fill").foregroundStyle(ok ? Color.green : Color.orange)
        }
        .padding(.vertical, 2)
    }

    static func statusText(_ s: UNAuthorizationStatus) -> String {
        switch s { case .authorized: return "Allowed"; case .denied: return "Denied"; case .provisional: return "Provisional"; case .ephemeral: return "Ephemeral"; default: return "Not asked" }
    }
}

/// The companion update, in the voice of iOS Software Update: what is available, one Install Now
/// button, a progress bar with a stage and time remaining, then "Update Complete". A small console
/// underneath shows what the gateway is doing and fades out a few seconds after success.
struct CompanionUpdateRows: View {
    @Bindable var setup: PushSetupModel
    var runtime: GatewayRuntime

    private var version: String { PushSetupModel.bundledPluginVersion }
    private var sizeText: String { ByteCountFormatter.string(fromByteCount: Int64(PushSetupModel.bundledScriptSize), countStyle: .file) }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top, spacing: 14) {
                ZStack {
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .fill(LinearGradient(colors: [Color(red: 0.24, green: 0.77, blue: 0.93), Color(red: 0.04, green: 0.16, blue: 0.41)], startPoint: .topLeading, endPoint: .bottomTrailing))
                    Image(systemName: setup.updateOutcome?.ok == true ? "checkmark" : "puzzlepiece.extension.fill")
                        .font(.title2.weight(.semibold)).foregroundStyle(.white)
                        .contentTransition(.symbolEffect(.replace.downUp))
                }
                .frame(width: 60, height: 60)
                .symbolEffect(.bounce, value: setup.updateOutcome?.ok == true)
                VStack(alignment: .leading, spacing: 3) {
                    Text("Vory Companion \(version)").font(.headline)
                    Text("Vorantx · \(sizeText)").font(.subheadline).foregroundStyle(.secondary)
                    if !setup.updating, setup.updateOutcome == nil, !setup.updateNeedsRestart {
                        Text("Sends replies as notifications, \(DeviceWords.keepsActivity)and brings approval cards to \(DeviceWords.your) the moment a bot needs a yes.")
                            .font(.footnote).foregroundStyle(.secondary).padding(.top, 2)
                        if setup.runningCanSelfReload {
                            Label("Installs in place — no Gateway restart.", systemImage: "checkmark.circle")
                                .font(.footnote).foregroundStyle(.secondary).padding(.top, 2)
                        } else {
                            Label("Needs a Gateway restart to finish (running turns pause for a few seconds).", systemImage: "arrow.clockwise")
                                .font(.footnote).foregroundStyle(.orange).padding(.top, 2)
                        }
                    }
                }
                Spacer(minLength: 0)
            }

            if setup.updating || setup.showUpdateConsole || setup.updateOutcome != nil {
                VStack(alignment: .leading, spacing: 6) {
                    ProgressView(value: setup.updateProgress)
                        .progressViewStyle(.linear)
                        .scaleEffect(x: 1, y: 1.6, anchor: .center)
                        .tint(setup.updateOutcome?.ok == false ? .red : setup.updateProgress >= 1 ? .green : .accentColor)
                        .padding(.vertical, 4)
                    HStack {
                        Text(setup.updateStage).font(.footnote.weight(.medium))
                            .contentTransition(.opacity)
                        Spacer()
                        if let r = setup.updateRemaining { Text(r).font(.footnote).foregroundStyle(.secondary) }
                        else if setup.updateProgress >= 1 { Text("100%").font(.footnote.monospacedDigit()).foregroundStyle(.secondary) }
                    }
                    if let o = setup.updateOutcome, !o.ok {
                        Label(o.text, systemImage: "xmark.octagon").font(.footnote).foregroundStyle(.red).transition(.opacity)
                    }
                    if let o = setup.updateOutcome, o.ok {
                        Text("Vory Companion \(version) is installed and running.").font(.footnote).foregroundStyle(.secondary).transition(.opacity)
                    }
                }
                .transition(.opacity.combined(with: .move(edge: .top)))
            }

            if setup.showUpdateConsole {
                ScrollViewReader { proxy in
                    ScrollView {
                        VStack(alignment: .leading, spacing: 2) {
                            ForEach(Array(setup.updateConsole.enumerated()), id: \.offset) { i, line in
                                Text(line).font(.caption2.monospaced())
                                    .foregroundStyle(line.contains("FAILED") ? Color.red : Color.secondary)
                                    .id(i)
                                    .transition(.opacity.combined(with: .move(edge: .bottom)))
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(10)
                    }
                    .frame(height: 110)
                    .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.black.opacity(0.35)))
                    .onChange(of: setup.updateConsole.count) { _, n in withAnimation(.snappy) { proxy.scrollTo(max(0, n - 1), anchor: .bottom) } }
                }
                .transition(.opacity.combined(with: .scale(scale: 0.98, anchor: .top)))
            }

            if setup.updateNeedsRestart, !setup.updating {
                RestartCountdownRows(setup: setup, runtime: runtime)
            } else if !setup.updating, setup.updateOutcome?.ok != true {
                Button {
                    Task { await setup.updateCompanion(runtime: runtime) }
                } label: {
                    Text(setup.updateOutcome == nil ? "Install Now" : "Try Again")
                        .font(.body.weight(.semibold)).frame(maxWidth: .infinity).padding(.vertical, 6)
                }
                .buttonStyle(.borderedProminent)
                .buttonBorderShape(.roundedRectangle(radius: 12))
            }
        }
        .padding(.vertical, 6)
        .animation(.snappy, value: setup.updateConsole.count)
        .animation(.smooth, value: setup.showUpdateConsole)
        .animation(.smooth, value: setup.updating)
    }
}

/// "Restarting the gateway in 1:30" with Restart now / Later; or, after Later, the plain reminder
/// that nothing works until the restart happens.
struct RestartCountdownRows: View {
    @Bindable var setup: PushSetupModel
    var runtime: GatewayRuntime

    var body: some View {
        if setup.restarting {
            VStack(alignment: .leading, spacing: 8) {
                Label { Text("Restarting the gateway…") } icon: { ProgressView() }
                if let began = setup.restartBegan {
                    TimelineView(.periodic(from: .now, by: 1)) { ctx in
                        let secs = Int(ctx.date.timeIntervalSince(began))
                        VStack(alignment: .leading, spacing: 6) {
                            Text("\(setup.restartStage.isEmpty ? "Working" : setup.restartStage) · \(secs / 60):\(String(format: "%02d", secs % 60))")
                                .font(.footnote).foregroundStyle(.secondary)
                            if secs >= 60 {
                                Text("Still waiting. A gateway is usually back in under a minute; this gives it up to three. You can check now or finish later, and the files stay installed either way.")
                                    .font(.footnote).foregroundStyle(.orange)
                                HStack {
                                    Button { Task { await setup.checkRestartNow(runtime: runtime) } } label: { Text("Check now").frame(maxWidth: .infinity) }
                                        .buttonStyle(.bordered)
                                    Button { withAnimation(.snappy) { setup.stopWaitingForRestart() } } label: { Text("Finish later").frame(maxWidth: .infinity) }
                                        .buttonStyle(.bordered)
                                }
                            }
                        }
                    }
                }
            }
            .padding(.vertical, 4)
        } else if let end = setup.restartCountdownEnd {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Label("Restarting the Gateway in", systemImage: "arrow.clockwise.circle").font(.footnote.weight(.medium))
                    Spacer()
                    // The countdown itself pulls the trigger when it reaches zero.
                    // The tick that reaches zero renders with `now` past `end`; a range must
                    // not run backwards (it trapped: "Range requires lowerBound <= upperBound").
                    TimelineView(.periodic(from: .now, by: 1)) { ctx in
                        Text(timerInterval: min(ctx.date, end)...end, countsDown: true).font(.title3.monospacedDigit().weight(.semibold))
                            .onChange(of: ctx.date >= end) { _, due in if due { Task { await setup.restartNow(runtime: runtime) } } }
                    }
                }
                ProgressView(timerInterval: min(Date(), end)...end, countsDown: true) { EmptyView() } currentValueLabel: { EmptyView() }
                    .tint(.orange)
                HStack {
                    Button { Task { await setup.restartNow(runtime: runtime) } } label: { Text("Restart now").frame(maxWidth: .infinity) }
                        .buttonStyle(.borderedProminent)
                    Button { withAnimation(.snappy) { setup.restartLater() } } label: { Text("Later").frame(maxWidth: .infinity) }
                        .buttonStyle(.bordered)
                }
                Text("Running turns pause for a few seconds. Nothing works until the restart.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            .padding(.vertical, 4)
            .transition(.opacity.combined(with: .move(edge: .top)))
        } else if setup.restartPending {
            Label(setup.restartError.map { "The restart failed: \($0)" } ?? "Restart needed: the files are on the Gateway, but nothing works until it restarts.", systemImage: "exclamationmark.triangle.fill")
                .font(.footnote).foregroundStyle(.orange)
            Button { Task { await setup.restartNow(runtime: runtime) } } label: { Label("Restart Gateway now", systemImage: "arrow.clockwise") }
            Button { Task { await setup.checkRestartNow(runtime: runtime) } } label: { Label("Check now", systemImage: "waveform.path.ecg") }
            if setup.restartError?.localizedCaseInsensitiveContains("expired") == true || setup.restartError?.localizedCaseInsensitiveContains("401") == true {
                NavigationLink { GatewayFormView(existing: runtime.connection) } label: { Label("Sign in again", systemImage: "person.badge.key") }
                Text("If the gateway already came back, Settings › Companion will show it running; sign in again and the restart is not needed.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
        }
    }
}

/// One step: a floating glass card (step, title, and the bot's message bubble) with the step's
/// rows scrolling underneath it.
struct StepPage<Content: View, Header: View>: View {
    var step: PushSetupView.SetupStep
    var done: Bool
    @Binding var headerHeight: CGFloat
    @ViewBuilder var content: () -> Content
    @ViewBuilder var header: () -> Header

    var body: some View {
        Form { content() }
            #if os(macOS)
            .formStyle(.grouped)
            #endif
            .scrollContentBackground(.hidden)
            .listSectionSpacing(24)
            .contentMargins(.top, headerHeight + 10, for: .scrollContent)
            .contentMargins(.bottom, 120, for: .scrollContent)
            .overlay(alignment: .top) { top }
            #if os(macOS)
            // The wizard's column, as wide as a settings page.
            .frame(maxWidth: 700)
            .frame(maxWidth: .infinity)
            #endif
    }

    /// Vory and the step's title, over the form; the form scrolls under it.
    private var top: some View {
        VStack(spacing: 10) {
            header()
            Text(step.title).font(.title2.weight(.bold)).multilineTextAlignment(.center)
                .contentTransition(.numericText())
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 14).padding(.bottom, 12)
        .background(
            LinearGradient(colors: [Color(.systemGroupedBackground), Color(.systemGroupedBackground), Color(.systemGroupedBackground).opacity(0)], startPoint: .top, endPoint: .bottom)
                .ignoresSafeArea()
        )
        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { headerHeight = $0 }
    }
}

/// Section headings sit a touch higher off their cards than the default.
func sectionHeader(_ title: String) -> some View { Text(title).padding(.bottom, 6) }

/// A value that may not fit: shown from its start and cut with …; a tap floats the whole thing in
/// a small popover for a few seconds.
struct PeekableValue: View {
    var text: String
    var full: String?
    @State private var peek = false

    var body: some View {
        Text(text).font(.subheadline).foregroundStyle(.secondary).lineLimit(1).truncationMode(.tail)
            .onTapGesture { guard full != nil else { return }; peek = true; Task { try? await Task.sleep(for: .seconds(5)); peek = false } }
            .popover(isPresented: $peek, arrowEdge: .bottom) {
                Text(full ?? text).font(.footnote.monospaced()).textSelection(.enabled).fixedSize()
                    .padding(.horizontal, 12).padding(.vertical, 6)
                    .presentationCompactAdaptation(.popover)
            }
    }
}

/// The bot's line, typed out character by character with the bubble growing behind the words.
/// The files an install wrote, shown like a little code window; once the install is done it folds
/// down to one line and can be opened again.
struct InstalledFilesWindow: View {
    var files: [PushSetupModel.InstalledFile]
    var finished: Bool
    @State private var expanded = true

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button { withAnimation(.smooth(duration: 0.3)) { expanded.toggle() } } label: {
                HStack(spacing: 8) {
                    HStack(spacing: 5) {
                        ForEach([Color.red, Color.yellow, Color.green], id: \.self) { c in Circle().fill(c.opacity(0.8)).frame(width: 9, height: 9) }
                    }
                    Text(finished ? "Installed \(files.count) necessary files" : "Writing files…")
                        .font(.caption.weight(.medium)).foregroundStyle(.secondary)
                    Spacer()
                    Image(systemName: "chevron.down").font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
                        .rotationEffect(.degrees(expanded ? 0 : -90))
                }
                .padding(.horizontal, 12).padding(.vertical, 8)
            }
            .buttonStyle(.plain)
            VStack(alignment: .leading, spacing: 3) {
                ForEach(files, id: \.self) { f in
                    HStack(spacing: 8) {
                        Text("+").foregroundStyle(.green)
                        Text(f.name).foregroundStyle(.primary)
                        Spacer()
                        Text(ByteCountFormatter.string(fromByteCount: Int64(f.bytes), countStyle: .file)).foregroundStyle(.secondary)
                    }
                    .font(.caption.monospaced())
                    Text(f.directory).font(.caption2.monospaced()).foregroundStyle(.tertiary).padding(.leading, 18)
                }
            }
            .padding(.horizontal, 12).padding(.bottom, 10)
            .frame(maxHeight: expanded ? .infinity : 0, alignment: .top)
            .opacity(expanded ? 1 : 0)
            .clipped()
        }
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.black.opacity(0.35)))
        .onChange(of: finished) { _, now in if now { Task { try? await Task.sleep(for: .seconds(1.2)); withAnimation(.smooth(duration: 0.35)) { expanded = false } } } }
    }
}

/// Settings › Companion: everything about the plugin on the gateway in one place — whether it is
/// installed and running, Configure (the guided setup), Software Update, and Uninstall.
struct CompanionView: View {
    @Environment(AppModel.self) private var model
    @State private var setup = PushSetupModel()
    @State private var confirmReset = false
    @State private var resetting = false

    private var rt: GatewayRuntime? { model.runtime }

    var body: some View {
        SettingsList {
            SettingsHeaderSection(title: "Companion", symbol: "puzzlepiece.fill", color: .blue, description: "The plugin on your gateway that brings \(DeviceWords.companionBrings) to \(DeviceWords.this).")
            if let rt {
                let push = model.push
                Section {
                    NavigationLink { PushSetupView(setup: setup) } label: {
                        Label(setup.isCompleted(for: rt) ? "Configure" : "Configure the Companion", systemImage: "wand.and.stars")
                    }
                    NavigationLink { SoftwareUpdateView() } label: {
                        HStack {
                            Label("Software Update", systemImage: "arrow.down.circle")
                            Spacer(minLength: 8)
                            if setup.updateAvailable { CountBadge(1) }
                        }
                    }
                } footer: {
                    Text(setup.isCompleted(for: rt) ? "Configure walks through the setup again — address, sign-in, install, test." : "Guided setup: permission, address, sign-in, install, start, test.")
                }
                Section {
                    if setup.companionCheckedAt == nil {
                        Label { Text("Checking…") } icon: { ProgressView() }.foregroundStyle(.secondary)
                    } else {
                        CompanionStatusChecks(setup: setup)
                    }
                } header: { sectionHeader("Companion on the gateway") } footer: {
                    Text("A small plugin on your gateway. It sends replies as notifications, \(DeviceWords.keepsActivity)and gets approval cards to \(DeviceWords.your) the moment a bot needs a yes.")
                }
                Section {
                    LabeledContent("Notifications", value: PushSetupView.statusText(push.authorization))
                    if PushRelay.isConfigured {
                        LabeledContent("Push relay", value: push.relayRegisteredAt.map { "registered " + $0.formatted(date: .omitted, time: .shortened) } ?? "not registered")
                    }
                    LabeledContent("Device file on gateway", value: push.registeredAt.map { "published " + $0.formatted(date: .omitted, time: .shortened) } ?? "not published")
                } header: { sectionHeader("\(DeviceWords.This)") }
                if setup.isCompleted(for: rt) || setup.installedVersion != nil {
                    Section {
                        Button(role: .destructive) { confirmReset = true } label: {
                            if resetting { Label { Text("Uninstalling…") } icon: { ProgressView() } }
                            else { Label("Uninstall Companion", systemImage: "trash") }
                        }
                        .disabled(resetting)
                    } footer: {
                        Text("Stops the service and removes the plugin and its files from the gateway, and \(DeviceWords.this) forgets the setup. Installing again starts from scratch.")
                    }
                }
                Section {
                    NavigationLink { CompanionDiagnosticsView(setup: setup, push: push) } label: { Label("Diagnostics", systemImage: "stethoscope") }
                } footer: {
                    Text(DeviceWords.isMac ? "The last notification and the last push the Companion sent." : "The last notification, the Live Activity's tokens and log, and the last push the Companion sent.")
                }
            } else {
                Text("Connect a gateway first.").foregroundStyle(.secondary)
            }
        }
        .untitledPage()
        .listSectionSpacing(28)
        .animation(.smooth, value: setup.updateOutcome == nil)
        .alert("Uninstall the Companion?", isPresented: $confirmReset) {
            Button("Uninstall", role: .destructive) { Task { resetting = true; if let rt { await setup.uninstall(runtime: rt, model: model) }; resetting = false } }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("The plugin is disabled, its service is stopped and its files are deleted from the gateway (a bot runs the removal — approve it in the chat that opens). \(DeviceWords.CompanionBrings) stop until it is installed again.")
        }
        .task {
            guard let rt else { return }
            await setup.prepare(runtime: rt)
        }
        .reloadable { if let rt { await setup.checkCompanion(runtime: rt) } }
        // The badge on Settings › Notifications follows what this page finds.
        .onChange(of: setup.companionCheckedAt) { _, _ in model.companionUpdateAvailable = setup.updateAvailable }
    }
}

/// Just the two facts, as check marks: the plugin is on the gateway, and it is running.
struct CompanionStatusChecks: View {
    @Bindable var setup: PushSetupModel

    private var running: Bool {
        guard let hb = setup.heartbeat else { return false }
        return Date().timeIntervalSince(Date(timeIntervalSince1970: hb.updatedAt)) <= PushSetupModel.heartbeatSeconds * 6 && hb.connected == true
    }

    var body: some View {
        HStack {
            Text("Installed")
            Spacer()
            Image(systemName: setup.installedVersion != nil ? "checkmark.circle.fill" : "xmark.circle")
                .foregroundStyle(setup.installedVersion != nil ? .green : .secondary)
                .accessibilityLabel(setup.installedVersion != nil ? "Installed" : "Not installed")
        }
        HStack {
            Text("Running")
            Spacer()
            Image(systemName: running ? "checkmark.circle.fill" : (setup.heartbeat == nil ? "questionmark.circle" : "exclamationmark.triangle.fill"))
                .foregroundStyle(running ? .green : (setup.heartbeat == nil ? .secondary : .orange))
                .accessibilityLabel(running ? "Running" : "Not running")
        }
    }
}

/// Installed version, running version and heartbeat age, with the one action each state calls for.
struct CompanionStatusRows: View {
    @State private var checkShown = false
    @State private var justChecked = false
    @Bindable var setup: PushSetupModel
    var runtime: GatewayRuntime
    var showInstall = true

    var body: some View {
        let bundled = PushSetupModel.bundledPluginVersion
        let upToDate = setup.installedVersion == bundled && setup.installedScriptMatches
        Group {
            // Plain HStacks: `LabeledContent` with a `Label` value stretched each row to screen height.
            statusRow("Installed") {
                if let v = setup.installedVersion {
                    statusLabel(upToDate ? "v\(v) · matches this build" : v == bundled ? "v\(v) · files differ from this build" : "v\(v) · this build has v\(bundled)",
                                systemImage: upToDate ? "checkmark.circle.fill" : "arrow.up.circle.fill", color: upToDate ? .green : .orange)
                } else if setup.checkingCompanion {
                    ProgressView()
                } else {
                    statusLabel("Not installed", systemImage: "xmark.circle", color: .secondary)
                }
            }
            statusRow("Running") { runningLabel }
            if let hb = setup.heartbeat, hb.connected == false, let e = hb.error, e != "connecting…",
               !e.hasPrefix("reloading"), !setup.updating, !setup.showUpdateConsole {
                // (the update card narrates a reload itself)
                Text(e).font(.footnote).foregroundStyle(.orange)
            }
            if let t = setup.heartbeat?.transport, !t.isEmpty {
                Text("Connected via \(t)").font(.footnote).foregroundStyle(.secondary)
            }
            if let e = setup.companionCheckError { Text(e).font(.footnote).foregroundStyle(.red) }
            if showInstall, upToDate, setup.needsRestart, !setup.updating {
                Text(setup.runningOlderCode ? "The gateway process is still running the previous companion code. Restart it to load what is on disk."
                                            : "The gateway is still running the old companion. Restart it to load v\(bundled).")
                    .font(.footnote).foregroundStyle(.orange)
                MaintenanceButtons(runtime: runtime, compact: true, restartOnly: true)
            }
            if setup.updateAvailable || setup.updating || setup.showUpdateConsole || setup.updateOutcome != nil {
                CompanionUpdateRows(setup: setup, runtime: runtime)
                    .transition(.opacity)
            } else if showInstall, setup.installedVersion != nil {
                Button {
                    Task { await setup.installPlugin(runtime: runtime); await setup.checkCompanion(runtime: runtime) }
                } label: {
                    if setup.installingPlugin { Label { Text("Installing…") } icon: { ProgressView() } }
                    else { Label("Reinstall plugin v\(bundled)", systemImage: "arrow.clockwise.circle") }
                }
                .disabled(setup.installingPlugin)
                if let r = setup.pluginResult { Text(r).font(.footnote).foregroundStyle(r.hasPrefix("Installed") ? Color.secondary : Color.red) }
            }
            Button {
                Task {
                    // The check itself takes a blink; a moment of "Checking…" says it happened.
                    checkShown = true
                    async let done: () = setup.checkCompanion(runtime: runtime)
                    try? await Task.sleep(for: .milliseconds(900))
                    await done
                    checkShown = false
                    justChecked = true
                    try? await Task.sleep(for: .seconds(4))
                    justChecked = false
                }
            } label: {
                if setup.checkingCompanion || checkShown { Label { Text("Checking…") } icon: { ProgressView() } }
                else if justChecked { Label("Checked just now", systemImage: "checkmark.circle") }
                else { Label(setup.companionCheckedAt.map { "Check again (last \($0.formatted(date: .omitted, time: .shortened)))" } ?? "Check now", systemImage: "arrow.triangle.2.circlepath") }
            }
            .disabled(setup.checkingCompanion || checkShown)
        }
    }

    private func statusRow<V: View>(_ title: String, @ViewBuilder value: () -> V) -> some View {
        HStack(alignment: .top) {
            Text(title)
            Spacer(minLength: 12)
            value().multilineTextAlignment(.trailing)
        }
    }

    /// Icon and text that share a first line, whatever the text wraps to.
    private func statusLabel(_ text: String, systemImage: String, color: Color) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Image(systemName: systemImage).frame(width: 20)
            Text(text)
        }
        .foregroundStyle(color)
    }

    @ViewBuilder private var runningLabel: some View {
        if let hb = setup.heartbeat {
            let age = Date().timeIntervalSince(Date(timeIntervalSince1970: hb.updatedAt))
            let ago = Duration.seconds(max(0, age)).formatted(.units(width: .abbreviated, maximumUnitCount: 1))
            if age > PushSetupModel.heartbeatSeconds * 6 {
                statusLabel("Stopped · last seen \(ago) ago (v\(hb.version))", systemImage: "xmark.circle.fill", color: .red)
            } else if hb.connected == false {
                statusLabel("v\(hb.version)\(setup.runningOlderCode ? " (older code)" : "") · \(hb.error == "connecting…" ? "connecting…" : "not connected")", systemImage: "exclamationmark.triangle.fill", color: .orange)
            } else if setup.runningOlderCode {
                statusLabel("v\(hb.version) · connected, but running older code · \(ago) ago", systemImage: "arrow.clockwise.circle.fill", color: .orange)
            } else {
                statusLabel("v\(hb.version) · connected · \(hb.devices ?? 0) device\(hb.devices == 1 ? "" : "s") · \(ago) ago", systemImage: "checkmark.circle.fill", color: .green)
            }
        } else if setup.checkingCompanion {
            ProgressView()
        } else {
            statusLabel("No heartbeat", systemImage: "questionmark.circle", color: .secondary)
        }
    }
}

@MainActor
@Observable
final class PushSetupModel {
    var keyFileName: String?
    var keyData: Data?
    var keyID = ""
    var teamID = ""
    var gatewayURL = ""
    var companionSecrets: GatewaySecrets?
    var uploading = false
    var uploaded: [String] = []
    var uploadedAt: Date?
    var error: String?
    var asking = false
    /// Address the companion's config on the gateway names right now (read at open).
    var urlInUse: String?

    // MARK: Step state

    var registering = false
    var registerOutcome: String?
    var installing = false
    var installedAt: Date?
    var pluginInstalledAt: Date?

    var addressValid: Bool {
        guard let u = URL(string: gatewayURL.trimmingCharacters(in: .whitespaces)), let scheme = u.scheme?.lowercased(), let host = u.host, !host.isEmpty else { return false }
        return scheme == "http" || scheme == "https"
    }
    var installedOnGateway: Bool { uploadedAt != nil && pluginInstalledAt != nil && error == nil }
    /// This build's companion is already on the gateway, running and connected (installed from
    /// another phone, or before a reinstall of the app): nothing to upload, nothing to restart;
    /// this phone only registers itself.
    var alreadyServing: Bool { installedVersion == Self.bundledPluginVersion && installedScriptMatches && companionHealthy && !needsRestart }
    /// Heartbeat fresh, connected, and running exactly the code this build ships.
    var companionHealthy: Bool {
        guard let hb = heartbeat, hb.connected == true, !runningOlderCode, installedScriptMatches else { return false }
        return Date().timeIntervalSince(Date(timeIntervalSince1970: hb.updatedAt)) <= Self.heartbeatSeconds * 6
    }

    func appleReady(push: PushRegistrar) -> Bool {
        guard push.authorization == .authorized || push.authorization == .provisional, push.registeredAt != nil else { return false }
        if PushRelay.isConfigured { return push.relayRegisteredAt != nil }
        return keyData != nil && !keyID.isEmpty && teamID.count == 10
    }

    func registerPhone(push: PushRegistrar, runtime rt: GatewayRuntime) async {
        registering = true; registerOutcome = nil
        defer { registering = false }
        _ = await push.requestAuthorization()
        // The APNs token lands a moment after the permission; without it the publish is skipped.
        for _ in 0..<10 where push.deviceToken == nil { try? await Task.sleep(for: .milliseconds(500)) }
        await push.syncRegistration(runtime: rt)
        await push.registerWithRelay()
        if let e = push.lastError ?? push.relayError { registerOutcome = "Failed: \(e)" }
        else if push.registeredAt == nil { registerOutcome = "Failed: \(DeviceWords.the) has no push token yet. Try again in a moment." }
        else { registerOutcome = "Registered \(Date().formatted(date: .omitted, time: .shortened)): device file published to the gateway" + (PushRelay.isConfigured ? " and \(DeviceWords.the) registered with the relay." : ".") }
    }

    func signOutCompanion(runtime rt: GatewayRuntime) {
        companionSecrets = nil
        rememberCompanionSecrets(for: rt)
    }

    /// Config, companion and plugin in one go: the wizard's single "install" action.
    func installOnGateway(runtime rt: GatewayRuntime) async {
        installing = true; defer { installing = false }
        installedAt = nil; pluginInstalledAt = nil; pluginResult = nil; installedFiles = []
        // A companion already running (from another phone) reloads new files by itself
        // (1.0.12 and later); it must not be told to restart the gateway for nothing.
        let selfReloads = runningCanSelfReload && heartbeat?.connected == true
        await upload(runtime: rt)
        guard error == nil else { return }
        await installPlugin(runtime: rt)
        guard pluginResult?.hasPrefix("Installed") == true else { error = pluginResult ?? "The plugin could not be installed."; return }
        pluginInstalledAt = Date(); installedAt = Date(); urlInUse = gatewayURL
        if selfReloads {
            for _ in 0..<10 {
                try? await Task.sleep(for: .seconds(3))
                await checkCompanion(runtime: rt)
                if companionHealthy { return }   // picked the files up in place; no restart
            }
        }
        scheduleRestartCountdown(runtime: rt)
    }
    struct InstalledFile: Hashable {
        var name: String
        var directory: String
        var bytes: Int
    }
    var installedFiles: [InstalledFile] = []

    var startAdvice: String {
        if companionHealthy { return "Connected. Continue to the overview." }
        if restartPending { return "Installed, but the gateway has not been restarted yet: nothing works until it is. Restart it below." }
        guard let hb = heartbeat else { return installedVersion == nil ? "Install the plugin first (step 4)." : "No heartbeat yet: restart the gateway so Hermes loads the plugin, then wait a few seconds." }
        if Date().timeIntervalSince(Date(timeIntervalSince1970: hb.updatedAt)) > Self.heartbeatSeconds * 6 { return "The companion stopped writing heartbeats. Restart the gateway." }
        if runningOlderCode || !installedScriptMatches { return "The gateway is running an older companion than the one installed. Restart it." }
        if hb.connected == false, let e = hb.error, e != "connecting…" { return "The companion is up but cannot reach the gateway: \(e). Go back and fix the address or the sign-in, then install again; it switches within ten seconds, no restart needed." }
        return "Connecting…"
    }
    var runningSummary: String {
        guard let hb = heartbeat else { return "no heartbeat" }
        if companionHealthy { return "v\(hb.version) · connected · \(hb.devices ?? 0) device\(hb.devices == 1 ? "" : "s")" }
        return "v\(hb.version) · " + (hb.connected == true ? "connected (restart pending)" : "not connected")
    }
    func credentialText(for rt: GatewayRuntime) -> String {
        switch credential(for: rt) {
        case .sessionToken: return "gateway session token"
        case .needsSignIn: return "not signed in"
        case .ready(let p): return "signed in" + (p.map { " via \($0)" } ?? "") + (companionSecrets?.userId.map { " as \($0)" } ?? "")
        }
    }

    private static func completedKey(_ rt: GatewayRuntime) -> String { "pushSetupCompleted." + rt.connection.id.uuidString }
    func isCompleted(for rt: GatewayRuntime) -> Bool { UserDefaults.standard.bool(forKey: Self.completedKey(rt)) }
    func markCompleted(for rt: GatewayRuntime) { UserDefaults.standard.set(true, forKey: Self.completedKey(rt)) }

    /// Removes the companion for good: the plugin is disabled, this phone's device file is
    /// withdrawn, Hermes is asked to run `install.sh --uninstall` (service, plugin folder and the
    /// push folder go — an approval card in a new chat, like the install), and the phone forgets
    /// its setup. The next Configure is a clean install.
    func uninstall(runtime rt: GatewayRuntime, model: AppModel) async {
        let _: JSONValue? = try? await rt.api.send("POST", "/api/dashboard/agent-plugins/vory-push/disable", body: EmptyBody())
        await model.push.removeRegistration(runtime: rt)
        let cmd = installCommand(for: rt) + " --uninstall"
        if let chat = try? await rt.newChat() {
            await chat.send("Run this exact command in the terminal and show me its full output: `\(cmd)`. It stops the Vory companion service and deletes its files. If it fails, tell me the error verbatim.")
            model.pendingRoute = PendingRoute(connectionID: rt.connection.id, storedSessionID: chat.storedID, profile: rt.selectedProfile)
            model.selectedTab = .chats
        }
        startOver(runtime: rt)
        heartbeat = nil; installedVersion = nil; installedScriptMatches = false
        await checkCompanion(runtime: rt)
    }

    func startOver(runtime rt: GatewayRuntime) {
        gatewayURL = ""; urlInUse = nil
        signOutCompanion(runtime: rt)
        uploaded = []; uploadedAt = nil; installedAt = nil; pluginInstalledAt = nil; pluginResult = nil; error = nil
        testPhase = .idle; registerOutcome = nil
        UserDefaults.standard.removeObject(forKey: Self.completedKey(rt))
    }

    // MARK: Gateway restart (countdown)

    /// When the automatic restart fires; nil when no countdown is running.
    var restartCountdownEnd: Date?
    /// Files are on the gateway but it has not been restarted: notifications will not work until it is.
    var restartPending = false
    var restarting = false
    var restartError: String?
    /// What the restart wait is doing right now, and since when: the page says so instead of
    /// spinning (a tester sat on a bare "Restarting the gateway…" and reported a hang).
    var restartStage = ""
    var restartBegan: Date?
    private var restartWait: Task<Void, Never>?
    /// Stop waiting and leave the page usable; the restart may still land, and Check now says so.
    func stopWaitingForRestart() { restartWait?.cancel(); restartWait = nil }
    private var restartTask: Task<Void, Never>?

    func scheduleRestartCountdown(runtime rt: GatewayRuntime, seconds: TimeInterval = 90) {
        restartPending = true
        restartCountdownEnd = Date().addingTimeInterval(seconds)
        restartTask?.cancel()
        restartTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(seconds))
            guard !Task.isCancelled, let self, self.restartCountdownEnd != nil else { return }
            await self.restartNow(runtime: rt)
        }
    }

    func restartLater() {
        restartTask?.cancel(); restartTask = nil
        restartCountdownEnd = nil
        // restartPending stays true: the cards keep saying so until it happens.
    }

    func restartNow(runtime rt: GatewayRuntime) async {
        restartTask?.cancel(); restartTask = nil
        restartCountdownEnd = nil
        guard !restarting else { return }
        // The wait runs as its own task so the page can abandon it (Finish later) without the
        // button's task being torn down under it.
        let wait = Task { await self.waitForRestart(runtime: rt) }
        restartWait = wait
        await wait.value
    }

    private func waitForRestart(runtime rt: GatewayRuntime) async {
        restarting = true; restartBegan = Date(); restartStage = "Asking the gateway to restart"
        defer { restarting = false; restartBegan = nil; restartStage = "" }
        restartError = nil
        if updateNeedsRestart {
            await finishUpdateAfterRestart(runtime: rt)
            return
        }
        // Another maintenance action still tailing its log would make the restart a silent no-op.
        for _ in 0..<20 where rt.maintenance.isBusy { try? await Task.sleep(for: .seconds(1)) }
        // The restart action rarely reports back: the dashboard it reports through is the thing
        // restarting (a tester sat on a spinner for nine minutes). So the action runs on the
        // side, and what ends the wait is the companion's first heartbeat written AFTER the
        // restart began; failing that, the action's own short deadline says what happened.
        let began = Date().timeIntervalSince1970
        _restartAskedAt = Date()
        let profile = heartbeat?.profile == "default" ? nil : heartbeat?.profile
        var action = Task { await rt.maintenance.restartGateway(runtime: rt, profile: profile) }
        var back = false
        var refreshed = false
        restartStage = "Waiting for the companion to report back after the restart"
        for _ in 0..<40 {   // up to two minutes
            try? await Task.sleep(for: .seconds(3))
            if Task.isCancelled { restartStage = ""; return }
            if case .failed(let why) = rt.maintenance.phase {
                // The gateway said the session had expired (a tester hit this seven minutes after
                // a successful install): renew it once and go again before asking for a sign-in.
                if !refreshed, why.localizedCaseInsensitiveContains("expired") || why.localizedCaseInsensitiveContains("401") {
                    refreshed = true
                    if (try? await rt.refreshSession()) != nil {
                        action = Task { await rt.maintenance.restartGateway(runtime: rt, profile: profile) }
                        continue
                    }
                }
                break
            }
            await checkCompanion(runtime: rt)
            if companionHealthy, let hb = heartbeat, hb.updatedAt > began + 2 { back = true; break }
        }
        if !back, case .failed = rt.maintenance.phase {
            // The call failed, but the restart may still have gone through (the session dies
            // with the old process): give the companion a minute to report back.
            restartStage = "The restart call failed; checking whether the gateway came back anyway"
            for _ in 0..<20 {
                try? await Task.sleep(for: .seconds(3))
                if Task.isCancelled { restartStage = ""; return }
                await checkCompanion(runtime: rt)
                if companionHealthy, let hb = heartbeat, hb.updatedAt > began + 2 { back = true; break }
            }
        }
        if back {
            rt.maintenance.finishEarly("Restarting gateway: back up")
            await rt.reconnectNow()
        } else {
            // The action's own deadline usually ends it; a dashboard that never answers must
            // not keep the page on a spinner, so this is the last stretch the wait allows.
            restartStage = "Giving the gateway a last half minute"
            let lastCall = Date().addingTimeInterval(30)
            while Date() < lastCall, case .running = rt.maintenance.phase {
                try? await Task.sleep(for: .seconds(1))
                if Task.isCancelled { restartStage = ""; return }
            }
            if case .running = rt.maintenance.phase {
                action.cancel()
                rt.maintenance.finishEarly("Restarting gateway: no answer yet")
                restartError = "The gateway has not reported back. It may still be restarting: Check now looks again, or finish later and come back."
                return
            }
        }
        // The last word is the companion's: if it is reporting in now, the restart happened,
        // whatever the restart call said about itself (a tester saw "did not report completion
        // in time" under a companion connected five seconds earlier).
        await checkCompanion(runtime: rt)
        if companionHealthy, let hb = heartbeat, Date().timeIntervalSince1970 - hb.updatedAt < 90 {
            if case .failed = rt.maintenance.phase { rt.maintenance.finishEarly("Restarting gateway: back up") }
            restartError = nil
            restartPending = false
            return
        }
        if case .failed(let why) = rt.maintenance.phase { restartError = why; return }
        restartPending = false
    }

    /// Check now: one look at the companion; if it is back since the restart began, finish.
    func checkRestartNow(runtime rt: GatewayRuntime) async {
        await checkCompanion(runtime: rt)
        if companionHealthy, let hb = heartbeat, let began = restartBegan ?? lastRestartAsked, hb.updatedAt > began.timeIntervalSince1970 + 2 {
            stopWaitingForRestart()
            rt.maintenance.finishEarly("Restarting gateway: back up")
            await rt.reconnectNow()
            restartError = nil
            restartPending = false
        } else {
            restartError = "Not back yet. The companion has not reported since the restart began."
        }
    }
    private var lastRestartAsked: Date? { restartBegan ?? restartAskedAt }
    private var restartAskedAt: Date? { _restartAskedAt }
    private var _restartAskedAt: Date?

    // MARK: Companion update

    /// A newer companion is in this build than on the gateway (version or file contents).
    var updateAvailable: Bool { installedVersion != nil && !(installedVersion == Self.bundledPluginVersion && installedScriptMatches) }
    /// Companions from 1.0.12 on pick up a new file by themselves; older ones need the gateway restarted.
    var runningCanSelfReload: Bool {
        guard let v = heartbeat?.version else { return false }
        let a = v.split(separator: ".").compactMap { Int($0) }, b = [1, 0, 12]
        for i in 0..<max(a.count, b.count) {
            let x = i < a.count ? a[i] : 0, y = i < b.count ? b[i] : 0
            if x != y { return x > y }
        }
        return true
    }
    var updating = false
    /// 0…1 across upload, enable, restart and the first healthy heartbeat.
    var updateProgress: Double = 0
    var updateStage = ""
    /// The console under the bar: one line per thing done, the gateway's own restart output included.
    var updateConsole: [String] = []
    var updateOutcome: (ok: Bool, text: String)?
    var showUpdateConsole = false
    /// Files and enable are done; the gateway restart (countdown or manual) finishes it.
    var updateNeedsRestart = false
    /// Size of the companion this build ships, for the update card.
    static let bundledScriptSize: Int = {
        guard let url = Bundle.main.url(forResource: "hermes_push", withExtension: "py", subdirectory: "hermes-push") ?? Bundle.main.url(forResource: "hermes_push", withExtension: "py"),
              let n = try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int else { return 0 }
        return n
    }()
    /// Rough "time remaining" for the card, from the stage.
    var updateRemaining: String? {
        switch updateStage {
        case "Preparing Update…", "Installing…": return "About 1 minute remaining"
        case "Restart to finish": return "Waiting for the restart"
        case "Restarting Gateway…": return "About 1 minute remaining"
        case "Verifying…": return "Less than a minute remaining"
        default: return nil
        }
    }

    private func console(_ line: String) {
        let stamp = Date().formatted(.dateTime.hour().minute().second())
        updateConsole.append("\(stamp)  \(line)")
        if updateConsole.count > 40 { updateConsole.removeFirst(updateConsole.count - 40) }
    }

    /// Upload the plugin files, enable, restart the gateway and wait for the new heartbeat, reporting
    /// each step under a progress bar. The console stays for a moment after success, then goes away.
    func updateCompanion(runtime rt: GatewayRuntime) async {
        guard !updating else { return }
        updating = true; updateProgress = 0; updateConsole = []; updateOutcome = nil; showUpdateConsole = true
        defer { updating = false }
        let target = Self.bundledPluginVersion
        guard let home = rt.profileHome else { updateOutcome = (false, "The gateway did not report its home folder."); return }
        let base = "\(home)/plugins/vory-push"
        guard let script = Bundle.main.url(forResource: "hermes_push", withExtension: "py", subdirectory: "hermes-push") ?? Bundle.main.url(forResource: "hermes_push", withExtension: "py"),
              let manifest = Bundle.main.url(forResource: "plugin", withExtension: "yaml", subdirectory: "hermes-push/plugin") ?? Bundle.main.url(forResource: "plugin", withExtension: "yaml"),
              let entry = Bundle.main.url(forResource: "__init__", withExtension: "py", subdirectory: "hermes-push/plugin") ?? Bundle.main.url(forResource: "__init__", withExtension: "py"),
              let s = try? Data(contentsOf: script), let m = try? Data(contentsOf: manifest), let e = try? Data(contentsOf: entry) else {
            updateOutcome = (false, "The plugin files are missing from this build."); return
        }
        let files = [("hermes_push.py", s, "text/x-python"), ("plugin.yaml", m, "text/yaml"), ("__init__.py", e, "text/x-python")]
        let total = Double(files.count + 3)   // files + enable + restart + heartbeat
        var done = 0.0
        updateStage = "Preparing Update…"
        console("Updating companion \(installedVersion.map { "v\($0)" } ?? "?") → v\(target)")
        for (name, data, mime) in files {
            do {
                let body: JSONValue = ["path": .string("\(base)/\(name)"), "data_url": .string("data:\(mime);base64," + data.base64EncodedString()), "overwrite": true]
                let _: ManagedUploadResult = try await rt.api.send("POST", "/api/files/upload", json: body)
                console("wrote \(base)/\(name) (\(data.count) bytes)")
            } catch {
                console("FAILED \(name): \(error.localizedDescription)")
                updateOutcome = (false, "Could not write \(name): \(error.localizedDescription)"); return
            }
            done += 1; withAnimation(.snappy) { updateProgress = done / total }
        }
        updateStage = "Installing…"
        do {
            let r: JSONValue = try await rt.api.send("POST", "/api/dashboard/agent-plugins/vory-push/enable", body: EmptyBody())
            if r["ok"]?.boolValue == false { let msg = r["error"]?.stringValue ?? "Hermes refused to enable the plugin."; console("FAILED enable: \(msg)"); updateOutcome = (false, msg); return }
            console("plugin vory-push enabled")
        } catch { console("FAILED enable: \(error.localizedDescription)"); updateOutcome = (false, error.localizedDescription); return }
        done += 1; withAnimation(.snappy) { updateProgress = done / total }

        // Companions from 1.0.12 on pick new code up by themselves; give that half a minute first.
        updateStage = "Reloading…"
        console("files in place; waiting for the companion to reload itself")
        for _ in 0..<10 {
            try? await Task.sleep(for: .seconds(3))
            await checkCompanion(runtime: rt)
            if let hb = heartbeat, hb.version == target, !runningOlderCode {
                console("companion v\(target) reloaded in place (no restart needed)")
                withAnimation(.snappy) { updateProgress = 5 / total }
                updateStage = "Verifying…"
                for _ in 0..<10 where !companionHealthy { try? await Task.sleep(for: .seconds(3)); await checkCompanion(runtime: rt) }
                guard companionHealthy else { break }
                withAnimation(.snappy) { updateProgress = 1 }
                updateStage = "Update Complete"
                console("companion v\(target) running and connected")
                updateOutcome = (true, "Updated to v\(target). The companion is running and connected.")
                try? await Task.sleep(for: .seconds(4))
                withAnimation(.smooth(duration: 0.7)) { showUpdateConsole = false; updateOutcome = nil; updateProgress = 0; updateStage = "" }
                return
            }
        }
        updateNeedsRestart = true
        updateStage = "Restart to finish"
        console("the running companion did not pick the files up; a restart of the \(heartbeat?.profile ?? "default") gateway will")
        scheduleRestartCountdown(runtime: rt)
    }

    /// The second half of an update: restart the gateway and wait for the new companion's heartbeat.
    func finishUpdateAfterRestart(runtime rt: GatewayRuntime) async {
        let target = Self.bundledPluginVersion
        let total = 6.0
        var done = 4.0
        updating = true; showUpdateConsole = true
        defer { updating = false }
        updateStage = "Restarting Gateway…"
        console("POST /api/gateway/restart (profile \(heartbeat?.profile ?? "default"))")
        let mirror = Task { [weak self] in
            // Mirror the gateway's own restart output into the console as it arrives.
            var seen = 0
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(500))
                let log = rt.maintenance.actionLog
                if log.count > seen { for line in log[seen...] { self?.console("gateway: \(line)") }; seen = log.count }
            }
        }
        await rt.maintenance.restartGateway(runtime: rt, profile: heartbeat?.profile == "default" ? nil : heartbeat?.profile)
        mirror.cancel()
        if case .failed(let why) = rt.maintenance.phase { console("FAILED restart: \(why)"); updateOutcome = (false, "Restart failed: \(why)"); return }
        console("gateway restart finished")
        restartPending = false; updateNeedsRestart = false
        done += 1; withAnimation(.snappy) { updateProgress = done / total }

        updateStage = "Verifying…"
        let deadline = Date().addingTimeInterval(120)
        var announced = ""
        while Date() < deadline {
            try? await Task.sleep(for: .seconds(3))
            await checkCompanion(runtime: rt)
            if let hb = heartbeat {
                let line = "heartbeat v\(hb.version) · \(hb.connected == true ? "connected" : (hb.error ?? "not connected"))"
                if line != announced { console(line); announced = line }
            }
            if companionHealthy, installedVersion == target { break }
        }
        guard companionHealthy, installedVersion == target else {
            updateOutcome = (false, "The files are on the gateway but the new companion did not report in within two minutes. Check the status above and restart the gateway again.")
            return
        }
        withAnimation(.snappy) { updateProgress = 1 }
        updateStage = "Update Complete"
        console("companion v\(target) running and connected")
        updateOutcome = (true, "Updated to v\(target). The companion is running and connected.")
        try? await Task.sleep(for: .seconds(4))
        withAnimation(.smooth(duration: 0.7)) { showUpdateConsole = false; updateOutcome = nil; updateProgress = 0; updateStage = "" }
    }

    // MARK: Test notification

    enum TestPhase {
        case idle, waiting, done(ok: Bool, text: String)
        var isWaiting: Bool { if case .waiting = self { return true }; return false }
    }
    var testPhase: TestPhase = .idle
    var testStartedAt: Date?
    var testPassed: Bool { if case .done(let ok, _) = testPhase { return ok }; return false }
    /// What the test is doing right now, under the spinner.
    var testStage = ""
    /// Nonces of pushes iOS presented while the app was in front (from the notification delegate).
    static var presentedNonces: Set<String> = []
    /// When iOS last presented any Vory push in the foreground.
    static var lastPresentedAt: Date?
    /// What the device file on the gateway says about this phone's Live Activity (read with the heartbeat).
    var deviceFileLiveActivity: String?
    /// The notification service extension's last breadcrumb ("decrypted OK", "no relay credentials…").
    var extensionBreadcrumb: String? {
        guard let d = Keychain.get(account: "push.nse.last"), let s = String(data: d, encoding: .utf8) else { return nil }
        return s
    }

    /// Drops a request file next to the companion's config; the companion sends one push to every
    /// registered phone and records the nonce in its heartbeat. Received = the full chain works.
    func sendTest(runtime rt: GatewayRuntime) async {
        testPhase = .waiting; testStartedAt = Date(); testStage = "Handing the request to the gateway…"
        let nonce = UUID().uuidString.lowercased()
        let body: JSONValue = ["nonce": .string(nonce), "requested_at": .number(Date().timeIntervalSince1970)]
        do {
            let data = try JSONEncoder().encode(body)
            let up: JSONValue = ["path": .string("\(pushDir(for: rt))/test-request.json"), "data_url": .string("data:application/json;base64," + data.base64EncodedString()), "overwrite": true]
            let _: ManagedUploadResult = try await rt.api.send("POST", "/api/files/upload", json: up)
        } catch { testPhase = .done(ok: false, text: "Could not hand the request to the gateway: \(error.localizedDescription)"); return }
        let started = Date()
        testStage = "Waiting for the companion to pick it up (it looks every 3 s)…"
        var sentTo: Int?
        var detail = ""
        Self.presentedNonces.remove(nonce); Self.lastPresentedAt = nil
        while Date().timeIntervalSince(started) < 60 {
            try? await Task.sleep(for: .seconds(1))
            let secs = Int(Date().timeIntervalSince(started))
            var decrypted = Self.presentedNonces.contains(nonce)
            var arrived = decrypted || (Self.lastPresentedAt.map { $0 >= started } ?? false)
            if !decrypted {
                let seen = await Self.testDelivered(nonce: nonce, since: started)
                arrived = arrived || seen.arrived
                decrypted = decrypted || seen.decrypted
            }
            if arrived {
                testPhase = decrypted
                    ? .done(ok: true, text: "Received on \(DeviceWords.this) \(secs)s after asking, content decrypted. The whole chain works.")
                    : .done(ok: true, text: "Received on \(DeviceWords.this) \(secs)s after asking — but its content could not be decrypted, so it showed the placeholder text. Register \(DeviceWords.this) again (step 1) so the relay key matches, then test once more.")
                return
            }
            if sentTo == nil, secs % 2 == 0 {
                await checkCompanion(runtime: rt)
                if heartbeat?.lastTestNonce == nonce {
                    sentTo = heartbeat?.lastTestDevices ?? 0
                    detail = heartbeat?.lastTestDetail ?? ""
                    testStage = sentTo == 0 ? "The companion found no device to send to" : "Sent to Apple by the companion · waiting for it to arrive…"
                }
            }
        }
        let relayNote = detail.isEmpty ? "" : (detail.contains("1010") ? " Cloudflare blocked the companion's request to the relay (error 1010, browser check) — update the companion; newer ones identify themselves."
                                                                        : " The relay answered: \(detail).")
        if let n = sentTo {
            testPhase = .done(ok: false, text: n == 0 ? "The companion tried, but the relay refused the push for \(DeviceWords.this).\(relayNote)\(detail.contains("1010") ? "" : " If it says \"unknown device\", register \(DeviceWords.this) again (step 1).")"
                                                     : "The companion sent it to \(n) device\(n == 1 ? "" : "s") but nothing arrived here within a minute.\(relayNote) Check that notifications are allowed for Vory, and the relay registration in step 1.")
        } else {
            testPhase = .done(ok: false, text: "The companion never picked the request up within a minute. Is it connected (step 5)?")
        }
    }

    /// Anything Vory received since the request counts as arrived; the nonce inside means the
    /// notification service extension also managed to decrypt it.
    private static func testDelivered(nonce: String, since: Date) async -> (arrived: Bool, decrypted: Bool) {
        let delivered = await UNUserNotificationCenter.current().deliveredNotifications()
        var arrived = false, decrypted = false
        for n in delivered {
            let info = n.request.content.userInfo
            if (((info["hermes"] as? [String: Any])?["nonce"] as? String) == nonce) { arrived = true; decrypted = true; break }
            if n.date >= since.addingTimeInterval(-2), info["enc"] != nil || info["hermes"] != nil { arrived = true }
        }
        return (arrived, decrypted)
    }

    enum Credential { case sessionToken, needsSignIn, ready(provider: String?) }

    func credential(for rt: GatewayRuntime) -> Credential {
        if rt.connection.authMode == .sessionToken { return .sessionToken }
        if let s = companionSecrets, s.accessToken != nil { return .ready(provider: s.provider) }
        return .needsSignIn
    }

    var installingPlugin = false
    var pluginResult: String?

    // MARK: Remembered per connection

    private static func secretsAccount(_ rt: GatewayRuntime) -> String { "companion-secrets." + rt.connection.id.uuidString }

    func restore(for rt: GatewayRuntime) {
        if companionSecrets == nil { companionSecrets = Keychain.getCodable(GatewaySecrets.self, account: Self.secretsAccount(rt)) }
    }

    /// Everything a screen needs before it shows: remembered sign-in, the address in use, the heartbeat.
    func prepare(runtime rt: GatewayRuntime) async {
        companionCheckedAt = nil   // "Checking…" until this visit's read-back lands
        restore(for: rt)
        // Prefilled with the address the companion uses right now; the phone's own URL before the first install.
        if gatewayURL.isEmpty, let inUse = await gatewayURLFromConfig(runtime: rt) { gatewayURL = inUse }
        if gatewayURL.isEmpty { gatewayURL = rt.connection.gateway.description }
        await checkCompanion(runtime: rt)
    }

    /// The URL in the config already on the gateway, so a reinstalled app picks up where it left off.
    func gatewayURLFromConfig(runtime rt: GatewayRuntime) async -> String? {
        guard let text = try? await readManagedText(rt, path: "\(pushDir(for: rt))/hermes-push.conf") else { return nil }
        for line in text.split(separator: "\n") where line.hasPrefix("HERMES_PUSH_GATEWAY_URL=") {
            let v = line.dropFirst("HERMES_PUSH_GATEWAY_URL=".count).trimmingCharacters(in: .whitespaces)
            urlInUse = v.isEmpty ? nil : v
            return urlInUse
        }
        return nil
    }

    func rememberCompanionSecrets(for rt: GatewayRuntime) {
        guard let s = companionSecrets else { Keychain.delete(account: Self.secretsAccount(rt)); return }
        try? Keychain.setCodable(s, account: Self.secretsAccount(rt))
    }

    // MARK: Companion status

    /// What the companion writes to `<push dir>/status.json` on every discovery poll.
    struct CompanionHeartbeat: Decodable {
        var version: String
        var scriptSha256: String?
        var profile: String?
        var updatedAt: Double
        var connected: Bool?
        var transport: String?
        var attached: Int?
        var devices: Int?
        var error: String?
        var lastTestNonce: String?
        var lastTestDevices: Int?
        var lastTestDetail: String?
        var lastLaEvent: String?
        var lastLaOk: Bool?
        var lastLaResponse: String?
        var lastLaAt: Double?
        enum CodingKeys: String, CodingKey {
            case version, scriptSha256 = "script_sha256", profile, updatedAt = "updated_at", connected, transport, attached, devices, error
            case lastTestNonce = "last_test_nonce", lastTestDevices = "last_test_devices", lastTestDetail = "last_test_detail"
            case lastLaEvent = "last_la_event", lastLaOk = "last_la_ok", lastLaResponse = "last_la_response", lastLaAt = "last_la_at"
        }
    }

    static let heartbeatSeconds: TimeInterval = 10
    /// Version in the plugin manifest this build ships.
    static let bundledPluginVersion: String = {
        guard let url = Bundle.main.url(forResource: "plugin", withExtension: "yaml", subdirectory: "hermes-push/plugin") ?? Bundle.main.url(forResource: "plugin", withExtension: "yaml"),
              let text = try? String(contentsOf: url, encoding: .utf8),
              let m = text.firstMatch(of: /version: "([^"]+)"/) else { return "?" }
        return String(m.1)
    }()

    /// SHA-256 of the companion script this build ships.
    static let bundledScriptSHA256: String = {
        guard let url = Bundle.main.url(forResource: "hermes_push", withExtension: "py", subdirectory: "hermes-push") ?? Bundle.main.url(forResource: "hermes_push", withExtension: "py"),
              let data = try? Data(contentsOf: url) else { return "" }
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }()

    var checkingCompanion = false
    /// Version of the plugin manifest on the gateway; nil when it is not installed.
    var installedVersion: String?
    /// True when the script on the gateway's disk is byte-for-byte the one this build ships.
    var installedScriptMatches = false
    /// The gateway process is executing older code than what is on its disk / in this build.
    var runningOlderCode: Bool { heartbeat?.scriptSha256.map { $0 != Self.bundledScriptSHA256 } ?? false }
    var heartbeat: CompanionHeartbeat?
    var companionCheckError: String?
    var companionCheckedAt: Date?

    /// A newer plugin is on disk than the one the gateway process is running (or that one never wrote a heartbeat).
    var needsRestart: Bool {
        guard let installed = installedVersion else { return false }
        guard let hb = heartbeat else { return true }
        return hb.version != installed || runningOlderCode
    }

    func checkCompanion(runtime rt: GatewayRuntime) async {
        checkingCompanion = true; defer { checkingCompanion = false }
        companionCheckError = nil
        guard let home = rt.profileHome else { companionCheckError = "The gateway did not report its home folder."; return }
        do {
            let manifest = try await readManagedText(rt, path: "\(home)/plugins/vory-push/plugin.yaml")
            installedVersion = manifest.map { $0.firstMatch(of: /version: "([^"]+)"/).map { String($0.1) } ?? "?" }
            if let push = rt.pushRegistrar as? PushRegistrar, let dev = try await readManagedText(rt, path: "\(pushDir(for: rt))/devices/\(push.installID).json"),
               let obj = try? JSONDecoder().decode(JSONValue.self, from: Data(dev.utf8)) {
                if let t = obj["live_activity_token"]?.stringValue, !t.isEmpty {
                    let sid = obj["live_activity_session_id"]?.stringValue ?? "?"
                    deviceFileLiveActivity = "token on file for session \(sid.prefix(12))…"
                } else { deviceFileLiveActivity = "no Live Activity token on file" }
            } else { deviceFileLiveActivity = nil }
            if let script = try await readManagedText(rt, path: "\(home)/plugins/vory-push/hermes_push.py") {
                installedScriptMatches = SHA256.hash(data: Data(script.utf8)).map { String(format: "%02x", $0) }.joined() == Self.bundledScriptSHA256
            } else {
                installedScriptMatches = false
            }
            if let text = try await readManagedText(rt, path: "\(pushDir(for: rt))/status.json"), let data = text.data(using: .utf8) {
                heartbeat = try JSONDecoder().decode(CompanionHeartbeat.self, from: data)
            } else {
                heartbeat = nil
            }
        } catch { companionCheckError = error.localizedDescription }
        companionCheckedAt = Date()
    }

    /// A managed file's text, or nil when the gateway has no such file.
    private func readManagedText(_ rt: GatewayRuntime, path: String) async throws -> String? {
        do {
            let r: JSONValue = try await rt.api.get("/api/files/read", query: [URLQueryItem(name: "path", value: path)])
            guard let url = r["data_url"]?.stringValue, let comma = url.firstIndex(of: ","),
                  let data = Data(base64Encoded: String(url[url.index(after: comma)...])) else { return nil }
            return String(data: data, encoding: .utf8)
        } catch HermesAPIError.http(let status, _) where status == 404 {
            return nil
        }
    }

    func canUpload(for rt: GatewayRuntime) -> Bool { uploadBlocker(for: rt) == nil }

    /// Why the upload button is disabled, in words, or nil when it can run.
    func uploadBlocker(for rt: GatewayRuntime) -> String? {
        if gatewayURL.isEmpty { return "Enter the gateway URL for the companion first." }
        if !PushRelay.isConfigured {
            if keyData == nil { return "This build has no push relay, so it needs your APNs .p8 key first (step 1)." }
            if keyID.isEmpty || teamID.count != 10 { return "The Key ID and a 10-character Team ID are needed (step 1)." }
        }
        if case .needsSignIn = credential(for: rt) { return "Sign in for the companion first." }
        return nil
    }

    var uploadedAll: Bool { uploaded.count >= (PushRelay.isConfigured ? 3 : 4) }

    func pushDir(for rt: GatewayRuntime) -> String { (rt.profileHome ?? "~/.hermes") + "/push" }
    func installCommand(for rt: GatewayRuntime) -> String { "bash \(pushDir(for: rt))/install.sh" }

    func importKey(_ url: URL) {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        guard let data = try? Data(contentsOf: url) else { error = "Could not read \(url.lastPathComponent)."; return }
        guard String(data: data, encoding: .utf8)?.contains("PRIVATE KEY") == true else { error = "\(url.lastPathComponent) does not look like an APNs .p8 key."; return }
        keyData = data
        keyFileName = url.lastPathComponent
        // AuthKey_ABC123DEFG.p8 → ABC123DEFG
        let stem = url.deletingPathExtension().lastPathComponent
        keyID = stem.hasPrefix("AuthKey_") ? String(stem.dropFirst(8)) : ""
        error = nil
    }

    /// The config the companion reads. Never contains this phone's own OAuth tokens.
    func configText(for rt: GatewayRuntime) -> String {
        var lines = ["# Written by Vory. Read by hermes_push.py (HERMES_PUSH_CONFIG). Values override nothing set in the environment.",
                     "HERMES_PUSH_GATEWAY_URL=\(gatewayURL)",
                     "HERMES_PUSH_PUBLIC_URL=\(rt.connection.gateway.description)"]
        switch credential(for: rt) {
        case .sessionToken:
            if let t = rt.secrets.sessionToken { lines.append("HERMES_PUSH_GATEWAY_TOKEN=\(t)") }
        case .ready:
            if let a = companionSecrets?.accessToken { lines.append("HERMES_PUSH_GATEWAY_BEARER=\(a)") }
            if let r = companionSecrets?.refreshToken { lines.append("HERMES_PUSH_GATEWAY_REFRESH_TOKEN=\(r)") }
        case .needsSignIn: break
        }
        let access = rt.secrets.access
        if access.isConfigured {
            lines.append("HERMES_PUSH_CF_ACCESS_CLIENT_ID=\(access.clientId)")
            lines.append("HERMES_PUSH_CF_ACCESS_CLIENT_SECRET=\(access.clientSecret)")
        }
        let dir = pushDir(for: rt)
        if !PushRelay.isConfigured {
            lines += ["HERMES_PUSH_APNS_KEY_FILE=\(dir)/AuthKey_\(keyID).p8",
                      "HERMES_PUSH_APNS_KEY_ID=\(keyID)",
                      "HERMES_PUSH_APNS_TEAM_ID=\(teamID)"]
        }
        lines.append("HERMES_PUSH_DEVICES_DIR=\(dir)/devices")
        return lines.joined(separator: "\n") + "\n"
    }

    func upload(runtime rt: GatewayRuntime) async {
        uploading = true; defer { uploading = false }
        uploaded = []; error = nil; uploadedAt = nil
        let dir = pushDir(for: rt)
        guard let script = Bundle.main.url(forResource: "hermes_push", withExtension: "py", subdirectory: "hermes-push") ?? Bundle.main.url(forResource: "hermes_push", withExtension: "py"),
              let installer = Bundle.main.url(forResource: "install", withExtension: "sh", subdirectory: "hermes-push") ?? Bundle.main.url(forResource: "install", withExtension: "sh"),
              let scriptData = try? Data(contentsOf: script), let installerData = try? Data(contentsOf: installer) else { error = "The companion files are missing from this build."; return }
        var files: [(String, Data, String)] = [
            ("\(dir)/hermes_push.py", scriptData, "text/x-python"),
            ("\(dir)/install.sh", installerData, "text/x-shellscript"),
            ("\(dir)/hermes-push.conf", Data(configText(for: rt).utf8), "text/plain"),
        ]
        if !PushRelay.isConfigured {
            guard let keyData else { error = "Choose the APNs key first."; return }
            files.insert(("\(dir)/AuthKey_\(keyID).p8", keyData, "application/x-pem-file"), at: 2)
        }
        for (path, data, mime) in files {
            do {
                let body: JSONValue = ["path": .string(path), "data_url": .string("data:\(mime);base64," + data.base64EncodedString()), "overwrite": true]
                let _: ManagedUploadResult = try await rt.api.send("POST", "/api/files/upload", json: body)
                uploaded.append(path)
                installedFiles.append(InstalledFile(name: String(path.split(separator: "/").last ?? ""), directory: String(path.dropLast((path.split(separator: "/").last ?? "").count)), bytes: data.count))
            } catch {
                self.error = "\(path.split(separator: "/").last ?? ""): \(error.localizedDescription)"
                return
            }
        }
        uploadedAt = Date()
    }

    /// Writes the plugin into `<home>/plugins/vory-push/` through the files API and enables it.
    /// Hermes loads it on the next gateway restart and runs the relay loop in-process.
    func installPlugin(runtime rt: GatewayRuntime) async {
        installingPlugin = true; defer { installingPlugin = false }
        guard let home = rt.profileHome else { pluginResult = "The gateway did not report its home folder."; return }
        let base = "\(home)/plugins/vory-push"
        guard let script = Bundle.main.url(forResource: "hermes_push", withExtension: "py", subdirectory: "hermes-push") ?? Bundle.main.url(forResource: "hermes_push", withExtension: "py"),
              let manifest = Bundle.main.url(forResource: "plugin", withExtension: "yaml", subdirectory: "hermes-push/plugin") ?? Bundle.main.url(forResource: "plugin", withExtension: "yaml"),
              let entry = Bundle.main.url(forResource: "__init__", withExtension: "py", subdirectory: "hermes-push/plugin") ?? Bundle.main.url(forResource: "__init__", withExtension: "py"),
              let s = try? Data(contentsOf: script), let m = try? Data(contentsOf: manifest), let e = try? Data(contentsOf: entry) else {
            pluginResult = "The plugin files are missing from this build."; return
        }
        do {
            for (name, data, mime) in [("hermes_push.py", s, "text/x-python"), ("plugin.yaml", m, "text/yaml"), ("__init__.py", e, "text/x-python")] {
                let body: JSONValue = ["path": .string("\(base)/\(name)"), "data_url": .string("data:\(mime);base64," + data.base64EncodedString()), "overwrite": true]
                let _: ManagedUploadResult = try await rt.api.send("POST", "/api/files/upload", json: body)
                installedFiles.append(InstalledFile(name: name, directory: base + "/", bytes: data.count))
            }
            let r: JSONValue = try await rt.api.send("POST", "/api/dashboard/agent-plugins/vory-push/enable", body: EmptyBody())
            if r["ok"]?.boolValue == false { pluginResult = r["error"]?.stringValue ?? "Hermes refused to enable the plugin."; return }
            pluginResult = "Installed v\(Self.bundledPluginVersion) and enabled. Restart the gateway to load it."
        } catch { pluginResult = error.localizedDescription }
    }

    /// Opens a new chat and asks the agent to run the installer; the terminal call shows up as
    /// an approval card in that chat, so nothing runs without a tap.
    func askHermesToInstall(runtime rt: GatewayRuntime, model: AppModel) async {
        asking = true; defer { asking = false }
        do {
            let chat = try await rt.newChat()
            let cmd = installCommand(for: rt)
            await chat.send("Run this exact command in the terminal and show me its full output: `\(cmd)`. Do not edit any file under \(pushDir(for: rt)). If it fails, tell me the error verbatim.")
            model.pendingRoute = PendingRoute(connectionID: rt.connection.id, storedSessionID: chat.storedID, profile: rt.selectedProfile)
            model.selectedTab = .chats
        } catch { self.error = error.localizedDescription }
    }
}

/// Runs the gateway's own sign-in a second time, for the companion. The tokens never touch the
/// phone's session and are written straight into the uploaded config.
struct CompanionSignInSheet: View {
    var runtime: GatewayRuntime
    var onSignedIn: (GatewaySecrets) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var username = ""
    @State private var password = ""
    @State private var busy = false
    @State private var error: String?
    @State private var client = NativeAuthClient()

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Text("Signs the relay in to \(runtime.connection.name) with its own credentials. Use the same account you use for the dashboard.").font(.footnote).foregroundStyle(.secondary)
                }
                if runtime.connection.authMode == .password {
                    Section {
                        TextField("Username", text: $username).textInputAutocapitalization(.never).autocorrectionDisabled()
                        SecureField("Password", text: $password)
                    }
                    Section { Button(busy ? "Signing in…" : "Sign in") { Task { await signInWithPassword() } }.disabled(busy || username.isEmpty || password.isEmpty) }
                } else {
                    Section { Button(busy ? "Waiting for the browser…" : "Sign in with browser") { Task { await signInWithBrowser() } }.disabled(busy) }
                }
                if let error { Text(error).foregroundStyle(.red).font(.footnote) }
            }
            .navigationTitle("Companion sign-in")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } } }
        }
        .presentationDetents([.medium])
    }

    private func signInWithBrowser() async {
        busy = true; defer { busy = false }
        do {
            let s = try await client.signInWithBrowser(gateway: runtime.connection.gateway, provider: runtime.connection.authProvider, access: runtime.secrets.access)
            onSignedIn(s); dismiss()
        } catch { self.error = error.localizedDescription }
    }

    private func signInWithPassword() async {
        busy = true; defer { busy = false }
        do {
            // The provider is whatever the phone itself signed in with; failing that, the gateway's
            // password-capable provider. "password" is a mode here, not a provider name.
            var provider = runtime.secrets.provider ?? runtime.connection.authProvider ?? ""
            if provider.isEmpty, let list = try? await NativeAuthClient.providers(gateway: runtime.connection.gateway, access: runtime.secrets.access) {
                provider = list.first(where: { $0.supportsPassword ?? false })?.name ?? list.first?.name ?? ""
            }
            if provider.isEmpty { provider = "basic" }
            let s = try await NativeAuthClient.signInWithPassword(gateway: runtime.connection.gateway, provider: provider, username: username, password: password, access: runtime.secrets.access)
            password = ""
            onSignedIn(s); dismiss()
        } catch { self.error = error.localizedDescription }
    }
}

/// Reads the Team ID out of this build's embedded provisioning profile (TestFlight / App Store /
/// device builds). Nil on the simulator, where the field is simply typed in.
enum ProvisioningProfile {
    static var teamID: String? {
        #if os(macOS)
        // A Mac app keeps its profile beside Info.plist, not among the resources.
        let url: URL? = Bundle.main.bundleURL.appendingPathComponent("Contents/embedded.provisionprofile")
        #else
        let url = Bundle.main.url(forResource: "embedded", withExtension: "mobileprovision")
        #endif
        guard let url, let data = try? Data(contentsOf: url) else { return nil }
        // The profile is CMS-signed DER with the property list embedded as plain text.
        guard let start = data.range(of: Data("<?xml".utf8)), let end = data.range(of: Data("</plist>".utf8)) else { return nil }
        let plistData = data[start.lowerBound..<end.upperBound]
        guard let plist = try? PropertyListSerialization.propertyList(from: plistData, format: nil) as? [String: Any] else { return nil }
        if let ids = plist["TeamIdentifier"] as? [String], let first = ids.first { return first }
        if let ent = plist["Entitlements"] as? [String: Any], let t = ent["com.apple.developer.team-identifier"] as? String { return t }
        return nil
    }
}


/// Settings › Companion › Diagnostics: what the last notification, the Live Activity and the
/// Companion's last push looked like, for when something does not arrive.
struct CompanionDiagnosticsView: View {
    @Bindable var setup: PushSetupModel
    var push: PushRegistrar

    var body: some View {
        SettingsList {
            SettingsHeaderSection(title: "Diagnostics", symbol: "stethoscope", color: .gray, description: DeviceWords.isMac ? "The last notification and the last push the Companion sent." : "The last notification, the Live Activity's tokens and log, and the last push the Companion sent.")
            Section {
                    LabeledContent("Last notification") {
                        Text(setup.extensionBreadcrumb ?? "none handled yet").font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.trailing)
                    }
                    #if os(iOS)
                    LabeledContent("Live Activity") {
                        VStack(alignment: .trailing, spacing: 2) {
                            Text(push.liveActivityToken != nil ? "active · token since \(push.liveActivityTokenAt?.formatted(date: .omitted, time: .shortened) ?? "?")" : "none running")
                            if let d = setup.deviceFileLiveActivity { Text(d).font(.caption).foregroundStyle(.secondary) }
                            if let at = LiveActivityController.lastStartedAt { Text("last started \(at.formatted(date: .omitted, time: .shortened))").font(.caption).foregroundStyle(.secondary) }
                            if let e = LiveActivityController.lastStartError { Text("could not start: \(e)").font(.caption).foregroundStyle(.orange) }
                        }
                    }
                    if !LiveActivityController.log.isEmpty {
                        VStack(alignment: .leading, spacing: 2) {
                            ForEach(Array(LiveActivityController.log.suffix(6).enumerated()), id: \.offset) { _, line in
                                Text(line).font(.caption2.monospaced()).foregroundStyle(.secondary)
                            }
                        }
                    }
                    LabeledContent("Last Live Activity push") {
                        if let hb = setup.heartbeat, let ev = hb.lastLaEvent {
                            VStack(alignment: .trailing, spacing: 2) {
                                Text("\(ev) · \(hb.lastLaOk == true ? "sent" : "failed")\(hb.lastLaAt.map { " · " + Date(timeIntervalSince1970: $0).formatted(date: .omitted, time: .shortened) } ?? "")")
                                    .font(.caption).foregroundStyle(hb.lastLaOk == true ? Color.secondary : Color.orange)
                                if let r = hb.lastLaResponse, !r.isEmpty { Text(r).font(.caption2.monospaced()).foregroundStyle(.secondary).lineLimit(3) }
                            }
                        } else {
                            Text("none yet").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    #endif
            } footer: {
                #if os(iOS)
                Text("With a Live Activity running, finish and approval alerts go through it (the Island expands and buzzes); banners only when there is none.")
                #else
                Text("On the Mac every alert arrives as a notification; running turns and waiting approvals also sit in the menu bar.")
                #endif
            }
        }
        .untitledPage()
    }
}
