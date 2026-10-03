import SwiftUI
import VoryCore

/// Settings › iCloud Sync: the switch, what iCloud holds, and the two explicit ways to take a
/// side (Restore from iCloud, Back Up This Device).
struct CloudSyncView: View {
    @Environment(AppModel.self) private var model
    @State private var sync = CloudSync.shared
    @State private var confirmRestore = false
    @State private var confirmBackUp = false
    @State private var note: String?

    var body: some View {
        let summary = summaryNow
        SettingsList {
            SettingsHeaderSection(title: "iCloud Sync", symbol: "icloud.fill", color: .cyan,
                                  description: "Your settings, bot looks and saved gateways, the same on every device signed in to your iCloud. Vory stores none of it.")
            Section {
                Toggle("Sync with iCloud", isOn: Binding(get: { sync.enabled }, set: { sync.enabled = $0 }))
                    .accessibilityIdentifier("cloud.enabled")
            } footer: {
                Text(statusLine)
            }

            Section {
                if let name = summary.name { LabeledContent("Your name", value: name) }
                LabeledContent("Settings", value: summary.settings == 0 ? "none" : "\(summary.settings)")
                LabeledContent("Bot looks", value: summary.bots == 0 ? "none" : "\(summary.bots)")
                LabeledContent("Gateways", value: summary.gateways == 0 ? "none" : "\(summary.gateways)")
                if let device = summary.device, let date = summary.date {
                    LabeledContent("Last change", value: "\(device), \(date.formatted(date: .abbreviated, time: .shortened))")
                }
            } header: { Text(sync.signedIn ? "In iCloud" : "Saved for iCloud") }

            Section {
                // Each question hangs from its own button: asked from the whole list, the
                // bubble opened at the top of the page, pointing at the Sync switch.
                Button { confirmRestore = true } label: { Label("Restore from iCloud…", systemImage: "icloud.and.arrow.down") }
                    .disabled(summary.isEmpty)
                    .accessibilityIdentifier("cloud.restore")
                    .confirmationDialog("Restore from iCloud?", isPresented: $confirmRestore, titleVisibility: .visible) {
                        Button("Restore") { restore() }
                        Button("Cancel", role: .cancel) {}
                    } message: {
                        Text("The settings and bot looks in iCloud replace the ones on \(DeviceWords.this), and gateways \(DeviceWords.this) does not have are added. Nothing on \(DeviceWords.this) is removed.")
                    }
                Button { confirmBackUp = true } label: { Label("Back Up \(DeviceWords.ThisTitle) Now", systemImage: "icloud.and.arrow.up") }
                    .accessibilityIdentifier("cloud.backUp")
                    .confirmationDialog("Back up \(DeviceWords.this)?", isPresented: $confirmBackUp, titleVisibility: .visible) {
                        Button("Back Up") { sync.backUpNow(); note = "Backed up \(Date().formatted(date: .omitted, time: .shortened))." }
                        Button("Cancel", role: .cancel) {}
                    } message: {
                        Text("The settings, bot looks and gateways on \(DeviceWords.this) replace the ones in iCloud, and your other devices take them.")
                    }
            } footer: {
                VStack(alignment: .leading, spacing: 6) {
                    if let note { Text(note).foregroundStyle(.primary) }
                    Text("With sync on, a change on one device reaches the others by itself. Restore makes \(DeviceWords.this) match iCloud now; Back Up makes iCloud match \(DeviceWords.this).")
                }
            }

            Section {
                row("paintpalette", "Appearance", "Accent, theme and what a chat shows")
                row("house", "Home", "Your name, the cards and their order")
                row("cloud", "Bot looks", "Each bot's colour, body, eyes and photo")
                row("network", "Gateways", "Their addresses, session tokens and Cloudflare Access values, through iCloud Keychain")
            } header: { Text("What syncs") } footer: {
                Text("Stays on each device: notifications, the app lock, the \(DeviceWords.isMac ? "sidebar" : "tab bar"), text size, and browser sign-ins (a gateway signed in with the browser asks once on each device).")
            }
        }
        .untitledPage()
    }

    /// Read again whenever the sync says the cloud may have changed.
    private var summaryNow: CloudSummary {
        _ = sync.revision
        return sync.summary()
    }

    private var statusLine: String {
        if let erased = sync.pausedByErase {
            return "The iCloud data was erased from another device on \(erased.formatted(date: .abbreviated, time: .shortened)), so sync stopped here and \(DeviceWords.this) kept what it has. Turn it on to put \(DeviceWords.this)'s settings, looks and gateways back in iCloud."
        }
        if !sync.enabled { return "Off: \(DeviceWords.this) keeps its own settings and sends nothing to iCloud. What is already in iCloud stays there." }
        if !sync.signedIn { return "\(DeviceWords.This) does not appear to be signed in to iCloud, or iCloud Drive is off for it. Sync starts by itself once it is." }
        if let t = sync.lastSyncedAt { return "On. Last checked \(t.formatted(date: .omitted, time: .shortened))." }
        return "On."
    }

    private func row(_ symbol: String, _ title: String, _ detail: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: symbol).foregroundStyle(.tint).frame(width: 24)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                Text(detail).font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private func restore() {
        let r = sync.restore()
        note = CloudRestoreSheet.words(for: r)
        // A gateway that came back without its sign-in is asked for it now.
        model.signInPrompt = r.pending
        if model.runtime == nil { Task { await model.activateSavedConnection() } }
    }
}

/// The restore flow as a sheet, for the first screen: look, say what is there, restore.
struct CloudRestoreSheet: View {
    /// Called after a restore, with what it brought.
    var onRestored: (CloudSync.RestoreOutcome) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var summary: CloudSummary?
    /// Settings are there and the gateways are not yet: they come through iCloud Keychain,
    /// which can take a while longer on a new device, so the sheet keeps looking for a bit.
    @State private var waitingForGateways = false
    private let sync = CloudSync.shared

    var body: some View {
        FittedSheet {
            VStack(spacing: 18) {
                BotFaceView(spec: BotLookSpec.vory, size: 84, active: summary == nil, mood: BotFaceView.Mood(profile: "vory-restore", state: summary == nil ? .thinking : .guide))
                if let summary {
                    if summary.isEmpty { empty } else { found(summary) }
                } else {
                    Text("Looking in your iCloud…").font(.headline)
                    ProgressView()
                }
            }
            .padding(.horizontal, 28).padding(.bottom, 24)
            .frame(maxWidth: 440)
        }
        .task {
            let s = await sync.refresh()
            summary = s
            guard !s.isEmpty, s.gateways == 0 else { return }
            waitingForGateways = true
            let n = await sync.waitForGateways(upTo: Self.gatewayWait)
            if !Task.isCancelled { summary?.gateways = n; waitingForGateways = false }
        }
    }

    /// How long the sheet looks for the gateway item after the settings have arrived.
    static let gatewayWait: Double = 20

    /// The gateway line of the box: what iCloud holds, or that it is still being looked for.
    static func gatewayLine(count: Int, waiting: Bool) -> String {
        if count > 0 { return count == 1 ? "1 gateway" : "\(count) gateways" }
        return waiting ? "Looking for your gateways…" : "No saved gateways yet"
    }

    @ViewBuilder private var empty: some View {
        Text("Nothing in iCloud yet").font(.title3.weight(.semibold))
        Text(sync.signedIn
             ? "There is no Vory backup in this iCloud account. Once Vory is set up on one device, the others can restore from it."
             : "\(DeviceWords.This) does not appear to be signed in to iCloud, or iCloud Drive is off for it. Sign in in \(DeviceWords.settings), or set Vory up fresh.")
            .font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center)
        Button { dismiss() } label: { Text("OK").font(.headline).frame(maxWidth: .infinity).padding(.vertical, 6) }
            .buttonStyle(.glass)
            .accessibilityIdentifier("restore.none")
    }

    @ViewBuilder private func found(_ s: CloudSummary) -> some View {
        // The name Home greets them by comes back with the rest; saying it shows whose backup this is.
        Text(s.name.map { "Welcome back, \($0)" } ?? "Found your Vory").font(.title3.weight(.semibold))
        if let device = s.device, let date = s.date {
            Text("Last changed on \(device), \(date.formatted(date: .abbreviated, time: .shortened))").font(.callout).foregroundStyle(.secondary)
        }
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                line("network", Self.gatewayLine(count: s.gateways, waiting: waitingForGateways))
                if waitingForGateways { ProgressView().controlSize(.small) }
            }
            line("cloud", s.bots == 0 ? "No bot looks" : (s.bots == 1 ? "Looks for 1 bot" : "Looks for \(s.bots) bots"))
            line("slider.horizontal.3", s.settings == 0 ? "No settings" : (s.name == nil ? "Your settings" : "Your settings and your name on Home"))
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.primary.opacity(0.05), in: .rect(cornerRadius: 14))
        VStack(spacing: 10) {
            Button {
                let r = sync.restore()
                dismiss()
                onRestored(r)
            } label: { Text("Restore").font(.headline).frame(maxWidth: .infinity).padding(.vertical, 6) }
                .buttonStyle(.glassProminent)
                .accessibilityIdentifier("restore.confirm")
            Button("Not now") { dismiss() }
                .font(.subheadline).foregroundStyle(.secondary)
                #if os(macOS)
                .buttonStyle(.borderless)
                #endif
        }
        Text(s.gateways == 0 && !waitingForGateways
             ? "Your gateways travel through iCloud Keychain, which can take a few minutes to reach a new device and must be on for both devices. Restore now and they are added when they arrive; until then the gateway can be entered by hand."
             : "Notifications are set up per device. A gateway signed in with the browser asks for its sign-in next.")
            .font(.footnote).foregroundStyle(.secondary).multilineTextAlignment(.center)
            .fixedSize(horizontal: false, vertical: true)
    }

    private func line(_ symbol: String, _ text: String) -> some View {
        Label(text, systemImage: symbol).font(.callout)
    }

    /// What a restore did, in a sentence.
    static func words(for r: CloudSync.RestoreOutcome) -> String {
        var parts: [String] = []
        if r.settings > 0 { parts.append("settings and looks restored") }
        if r.gateways > 0 { parts.append(r.gateways == 1 ? "1 gateway added" : "\(r.gateways) gateways added") }
        if parts.isEmpty { return r.gatewaysAwaited ? "Your gateways have not reached \(DeviceWords.this) yet; they are added when they arrive." : "\(DeviceWords.This) already matches iCloud." }
        var s = parts.joined(separator: ", ").prefix(1).uppercased() + parts.joined(separator: ", ").dropFirst() + "."
        if r.gatewaysAwaited { s += " Your gateways have not reached \(DeviceWords.this) yet; they are added when they arrive." }
        if r.needSignIn > 0 { s += r.needSignIn == 1 ? " One gateway needs its sign-in on \(DeviceWords.this)." : " \(r.needSignIn) gateways need their sign-in on \(DeviceWords.this)." }
        return s
    }
}
