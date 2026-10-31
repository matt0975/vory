import SwiftUI
import VoryCore

/// Whether to offer Add scheduled task on a gateway (#428), learned without ever writing to it. The + comes with the
/// jobs list: Hermes's create route stands beside the list in its own router (web_routers/cron.py), so a gateway that
/// lists its tasks takes new ones. A create the gateway answers as a route it doesn't know (404 or 405, a Hermes from
/// before it) takes the + away for that gateway, and it stays away until the gateway's Hermes changes: its version,
/// read from GET /api/status, is kept with the refusal. Kept per gateway in the defaults, the demo's in memory only.
/// No probe: a create sent to find out could make a task on a Hermes that fills in what it's not given.
@MainActor @Observable
final class CronCreateSupport {
    static let shared = CronCreateSupport()
    private static let key = "vory.cron.createRefused"
    /// The gateways whose jobs list has loaded this run.
    private(set) var listed: Set<UUID> = []
    /// Refused gateways, by id, with their Hermes version when refused ("" when it couldn't be read).
    private(set) var refusals: [String: String] = UserDefaults.standard.dictionary(forKey: CronCreateSupport.key) as? [String: String] ?? [:]

    func canCreate(on rt: GatewayRuntime?) -> Bool {
        guard let rt else { return false }
        return listed.contains(rt.connection.id) && refusals[rt.connection.id.uuidString] == nil
    }
    /// The gateway in use, for the Scheduled Tasks tab's bar, which has no runtime at hand.
    var onActiveGateway: Bool { canCreate(on: AppModel.shared.runtime) }

    /// The jobs list loaded. A refusal kept from before is let go when the gateway's Hermes has changed since.
    func listLoaded(on rt: GatewayRuntime) async {
        let id = rt.connection.id
        listed.insert(id)
        guard let was = refusals[id.uuidString] else { return }
        if Self.updatedSince(refusedAt: was, now: await Self.version(of: rt)) { forget(rt) }
    }

    /// A create the gateway answered as a route it doesn't know: no + from then on, until its Hermes changes.
    func refused(on rt: GatewayRuntime) async {
        refusals[rt.connection.id.uuidString] = await Self.version(of: rt) ?? ""
        save(rt)
    }

    private func forget(_ rt: GatewayRuntime) {
        refusals[rt.connection.id.uuidString] = nil
        save(rt)
    }

    private func save(_ rt: GatewayRuntime) {
        // The demo's (#392) stays in memory: the demo writes nothing to the device.
        guard !rt.isEphemeral else { return }
        UserDefaults.standard.set(refusals, forKey: Self.key)
    }

    /// A create's answer that says the route isn't there.
    nonisolated static func refusesRoute(status: Int) -> Bool { status == 404 || status == 405 }

    /// Whether a refusal kept at Hermes version `refusedAt` is out of date: the version now is known and different.
    nonisolated static func updatedSince(refusedAt: String, now: String?) -> Bool {
        guard let now, !now.isEmpty else { return false }
        return now != refusedAt
    }

    private static func version(of rt: GatewayRuntime) async -> String? {
        let status: JSONValue? = try? await rt.api.get("/api/status")
        return status?["version"]?.stringValue
    }

    static let refusalMessage = "This gateway\u{2019}s Hermes can\u{2019}t create scheduled tasks from Vory. Update Hermes to add them here."
}

/// A new scheduled task (#428): what it runs, when, on which bot, and where its result goes, as Hermes's own create takes
/// them (POST /api/cron/jobs: name, schedule, prompt and deliver, the bot as its profile). The schedule comes from the same
/// pickers as a task's page (`CronSchedule.build`), or a cron line; where it delivers, from the gateway's own list.
struct CronCreateView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    /// The task is made: the list reads it.
    var onCreated: () -> Void = {}
    @State private var name = ""
    @State private var bot = ""
    @State private var prompt = ""
    @State private var deliver = "local"
    @State private var targets: [Target] = [Target(id: "local", name: "Local (save only)")]
    @State private var repeatKind = "daily"
    @State private var weekday = 1
    @State private var monthDay = 1
    @State private var time = Calendar.current.date(from: DateComponents(hour: 9, minute: 0)) ?? Date()
    @State private var custom = ""
    @State private var saving = false
    /// What went wrong with the create, said in an alert: seen wherever the form is scrolled and whatever the keyboard
    /// covers. The gateway not knowing the route closes the form after it, as there's nothing more to do here.
    @State private var error: String?
    @State private var refusedRoute = false
    private var rt: GatewayRuntime? { model.runtime }

    struct Target: Hashable { var id: String; var name: String }

    private var schedule: String {
        repeatKind == "custom" ? custom.trimmingCharacters(in: .whitespaces)
            : CronSchedule.build(kind: repeatKind, weekday: weekday, monthDay: monthDay, time: time)
    }
    private var ready: Bool { !schedule.isEmpty && !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !saving }

    var body: some View {
        Form {
            Section {
                TextField("Name", text: $name)
                    .accessibilityIdentifier("cron.new.name")
                if let rt, !rt.profiles.isEmpty {
                    Picker("Bot", selection: $bot) {
                        ForEach(rt.profiles) { p in Text(p.label).tag(p.name) }
                    }
                }
            } header: { Text("Task") }
            Section {
                Picker("Repeats", selection: $repeatKind) {
                    Text("Every day").tag("daily")
                    Text("Weekdays").tag("weekdays")
                    Text("Weekends").tag("weekends")
                    Text("Weekly").tag("weekly")
                    Text("Monthly").tag("monthly")
                    Text("Custom cron").tag("custom")
                }
                if repeatKind == "weekly" {
                    Picker("Day", selection: $weekday) {
                        ForEach(0..<7, id: \.self) { Text(Calendar.current.weekdaySymbols[$0]).tag($0) }
                    }
                }
                if repeatKind == "monthly" {
                    Picker("Day of month", selection: $monthDay) { ForEach(1...28, id: \.self) { Text("\($0)").tag($0) } }
                }
                if repeatKind == "custom" {
                    TextField("min hour day month weekday", text: $custom)
                        .font(.body.monospaced())
                        .autocorrectionDisabled()
                        #if os(iOS)
                        .textInputAutocapitalization(.never)
                        #endif
                } else {
                    DatePicker("Time", selection: $time, displayedComponents: .hourAndMinute)
                }
                Text(CronSchedule.describe(schedule)).font(.caption).foregroundStyle(.secondary)
            } header: { Text("When") } footer: { Text("Times are in the gateway machine's time zone.") }
            Section {
                TextEditor(text: $prompt)
                    .frame(minHeight: 120)
                    .accessibilityLabel("Prompt")
                    .accessibilityIdentifier("cron.new.prompt")
            } header: { Text("What it does") } footer: { Text("The prompt the bot runs on schedule.") }
            Section {
                Picker("Delivers to", selection: $deliver) {
                    ForEach(targets, id: \.self) { t in Text(t.name).tag(t.id) }
                }
            }
        }
        // Grouped, as the Mac's other forms (the gateway form, the Board's New Task): the Mac's default columns put the
        // section titles in the field column as plain text and left the prompt a borderless blank. The iPhone's look.
        .formStyle(.grouped)
        // The phone's title is short (the long one clipped at large text sizes); the Mac's sheet has room for the whole.
        #if os(macOS)
        .navigationTitle("New Scheduled Task")
        #else
        .navigationTitle("New Task")
        #endif
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            ToolbarItem(placement: .confirmationAction) {
                Button(saving ? "Adding…" : "Add") { Task { await create() } }
                    .disabled(!ready)
                    .accessibilityIdentifier("cron.new.add")
            }
        }
        .task {
            if bot.isEmpty { bot = rt?.selectedProfile ?? rt?.profiles.first?.name ?? "" }
            await loadTargets()
        }
        .alert(refusedRoute ? "Can\u{2019}t add scheduled tasks" : "Not added", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
            Button("OK") { if refusedRoute { dismiss() } }
        } message: { Text(error ?? "") }
    }

    /// The gateway's delivery targets (local, and the messaging platforms it has set up); local alone when it has no list.
    private func loadTargets() async {
        guard let rt, let r: JSONValue = try? await rt.api.get("/api/cron/delivery-targets", profile: bot.isEmpty ? nil : bot) else { return }
        let list = (r["targets"]?.arrayValue ?? []).compactMap { t -> Target? in
            guard let id = t["id"]?.stringValue, !id.isEmpty else { return nil }
            return Target(id: id, name: t["name"]?.stringValue ?? id)
        }
        if !list.isEmpty { targets = list }
        if !targets.contains(where: { $0.id == deliver }) { deliver = targets.first?.id ?? "local" }
    }

    private func create() async {
        guard let rt, ready else { return }
        saving = true
        defer { saving = false }
        var body: [String: JSONValue] = ["schedule": .string(schedule), "prompt": .string(prompt), "deliver": .string(deliver)]
        let n = name.trimmingCharacters(in: .whitespaces)
        if !n.isEmpty { body["name"] = .string(n) }
        do {
            let _: JSONValue = try await rt.api.send("POST", "/api/cron/jobs", profile: bot.isEmpty ? nil : bot, json: .object(body))
            onCreated()
            dismiss()
        } catch HermesAPIError.http(let status, let detail) {
            if CronCreateSupport.refusesRoute(status: status) {
                await CronCreateSupport.shared.refused(on: rt)
                refusedRoute = true
                error = CronCreateSupport.refusalMessage
            } else {
                error = detail.isEmpty ? "The task could not be added (\(status))." : "The task could not be added: \(detail)"
            }
        } catch {
            self.error = error.localizedDescription
        }
    }
}
