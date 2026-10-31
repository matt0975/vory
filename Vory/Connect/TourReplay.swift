import SwiftUI
import VoryCore

#if os(iOS)
/// "Replay the welcome tour" (#487), from Settings › Troubleshooting on a test build only (`TestBuild`): the tour over
/// the running app. It runs on its own demo as on a first launch and leaves the app as it was:
/// Skip goes to the last beat as on a first launch (#492), and Done there comes back to where you were; Connect your
/// gateway opens the gateway form, and
/// leaving the form (Cancel, or Save) comes back too; Try a demo closes it and starts the demo, whose Leave demo
/// brings the gateway back (not offered while the demo already runs). Restore from iCloud is not offered: this
/// device's gateways are here, and a second import over them is the last thing a replay should do.
struct TourReplayView: View {
    @Environment(AppModel.self) private var model
    @State private var showForm = false

    var body: some View {
        NavigationStack {
            TourView(onRestore: nil, onConnect: { showForm = true },
                     onDemo: model.demoAvailable ? { close(); Task { await model.startDemo() } } : nil,
                     onClose: { close() })
                .toolbar(.hidden, for: .navigationBar)
                .navigationDestination(isPresented: $showForm) { GatewayFormView() }
        }
        .onChange(of: showForm) { _, shown in if !shown { close() } }
    }

    private func close() { model.replayingTour = false }
}
#endif

#if DEBUG && os(iOS)
/// DEBUG, for the replay's no-trace test (#487): with `-vory-app-fingerprint`, a 1 pt element ("debug.appfingerprint")
/// whose value is a digest of what a replay must leave as it was, one "part=hash" a line: each of the app's own
/// settings (the standard defaults, the system's own keys aside: drafts, Home's visit mark and every first-run flag
/// among them), the saved gateways and the one in use, the chats open on it, the bots' looks and the widgets'
/// snapshot. Read before and after; a line that differs names what changed.
enum AppFingerprint {
    static let isOn = ProcessInfo.processInfo.arguments.contains("-vory-app-fingerprint")

    @MainActor static func lines(_ model: AppModel) -> [String] {
        func hash(_ s: String) -> String { String(format: "%08x", s.unicodeScalars.reduce(UInt32(2_166_136_261)) { ($0 ^ $1.value) &* 16_777_619 }) }
        let systemPrefixes = ["Apple", "NS", "AK", "com.apple", "PK", "IN", "WebKit", "MSV", "XCUI", "UIKit", "_UI", "TV"]
        var out: [String] = []
        for (k, v) in UserDefaults.standard.dictionaryRepresentation() where !systemPrefixes.contains(where: k.hasPrefix) {
            // A gateway's cached chat list is rewritten from the gateway as it refreshes (its times move on): what it
            // lists is what counts.
            if k.hasPrefix("sessions.cache."), let ids = sessionIDs(v) {
                out.append("defaults.\(k)=\(hash(ids))")
                // The ids themselves too, so a test that finds the list changed can say what came or went.
                out.append("ids.\(k)=\(ids.isEmpty ? "none" : ids)")
                continue
            }
            out.append("defaults.\(k)=\(hash(canonical(v)))")
        }
        let gateways = model.store.connections.map { "\($0.id.uuidString):\($0.name)" }.sorted().joined(separator: ",")
        out.append("gateways=\(hash(gateways))")
        out.append("inUse=\(model.store.activeConnectionID?.uuidString ?? "none")")
        out.append("demo=\(model.isInDemo)")
        // Every setting keyed by the demo's connection: once the demo is left there must be none, whatever a run before
        // left (#493: its chat list's cache stayed, and a before-and-after match didn't show it).
        let demoID = GatewayConnection.demoID.uuidString
        let demoKeys = UserDefaults.standard.dictionaryRepresentation().keys.filter { $0.contains(demoID) }.sorted()
        out.append("demoKeys=\(demoKeys.isEmpty ? "none" : demoKeys.joined(separator: ","))")
        let chats = (model.runtime?.chats ?? []).compactMap(\.storedID).sorted().joined(separator: ",")
        out.append("chats=\(hash(chats))")
        // The looks by bot, in a fixed order (a dictionary's own order changes from one read to the next).
        let looks = BotLooks.load()
        out.append("looks.colors=\(hash(looks.colors.sorted { $0.key < $1.key }.map { "\($0.key):\($0.value)" }.joined(separator: ",")))")
        out.append("looks.avatars=\(hash(looks.avatars.sorted { $0.key < $1.key }.map { "\($0.key):\($0.value)" }.joined(separator: ",")))")
        out.append("looks.photos=\(hash(looks.photos.sorted { $0.key < $1.key }.map { "\($0.key):\($0.value.count)" }.joined(separator: ",")))")
        // The widgets' gateway and chats, not their times (rewritten as the app runs).
        let w = WidgetSnapshot.load()
        out.append("widgets=\(hash([w?.gatewayName ?? "", w?.connectionID ?? "", w?.profile ?? "", (w?.chats ?? []).map(\.id).joined(separator: ",")].joined(separator: "|")))")
        // With `-vory-notify-readout`: the system's notification question, as the registrar last read it (refreshed for
        // the next read), for a tour replayed in the demo, which must not raise it (#501 asks on the demo's own first
        // message). Opt-in, as a refresh between two reads would change it for every other test.
        if ProcessInfo.processInfo.arguments.contains("-vory-notify-readout") {
            let status: String = switch model.push.authorization {
            case .notDetermined: "notDetermined"
            case .denied: "denied"
            case .authorized: "authorized"
            case .provisional: "provisional"
            case .ephemeral: "ephemeral"
            @unknown default: "unknown"
            }
            out.append("notify=\(status)")
            Task { await model.push.refreshAuthorization() }
        }
        return out.sorted()
    }

    /// A setting's value written out the same way each time: a dictionary's keys in order.
    private static func canonical(_ v: Any) -> String {
        if let d = v as? [String: Any] { return "{" + d.keys.sorted().map { "\($0):\(canonical(d[$0]!))" }.joined(separator: ",") + "}" }
        if let a = v as? [Any] { return "[" + a.map(canonical).joined(separator: ",") + "]" }
        return String(describing: v)
    }

    /// A cached chat list's session ids, in order of id.
    private static func sessionIDs(_ value: Any) -> String? {
        let data = (value as? Data) ?? (value as? String).flatMap { $0.data(using: .utf8) }
        guard let data, let rows = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { return nil }
        return rows.compactMap { ($0["id"] ?? $0["session_id"]).map { String(describing: $0) } }.sorted().joined(separator: ",")
    }

    final class ReadoutView: UIView {
        override var isAccessibilityElement: Bool { get { true } set {} }
        override var accessibilityIdentifier: String? { get { "debug.appfingerprint" } set {} }
        override var accessibilityLabel: String? { get { "App fingerprint" } set {} }
        override var accessibilityValue: String? { get { MainActor.assumeIsolated { AppFingerprint.lines(.shared).joined(separator: "\n") } } set {} }
    }
    struct Readout: UIViewRepresentable {
        func makeUIView(context: Context) -> ReadoutView { ReadoutView() }
        func updateUIView(_ v: ReadoutView, context: Context) {}
    }
}
#endif
