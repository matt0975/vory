import SwiftUI
import VoryCore
#if canImport(UIKit)
import UIKit
#else
import AppKit
#endif

/// Settings › Troubleshooting › Crash and freeze reports (#668): what MetricKit has told Vory about times the app closed
/// unexpectedly or stopped responding, kept on this device only (`HealthReportStore`), with Copy. Nothing is sent.
struct HealthReportsView: View {
    var store: HealthReportStore = Self.defaultStore
    @State private var snapshot = HealthReportStore.Snapshot()
    @State private var copied = false

    static var defaultStore: HealthReportStore {
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("-vory-health-fixture") { return HealthReportsFixture.store }
        #endif
        return .shared
    }

    /// The page's rows for one section's counts: the problems in the store's order, the three kinds of crash as one,
    /// a normal close last, each only above zero.
    static func rows(_ counts: [HealthReportStore.ExitReason: Int]) -> [(String, Int)] {
        typealias R = HealthReportStore.ExitReason
        let n = { (r: R) in counts[r] ?? 0 }
        let all: [(String, Int)] = [
            ("Ran out of memory", n(.memoryLimit)),
            ("Took too long to respond", n(.watchdog)),
            ("Used too much processing", n(.cpuLimit)),
            ("Crashed", n(.badAccess) + n(.illegalInstruction) + n(.abnormal)),
            ("Background time ran out", n(.backgroundTimeout)),
            ("Kept a file locked", n(.lockedFile)),
            ("The system needed memory", n(.memoryPressure)),
            ("Closed normally", n(.normal)),
        ]
        return all.filter { $0.1 > 0 }
    }

    var body: some View {
        SettingsList {
            SettingsHeaderSection(title: "Crash and freeze reports", symbol: "waveform.path.ecg", color: .red,
                                  description: "What \(DeviceWords.this) has told Vory about times the app closed unexpectedly or stopped responding. Kept on \(DeviceWords.this) only; nothing is sent.")
            if snapshot.windows.isEmpty && snapshot.reports.isEmpty {
                Section {
                    Text("No reports yet. \(DeviceWords.isMac ? "macOS" : "iOS") sends them about once a day, after Vory has been used.")
                        .foregroundStyle(.secondary)
                        .accessibilityIdentifier("healthReports.empty")
                }
            } else {
                counts("Closed while you were using it", snapshot.foreground, id: "foreground")
                counts("Closed in the background", snapshot.background, id: "background")
                if !snapshot.reports.isEmpty {
                    Section {
                        ForEach(Array(snapshot.reports.reversed().enumerated()), id: \.offset) { _, r in
                            VStack(alignment: .leading, spacing: 2) {
                                Text(Self.title(r))
                                Text("Vory \(r.appVersion) (\(r.appBuild))").font(.footnote).foregroundStyle(.secondary)
                            }
                            .accessibilityElement(children: .combine)
                        }
                    }
                }
                Section {
                    Button { copy() } label: {
                        Label(copied ? "Copied" : "Copy report", systemImage: "doc.on.doc")
                            #if os(macOS)
                            // The Mac's form draws a button row only as tall as its text (16 pt): at least 28 pt, all of it a place to click.
                            .frame(minHeight: 28)
                            .contentShape(Rectangle())
                            #endif
                    }
                    .accessibilityIdentifier("healthReports.copy")
                } footer: {
                    Text("Copies the counts and the crash details as text, with no messages, names or keys, to paste into an email or a TestFlight comment.")
                }
            }
        }
        // The page's own frame, for the audit's test to tell the page from the columns and bars around it.
        .accessibilityIdentifier("healthReports.page")
        .untitledPage()
        .task { snapshot = store.snapshot }
    }

    @ViewBuilder private func counts(_ title: String, _ counts: [HealthReportStore.ExitReason: Int], id: String) -> some View {
        let rows = Self.rows(counts)
        if !rows.isEmpty {
            Section(title) {
                ForEach(rows, id: \.0) { row in
                    LabeledContent(row.0) { Text("\(row.1)").monospacedDigit() }
                }
            }
            .accessibilityIdentifier("healthReports.\(id)")
        }
    }

    /// "Crash on Nov 9, 2026", "Froze for 3 seconds on Nov 9, 2026", or "Froze on Nov 9, 2026" when the length didn't read.
    static func title(_ r: HealthReportStore.Report) -> String {
        let day = r.date.formatted(date: .abbreviated, time: .omitted)
        guard r.kind == .freeze else { return "Crash on \(day)" }
        guard let s = r.freezeSeconds else { return "Froze on \(day)" }
        let n = s == s.rounded() ? String(Int(s)) : String(format: "%.1f", s)
        return "Froze for \(n) \(s == 1 ? "second" : "seconds") on \(day)"
    }

    private func copy() {
        let text = store.copyText()
        #if canImport(UIKit)
        UIPasteboard.general.string = text
        #else
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        #endif
        withAnimation(.snappy) { copied = true }
    }
}

#if DEBUG
/// The UI tests' rows (`-vory-health-fixture`): an in-memory store with one day's counts, a crash and a freeze. Nothing is
/// written.
enum HealthReportsFixture {
    static let store: HealthReportStore = {
        let s = HealthReportStore(url: nil)
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX"); f.dateFormat = "yyyy-MM-dd HH:mm:ss Z"
        let end = f.string(from: Date()), begin = f.string(from: Date().addingTimeInterval(-86_400))
        let meta: [String: Any] = ["appVersion": "1.5.1", "appBuildVersion": "53", "osVersion": "iPhone OS 27.2 (24C101)",
                                   "deviceType": "iPhone18,1"]
        let frame: [String: Any] = ["binaryName": "Vory", "binaryUUID": "4C4C4C4C-0000-0000-0000-000000000001",
                                    "offsetIntoBinaryTextSegment": 1234]
        let tree: [String: Any] = ["callStacks": [["threadAttributed": true, "callStackRootFrames": [frame]]]]
        var crashMeta = meta
        crashMeta["exceptionType"] = 10; crashMeta["exceptionCode"] = 0; crashMeta["signal"] = 9
        crashMeta["terminationReason"] = "Namespace SPRINGBOARD, Code 0x8badf00d"
        var hangMeta = meta
        hangMeta["hangDuration"] = "3 sec"
        let diagnostic: [String: Any] = ["timeStampBegin": begin, "timeStampEnd": end,
                                         "crashDiagnostics": [["diagnosticMetaData": crashMeta, "callStackTree": tree]],
                                         "hangDiagnostics": [["diagnosticMetaData": hangMeta, "callStackTree": tree]]]
        let metric: [String: Any] = ["timeStampBegin": begin, "timeStampEnd": end, "applicationExitMetrics": [
            "foregroundExitData": ["cumulativeAppWatchdogExitCount": 1, "cumulativeNormalAppExitCount": 2],
            "backgroundExitData": ["cumulativeMemoryResourceLimitExitCount": 3, "cumulativeBackgroundTaskAssertionTimeoutExitCount": 1,
                                   "cumulativeNormalAppExitCount": 12]]]
        if let m = try? JSONSerialization.data(withJSONObject: metric) { s.ingest(metricJSON: m) }
        if let d = try? JSONSerialization.data(withJSONObject: diagnostic) { s.ingest(diagnosticJSON: d) }
        return s
    }()
}
#endif
