#if os(iOS)
import SwiftUI
import UIKit

/// Settings › Troubleshooting › Screen layout (#516), on a test build only (`AppModel.testBuild`): the numbers the layout
/// works from, live, from the same sources it reads (the window's geometry and reserved regions in the environment, the
/// strip, the hinge's last reading, the status reader's verdict and the room the top bar applied), so a screenshot from a
/// device shows what the simulator can't. Geometry and the device's make only: no gateway, names or anything of the
/// person's. Each value carries an identifier for the UI test that checks it against the DEBUG geometry probe.
struct ScreenLayoutView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.windowGeometry) private var windowGeometry
    @Environment(\.reservedRegions) private var regions

    var body: some View {
        let g = windowGeometry
        SettingsList {
            SettingsHeaderSection(title: "Screen layout", symbol: "ruler", color: .orange,
                                  description: "Take a screenshot in each way you hold the device.")
            Section {
                line("Window", Self.size(g.bounds.size), id: "layout.window")
                line("Safe area", Self.insets(g.safeArea), id: "layout.safeArea")
                line("Status area", Self.status(regions.statusArea(width: g.bounds.width)), id: "layout.status")
                line("Fold", Self.fold(regions), id: "layout.fold")
                line("Posture", DevicePosture.shared.last.map { String(format: "%@, %.0f°", $0.status, $0.degrees) } ?? "Not reported", id: "layout.posture")
                // The edge the system lays its bars on, from the environment the DEBUG probe reads too ("bar leading").
                VerticalBarEdge { edge in line("Strip edge", edge.map { $0 == .leading ? "Left" : "Right" } ?? "None", id: "layout.strip") }
                line("Top bar room", Self.room(front: model.selectedTab, rooms: AppliedRoom.shared.rooms), id: "layout.room")
            }
            Section {
                if regions.reported.isEmpty {
                    line("Areas", "None reported", id: "layout.area.none")
                } else {
                    ForEach(Array(regions.reported.enumerated()), id: \.offset) { i, r in
                        line((r.kind == .fold ? "Fold area" : "Covered area") + (r.active ? "" : ", inactive"), Self.rect(r.frame), id: "layout.area.\(i)")
                    }
                }
            } header: {
                Text("Reported areas")
            }
            Section {
                line("iOS", UIDevice.current.systemVersion, id: "layout.ios")
                line("Build", Self.build, id: "layout.build")
                line("Model", Self.model, id: "layout.model")
            }
        }
        .untitledPage()
    }

    /// One value: its label and value read together, the value wrapping at large sizes.
    private func line(_ label: String, _ value: String, id: String) -> some View {
        LabeledContent {
            Text(value).monospacedDigit().multilineTextAlignment(.trailing).fixedSize(horizontal: false, vertical: true)
        } label: {
            Text(label)
        }
        // Read once, as "Window, 669 by 951 pt"; the identifier and the value are what the UI test reads.
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(label)
        .accessibilityValue(value.replacingOccurrences(of: " × ", with: " by "))
        .accessibilityIdentifier(id)
    }

    // MARK: The values' wording

    /// Points to a tenth, without a trailing ".0": the probe's whole points match it to half a point.
    static func points(_ v: CGFloat) -> String {
        let r = (v * 10).rounded() / 10
        return (r == r.rounded() ? String(format: "%.0f", r) : String(format: "%.1f", r)) + " pt"
    }
    static func size(_ s: CGSize) -> String { "\(points(s.width).dropLast(3)) × \(points(s.height))" }
    static func insets(_ e: EdgeInsets) -> String {
        "top \(points(e.top)), left \(points(e.leading)), bottom \(points(e.bottom)), right \(points(e.trailing))"
    }
    static func rect(_ r: CGRect) -> String { "x \(points(r.minX)), y \(points(r.minY)), \(size(r.size))" }
    static func status(_ a: ReservedRegions.StatusArea) -> String {
        switch a {
        case .corner(let r): "Top right corner: \(rect(r))"
        case .notFound(let why): "Not found: \(why)"
        }
    }
    /// The front tab's root's room, and any other root's that differs ("1 pt (Chats 0 pt)"): every root applies its own.
    static func room(front: AppModel.AppTab, rooms: [AppModel.AppTab: CGFloat]) -> String {
        guard let mine = rooms[front] else { return "Not applied yet" }
        let others = rooms.filter { $0.key != front && abs($0.value - mine) > 0.05 }.sorted { $0.key.rawValue < $1.key.rawValue }
        return points(mine) + (others.isEmpty ? "" : " (" + others.map { "\($0.key.title) \(points($0.value))" }.joined(separator: ", ") + ")")
    }
    static func fold(_ regions: ReservedRegions) -> String {
        if let f = regions.horizontalFold { return "Across: \(rect(f))" }
        if let f = regions.verticalFold { return "Up the middle: \(rect(f))" }
        if let f = regions.upFold { return "Up the middle, inactive: \(rect(f))" }
        return "None"
    }
    static var build: String {
        let info = Bundle.main.infoDictionary
        return (info?["CFBundleShortVersionString"] as? String ?? "?") + " (" + (info?["CFBundleVersion"] as? String ?? "?") + ")"
    }
    /// The device's model identifier (the simulator's own when it runs there, said so).
    static var model: String {
        if let sim = ProcessInfo.processInfo.environment["SIMULATOR_MODEL_IDENTIFIER"] { return sim + ", simulator" }
        var u = utsname()
        uname(&u)
        return withUnsafeBytes(of: &u.machine) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
    }
}
#endif
