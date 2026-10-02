import SwiftUI
import VoryCore

/// A turn the gateway ended before the bot finished, in place of the bare "Operation
/// interrupted." bubble: one quiet line, and under Why the reasons it happens and what keeps
/// long work running. Opens already explained when the app knows it was away.
struct InterruptedTurnCard: View {
    var turn: InterruptedTurn
    var cause: InterruptedTurn.Cause?
    /// Opens the gateway's "keep work running" setting.
    var onKeepRunning: () -> Void
    @State private var open = false

    private var explained: Bool { open || cause == .appWasAway }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Label(cause == .stopped ? "You stopped this turn" : "Stopped before it finished", systemImage: "stop.circle")
                    .font(.subheadline.weight(.semibold))
                Spacer(minLength: 0)
                if cause == nil {
                    Button { withAnimation(.snappy) { open.toggle() } } label: { Text(open ? "Hide" : "Why?").font(.caption) }
                        .buttonStyle(.borderless)
                        .accessibilityIdentifier("interrupted.why")
                }
            }
            if let doing = turn.doing, cause != .stopped {
                Text(doing.lowercased().hasPrefix("during") ? "It was stopped \(doing)." : "It was \(doing).")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            if explained, cause != .stopped {
                Text(reason).font(.footnote).foregroundStyle(.secondary)
                Text("The chat is intact. Send a message to carry on from what the bot had done.")
                    .font(.footnote).foregroundStyle(.secondary)
                Text("To keep long work running: update Hermes on the gateway (newer versions leave a working turn alone), or make the gateway wait longer.")
                    .font(.footnote).foregroundStyle(.secondary)
                Button(action: onKeepRunning) { Label("Keep work running…", systemImage: "hourglass") }
                    .buttonStyle(.bordered).controlSize(.small)
                    .accessibilityIdentifier("interrupted.keepRunning")
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.orange.opacity(0.10), in: .rect(cornerRadius: 12))
        .accessibilityElement(children: .contain)
    }

    private var reason: String {
        let away = DeviceWords.isMac
            ? "A Mac that sleeps, or loses its network, drops its connection to the gateway."
            : "iOS suspends an app shortly after it leaves the screen, which drops its connection to the gateway."
        if cause == .appWasAway {
            return "The gateway ended this turn because Vory was not connected to it. \(away) A gateway that sees no app on a chat stops the turn after a short wait, 20 seconds unless it was changed."
        }
        return "Either Stop was pressed, or the gateway ended the turn because no app was connected to the chat. \(away) A gateway that sees no app on a chat stops the turn after a short wait, 20 seconds unless it was changed."
    }
}

/// How long the gateway keeps a turn going with no app connected: read from its config, set
/// from here. Shown in Settings › System and from an interrupted turn's card.
struct AwayGraceSection: View {
    var runtime: GatewayRuntime
    @State private var grace: AwayGrace?
    @State private var error: String?
    @State private var saving = false
    @State private var changed = false

    var body: some View {
        Section {
            if let grace {
                Picker(selection: Binding(get: { grace.effective }, set: { v in Task { await save(v) } })) {
                    ForEach(options(grace), id: \.self) { s in Text(AwayGrace.label(s)).tag(s) }
                } label: {
                    Label("Keep work running", systemImage: "hourglass")
                }
                .disabled(saving || grace.envOverride)
                .accessibilityIdentifier("system.awayGrace")
                if grace.isShort, !changed {
                    Label("Short. On a Hermes older than September 2026 a long task is cut off about \(AwayGrace.label(grace.effective)) after the app leaves.", systemImage: "exclamationmark.triangle")
                        .font(.footnote).foregroundStyle(.orange)
                }
                if grace.envOverride {
                    Text("\(AwayGrace.envKey) is set in the gateway's environment and wins over this. Change or remove it in Settings › Environment.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
            } else if error == nil {
                HStack { Label("Keep work running", systemImage: "hourglass"); Spacer(); ProgressView().controlSize(.small) }
            }
            if let error { Text(error).font(.footnote).foregroundStyle(.red) }
            if changed {
                Label("Saved. It takes effect when the dashboard service restarts on the gateway machine.", systemImage: "checkmark.circle")
                    .font(.footnote).foregroundStyle(.secondary)
            }
        } header: { Text("While the app is away") } footer: {
            Text("How long the gateway lets a turn carry on with no app connected to its chat, for example after \(DeviceWords.isMac ? "this Mac sleeps" : "Vory leaves the screen"). A current Hermes already leaves a turn that is still working alone; this matters most on an older one, where a short wait cuts long tasks off with \u{201C}Operation interrupted\u{201D}. The setting is dashboard.ws_orphan_reap_grace_s in the gateway's config, and the dashboard reads it when it starts (updating Hermes from here restarts it).")
        }
        .task(id: runtime.connection.id) { await load() }
    }

    /// The offered waits, plus the gateway's own value when it is none of them.
    private func options(_ g: AwayGrace) -> [Double] {
        AwayGrace.choices.contains(g.effective) ? AwayGrace.choices : (AwayGrace.choices + [g.effective]).sorted { ($0 == 0 ? .infinity : $0) < ($1 == 0 ? .infinity : $1) }
    }

    private func load() async {
        do {
            let cfg: JSONValue = try await runtime.api.get("/api/config", profile: runtime.selectedProfile)
            var g = AwayGrace.read(config: cfg)
            // The environment wins on the gateway; say so rather than show a value that does nothing.
            if let vars: [String: EnvVarInfo] = try? await runtime.api.get("/api/env", profile: runtime.selectedProfile), vars[AwayGrace.envKey]?.hasValue == true {
                g.envOverride = true
            }
            grace = g
            error = nil
        } catch {
            self.error = "Could not read the gateway's setting: \(error.localizedDescription)"
        }
    }

    private func save(_ seconds: Double) async {
        guard grace?.effective != seconds else { return }
        saving = true; defer { saving = false }
        do {
            let _: JSONValue = try await runtime.api.send("PUT", "/api/config", profile: runtime.selectedProfile, json: AwayGrace.writeBody(seconds: seconds))
            grace?.seconds = seconds
            changed = true
            error = nil
        } catch {
            self.error = "Could not save it: \(error.localizedDescription)"
        }
    }
}

/// The same control as a sheet, opened from an interrupted turn.
struct AwayGraceSheet: View {
    var runtime: GatewayRuntime
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                AwayGraceSection(runtime: runtime)
            }
            .formStyle(.grouped)
            .navigationTitle("Keep Work Running").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }
    }
}
