import Foundation
import Testing
@testable import VoryCore

/// MetricKit's exit counts and crash and freeze reports, kept on the device (#668). Built from JSON in the classic
/// payload's shape (`jsonRepresentation()`), so no real payload is needed; a simulator never gets one.
@Suite struct HealthReportsTests {
    /// 2026-11-09 12:00:00 UTC.
    private static let now = Date(timeIntervalSince1970: 1_794_225_600)
    private static let day: TimeInterval = 86_400

    private func freshStore() -> (HealthReportStore, URL) {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("HealthReportsTests-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("health-reports.json")
        return (HealthReportStore(url: url, now: { Self.now }), url)
    }

    private static func stamp(_ daysAgo: Double) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX"); f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "yyyy-MM-dd HH:mm:ss Z"
        return f.string(from: now.addingTimeInterval(-daysAgo * day))
    }

    private static func json(_ object: Any) -> Data {
        (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])) ?? Data()
    }

    /// A metric payload covering one day that ends `daysAgo` before now.
    private static func metric(daysAgo: Double, foreground: [String: Int], background: [String: Int], extra: [String: Any] = [:]) -> Data {
        var exits: [String: Any] = ["foregroundExitData": foreground, "backgroundExitData": background]
        for (k, v) in extra { exits[k] = v }
        return json(["appVersion": "1.5.1", "timeStampBegin": stamp(daysAgo + 1), "timeStampEnd": stamp(daysAgo),
                     "applicationExitMetrics": exits])
    }

    /// A frame and its callers as MetricKit nests them: each frame's caller in its subFrames.
    private static func frames(_ list: [(String, String, Int)]) -> [[String: Any]] {
        guard let (name, uuid, offset) = list.first else { return [] }
        var f: [String: Any] = ["binaryName": name, "binaryUUID": uuid, "offsetIntoBinaryTextSegment": offset,
                                "address": 4_295_000_000 + offset, "sampleCount": 1]
        let rest = frames(Array(list.dropFirst()))
        if !rest.isEmpty { f["subFrames"] = rest }
        return [f]
    }

    private static var meta: [String: Any] {
        ["appVersion": "1.5.1", "appBuildVersion": "52", "osVersion": "iPhone OS 26.6.2 (23G93)", "deviceType": "iPhone19,2",
         "platformArchitecture": "arm64e", "regionFormat": "US"]
    }
    private static let uuid1 = "4C4C4C4C-0000-0000-0000-000000000001", uuid2 = "4C4C4C4C-0000-0000-0000-000000000002"

    /// A diagnostic payload ending `daysAgo` before now, with the crashes and freezes given.
    private static func diagnostic(daysAgo: Double, crashes: [[String: Any]] = [], hangs: [[String: Any]] = []) -> Data {
        json(["timeStampBegin": stamp(daysAgo + 1), "timeStampEnd": stamp(daysAgo), "crashDiagnostics": crashes, "hangDiagnostics": hangs])
    }

    private static func crash(meta extra: [String: Any] = [:], frameList: [(String, String, Int)]) -> [String: Any] {
        var m = meta
        m["exceptionType"] = 1; m["exceptionCode"] = 0; m["signal"] = 11
        m["terminationReason"] = "Namespace SPRINGBOARD, Code 0x8badf00d"
        for (k, v) in extra { m[k] = v }
        return ["version": "1.0.0", "diagnosticMetaData": m,
                "callStackTree": ["callStackPerThread": true,
                                  "callStacks": [["threadAttributed": true, "callStackRootFrames": frames(frameList)]]]]
    }

    private static func hang(_ duration: String, frameList: [(String, String, Int)]) -> [String: Any] {
        var m = meta
        m["hangDuration"] = duration
        return ["version": "1.0.0", "diagnosticMetaData": m,
                "callStackTree": ["callStackPerThread": false,
                                  "callStacks": [["threadAttributed": true, "callStackRootFrames": frames(frameList)]]]]
    }

    // MARK: The redaction

    @Test func nothingPrivateIsStoredOrCopied() throws {
        let (store, url) = freshStore()
        let message = "SENTINEL-MESSAGE the deploy key is sk-live-SENTINEL0123456789 for SentinelBotName"
        let home = "/Users/sentinel-person/Documents/private.txt"
        // Every free-text field a payload has or could have, and keys nobody knows yet.
        var c = Self.crash(meta: [
            "terminationReason": "Namespace SPRINGBOARD, Code 0x8badf00d, \(message)",
            "regionFormat": "SENTINEL-REGION",
            "virtualMemoryRegionInfo": "0 is not in any region. \(home)",
            "objectiveCexceptionReason": ["composedMessage": message, "formatString": "%@", "arguments": [message],
                                          "exceptionType": "NSInvalidArgumentException", "className": "SentinelBotName"],
            "unknownSentinelKey": message,
        ], frameList: [("Vory", Self.uuid1, 1234), ("Vory SENTINEL \(home)", Self.uuid2, 5678)])
        c["unknownSentinelKey"] = message
        // The kept text fields, filled with something that isn't what they hold.
        let odd = Self.crash(meta: ["appVersion": message, "appBuildVersion": "sk-live-SENTINEL0123456789",
                                    "osVersion": "SENTINEL-OS \(home)", "deviceType": "SentinelBotName"],
                             frameList: [("Vory", Self.uuid1, 1)])
        store.ingest(diagnosticJSON: Self.diagnostic(daysAgo: 1, crashes: [c, odd], hangs: [Self.hang("2 sec", frameList: [("Vory", Self.uuid1, 9)])]))
        store.ingest(metricJSON: Self.metric(daysAgo: 1, foreground: ["cumulativeAppWatchdogExitCount": 1], background: [:],
                                             extra: ["unknownSentinelKey": message, "metaData": ["regionFormat": "SENTINEL-REGION"]]))

        let stored = try String(contentsOf: url, encoding: .utf8)
        let copied = store.copyText()
        for (what, text) in [("the stored file", stored), ("the copy", copied)] {
            #expect(!text.lowercased().contains("sentinel"), "\(what) holds a planted value")
            #expect(!text.contains("sk-live"), "\(what) holds the key")
            #expect(!text.contains("/Users/"), "\(what) holds a home path")
        }
        // What's kept is still there: the codes, and the frame that is a binary's name.
        #expect(copied.contains("SPRINGBOARD 0x8BADF00D"))
        #expect(copied.contains("Vory \(Self.uuid1) +1234"))
        let reports = store.snapshot.reports
        #expect(reports.count == 3)
        #expect(reports.first?.frames.last?.binary == "?", "a binary name with other characters isn't kept")
        let oddReport = reports.first { $0.device == "?" }
        #expect(oddReport?.appVersion == "?" && oddReport?.appBuild == "?" && oddReport?.osVersion == "?")
    }

    // MARK: The counts

    @Test func exitCountsAddUpByReason() {
        let (store, _) = freshStore()
        store.ingest(metricJSON: Self.metric(daysAgo: 2, foreground: ["cumulativeAppWatchdogExitCount": 1, "cumulativeBadAccessExitCount": 2],
                                             background: ["cumulativeMemoryResourceLimitExitCount": 3, "cumulativeNormalAppExitCount": 4]))
        store.ingest(metricJSON: Self.metric(daysAgo: 1, foreground: ["cumulativeAppWatchdogExitCount": 5],
                                             background: ["cumulativeMemoryResourceLimitExitCount": 1, "cumulativeSuspendedWithLockedFileExitCount": 2,
                                                          "cumulativeBackgroundTaskAssertionTimeoutExitCount": 6, "cumulativeCPUResourceLimitExitCount": 7,
                                                          "cumulativeMemoryPressureExitCount": 8]))
        let s = store.snapshot
        #expect(s.windows.count == 2)
        #expect(s.foreground == [.watchdog: 6, .badAccess: 2])
        #expect(s.background == [.memoryLimit: 4, .normal: 4, .lockedFile: 2, .backgroundTimeout: 6, .cpuLimit: 7, .memoryPressure: 8])
    }

    @Test func aRepeatedPayloadIsCountedOnce() {
        let (store, _) = freshStore()
        let payload = Self.metric(daysAgo: 1, foreground: ["cumulativeAbnormalExitCount": 2], background: [:])
        store.ingest(metricJSON: payload)
        store.ingest(metricJSON: payload)
        #expect(store.snapshot.windows.count == 1)
        #expect(store.snapshot.foreground == [.abnormal: 2])
        let crash = Self.diagnostic(daysAgo: 1, crashes: [Self.crash(frameList: [("Vory", Self.uuid1, 1)])])
        store.ingest(diagnosticJSON: crash)
        store.ingest(diagnosticJSON: crash)
        #expect(store.snapshot.reports.count == 1)
    }

    // MARK: The reports

    @Test func aCrashKeepsItsCodesAndFrames() throws {
        let (store, _) = freshStore()
        let many = (0..<40).map { ("Vory", Self.uuid1, 1000 + $0) }
        store.ingest(diagnosticJSON: Self.diagnostic(daysAgo: 1, crashes: [Self.crash(frameList: many)]))
        let r = try #require(store.snapshot.reports.first)
        #expect(r.kind == .crash)
        #expect(r.exceptionType == 1 && r.exceptionCode == 0 && r.signal == 11)
        #expect(r.termination == "SPRINGBOARD 0x8BADF00D")
        #expect(r.appVersion == "1.5.1" && r.appBuild == "52" && r.osVersion == "iPhone OS 26.6.2 (23G93)" && r.device == "iPhone19,2")
        #expect(r.frames.count == 32, "frames are capped at 32")
        #expect(r.frames.first == HealthReportStore.Report.Frame(binary: "Vory", uuid: Self.uuid1, offset: 1000))
        #expect(r.frames.last?.offset == 1031)
    }

    @Test func aFreezeKeepsItsLength() throws {
        let (store, _) = freshStore()
        store.ingest(diagnosticJSON: Self.diagnostic(daysAgo: 1, hangs: [Self.hang("1.5 sec", frameList: [("Vory", Self.uuid1, 7)])]))
        let r = try #require(store.snapshot.reports.first)
        #expect(r.kind == .freeze)
        #expect(r.freezeSeconds == 1.5)
        #expect(r.appVersion == "1.5.1" && r.appBuild == "52")
    }

    @Test func oldReportsGo() {
        let (store, _) = freshStore()
        store.ingest(diagnosticJSON: Self.diagnostic(daysAgo: 40, crashes: [Self.crash(frameList: [("Vory", Self.uuid1, 40)])]))
        for d in 0..<25 {
            store.ingest(diagnosticJSON: Self.diagnostic(daysAgo: Double(d), crashes: [Self.crash(frameList: [("Vory", Self.uuid1, d)])]))
        }
        store.ingest(metricJSON: Self.metric(daysAgo: 40, foreground: ["cumulativeNormalAppExitCount": 1], background: [:]))
        store.ingest(metricJSON: Self.metric(daysAgo: 1, foreground: ["cumulativeNormalAppExitCount": 1], background: [:]))
        let s = store.snapshot
        #expect(s.reports.count == 20, "at most 20 reports")
        #expect(s.reports.map { $0.frames.first?.offset } == (0..<20).reversed().map { Optional($0) }, "the newest 20, oldest first")
        #expect(s.windows.count == 1, "a window older than 30 days goes")
    }

    // MARK: Where it lives

    @Test func theStoreStaysOnTheDevice() throws {
        #expect(HealthReportStore.standardURL.path.hasSuffix("/Library/Application Support/Vory/health-reports.json"))
        let (store, url) = freshStore()
        store.ingest(metricJSON: Self.metric(daysAgo: 1, foreground: ["cumulativeNormalAppExitCount": 1], background: [:]))
        let values = try url.resourceValues(forKeys: [.isExcludedFromBackupKey])
        #expect(values.isExcludedFromBackup == true, "the file is left out of backups")
    }

    // MARK: The copy

    @Test func theCopyTextReadsPlainly() {
        let (store, _) = freshStore()
        store.ingest(metricJSON: Self.metric(daysAgo: 1, foreground: ["cumulativeAppWatchdogExitCount": 1, "cumulativeBadAccessExitCount": 2],
                                             background: ["cumulativeMemoryResourceLimitExitCount": 3, "cumulativeNormalAppExitCount": 4]))
        store.ingest(diagnosticJSON: Self.diagnostic(daysAgo: 1, crashes: [Self.crash(frameList: [("Vory", Self.uuid1, 1234), ("UIKitCore", Self.uuid2, 5678)])],
                                                     hangs: [Self.hang("1.5 sec", frameList: [("Vory", Self.uuid1, 1234)])]))
        #expect(store.copyText() == """
        Vory crash and freeze reports, kept on this device
        Counts from 2026-11-07 to 2026-11-08
        Closed while you were using it: took too long to respond 1, crashed (bad access) 2
        Closed in the background: ran out of memory 3, closed normally 4
        Crash on 2026-11-08: Vory 1.5.1 (52), iPhone OS 26.6.2 (23G93), iPhone19,2
          exception type 1, code 0, signal 11, SPRINGBOARD 0x8BADF00D
          Vory \(Self.uuid1) +1234
          UIKitCore \(Self.uuid2) +5678
        Froze for 1.5 seconds on 2026-11-08: Vory 1.5.1 (52), iPhone OS 26.6.2 (23G93), iPhone19,2
          Vory \(Self.uuid1) +1234
        """)
    }
}
