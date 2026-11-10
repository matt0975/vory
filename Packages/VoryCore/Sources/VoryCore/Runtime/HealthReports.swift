import Foundation

/// MetricKit's exit counts and crash and freeze reports (#668), kept on this device only and shown in Settings ›
/// Troubleshooting with Copy. Nothing here sends anything anywhere.
///
/// The app's listener hands this store each payload's `jsonRepresentation()`, from the classic MetricKit (MXMetricManager,
/// on every OS version Vory runs on; the headers mark it to be replaced by the Swift MetricManager of iOS and macOS 27, and
/// moving later is one adapter, since nothing here depends on either API).
///
/// Only allow-listed keys are read, and each kept value is reduced to what it must look like, so nothing a payload carries
/// besides counts, codes, versions and frames reaches the file or the copy: no exception message or argument, no region,
/// no memory-region text (it can hold file paths), no key nobody knows yet. A value that isn't what its field holds is
/// kept as "?".
public final class HealthReportStore: @unchecked Sendable {
    /// Why the system ended the app, by MetricKit's own counts, in the order they're shown: the problems first, a normal
    /// close last.
    public enum ExitReason: String, Codable, CaseIterable, Sendable {
        case memoryLimit, cpuLimit, watchdog, badAccess, illegalInstruction, abnormal, backgroundTimeout, lockedFile,
             memoryPressure, normal
    }

    /// One payload's counts, for the window it covers.
    public struct ExitWindow: Codable, Sendable, Equatable {
        public var begin: Date
        public var end: Date
        public var foreground: [ExitReason: Int]
        public var background: [ExitReason: Int]
    }

    /// One crash or freeze, as kept.
    public struct Report: Codable, Sendable, Equatable {
        public enum Kind: String, Codable, Sendable { case crash, freeze }
        public struct Frame: Codable, Sendable, Equatable {
            public var binary: String
            public var uuid: String
            public var offset: Int
        }
        public var kind: Kind
        public var date: Date
        public var appVersion: String
        public var appBuild: String
        public var osVersion: String
        public var device: String
        public var exceptionType: Int?
        public var exceptionCode: Int?
        public var signal: Int?
        /// The termination reason's namespace and code only ("SPRINGBOARD 0x8BADF00D").
        public var termination: String?
        public var freezeSeconds: Double?
        public var frames: [Frame]
    }

    /// What the store holds, newest last.
    public struct Snapshot: Codable, Sendable, Equatable {
        public var windows: [ExitWindow] = []
        public var reports: [Report] = []
        public init() {}
        /// Each reason's count over every window kept (reasons at zero left out).
        public var foreground: [ExitReason: Int] { Self.sum(windows.map(\.foreground)) }
        public var background: [ExitReason: Int] { Self.sum(windows.map(\.background)) }
        private static func sum(_ all: [[ExitReason: Int]]) -> [ExitReason: Int] {
            all.reduce(into: [:]) { total, counts in for (r, n) in counts where n > 0 { total[r, default: 0] += n } }
        }
    }

    /// The app's own store (`standardURL`).
    public static let shared = HealthReportStore()

    /// Where the app keeps it: Application Support/Vory/health-reports.json, left out of backups.
    public static var standardURL: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        return base.appendingPathComponent("Vory", isDirectory: true).appendingPathComponent("health-reports.json")
    }

    static let keepDays: Double = 30, maxReports = 20, maxWindows = 60, maxFrames = 32

    private let url: URL?
    private let now: @Sendable () -> Date
    private let lock = NSLock()
    private var state: Snapshot

    /// `url` nil keeps it in memory only (the UI tests' fixture).
    public init(url: URL? = HealthReportStore.standardURL, now: @escaping @Sendable () -> Date = { Date() }) {
        self.url = url
        self.now = now
        if let url, let data = try? Data(contentsOf: url), let saved = try? JSONDecoder().decode(Snapshot.self, from: data) {
            state = saved
        } else {
            state = Snapshot()
        }
    }

    public var snapshot: Snapshot {
        lock.lock(); defer { lock.unlock() }
        return state
    }

    // MARK: Intake

    /// The exit-count keys MetricKit writes, by reason (MXForegroundExitData's six, MXBackgroundExitData's ten).
    private static let foregroundKeys: [String: ExitReason] = [
        "cumulativeNormalAppExitCount": .normal, "cumulativeMemoryResourceLimitExitCount": .memoryLimit,
        "cumulativeBadAccessExitCount": .badAccess, "cumulativeAbnormalExitCount": .abnormal,
        "cumulativeIllegalInstructionExitCount": .illegalInstruction, "cumulativeAppWatchdogExitCount": .watchdog,
    ]
    private static let backgroundKeys: [String: ExitReason] = foregroundKeys.merging([
        "cumulativeCPUResourceLimitExitCount": .cpuLimit, "cumulativeMemoryPressureExitCount": .memoryPressure,
        "cumulativeSuspendedWithLockedFileExitCount": .lockedFile,
        "cumulativeBackgroundTaskAssertionTimeoutExitCount": .backgroundTimeout,
    ]) { a, _ in a }

    /// A metric payload's `jsonRepresentation()`: its exit counts, for its window. A window already kept isn't counted again.
    public func ingest(metricJSON: Data) {
        guard let o = (try? JSONSerialization.jsonObject(with: metricJSON)) as? [String: Any],
              let begin = Self.date(o["timeStampBegin"]), let end = Self.date(o["timeStampEnd"]),
              let exits = o["applicationExitMetrics"] as? [String: Any] else { return }
        let window = ExitWindow(begin: begin, end: end, foreground: Self.counts(exits["foregroundExitData"], Self.foregroundKeys),
                                background: Self.counts(exits["backgroundExitData"], Self.backgroundKeys))
        change { s in
            if !s.windows.contains(where: { $0.begin == begin && $0.end == end }) { s.windows.append(window) }
        }
    }

    /// A diagnostic payload's `jsonRepresentation()`: its crashes, then its freezes, each once.
    public func ingest(diagnosticJSON: Data) {
        guard let o = (try? JSONSerialization.jsonObject(with: diagnosticJSON)) as? [String: Any],
              let date = Self.date(o["timeStampEnd"]) ?? Self.date(o["timeStampBegin"]) else { return }
        let crashes = (o["crashDiagnostics"] as? [[String: Any]] ?? []).map { Self.report($0, kind: .crash, date: date) }
        let freezes = (o["hangDiagnostics"] as? [[String: Any]] ?? []).map { Self.report($0, kind: .freeze, date: date) }
        change { s in
            for r in crashes + freezes where !s.reports.contains(r) { s.reports.append(r) }
        }
    }

    private static func counts(_ any: Any?, _ keys: [String: ExitReason]) -> [ExitReason: Int] {
        guard let d = any as? [String: Any] else { return [:] }
        var out: [ExitReason: Int] = [:]
        for (key, reason) in keys { if let n = int(d[key]), n > 0 { out[reason, default: 0] += n } }
        return out
    }

    private static func report(_ d: [String: Any], kind: Report.Kind, date: Date) -> Report {
        let m = d["diagnosticMetaData"] as? [String: Any] ?? [:]
        return Report(kind: kind, date: date,
                      appVersion: kept(m["appVersion"], #"^[0-9][0-9.]{0,15}$"#),
                      appBuild: kept(m["appBuildVersion"], #"^[0-9][0-9.]{0,15}$"#),
                      osVersion: kept(m["osVersion"], #"^(iPhone OS|iPadOS|iOS|macOS|Mac OS X|visionOS) [0-9][0-9.]{0,15}( \([0-9A-Za-z]{1,16}\))?$"#),
                      device: kept(m["deviceType"], #"^[A-Za-z]{2,16}[0-9]{1,3},[0-9]{1,3}$"#),
                      exceptionType: kind == .crash ? int(m["exceptionType"]) : nil,
                      exceptionCode: kind == .crash ? int(m["exceptionCode"]) : nil,
                      signal: kind == .crash ? int(m["signal"]) : nil,
                      termination: kind == .crash ? termination(m["terminationReason"]) : nil,
                      freezeSeconds: kind == .freeze ? seconds(m["hangDuration"]) : nil,
                      frames: frames(d["callStackTree"]))
    }

    // MARK: Reducers (the redaction)

    /// The value when the whole of it matches `pattern`, else "?".
    static func kept(_ any: Any?, _ pattern: String) -> String {
        guard let s = any as? String, s.range(of: pattern, options: .regularExpression) != nil else { return "?" }
        return s
    }

    /// A JSON number as an Int; a string, a bool or anything else is nil.
    static func int(_ any: Any?) -> Int? {
        guard let n = any as? NSNumber, CFGetTypeID(n) != CFBooleanGetTypeID() else { return nil }
        return n.intValue
    }

    /// "Namespace SPRINGBOARD, Code 0x8badf00d, …" → "SPRINGBOARD 0x8BADF00D"; every other character goes.
    static func termination(_ any: Any?) -> String? {
        guard let s = any as? String,
              let r = s.range(of: #"Namespace [A-Z_]{1,32}, Code 0x[0-9A-Fa-f]{1,16}"#, options: .regularExpression) else { return nil }
        let parts = s[r].split(separator: " ")   // ["Namespace", "SPRINGBOARD,", "Code", "0x8badf00d"]
        guard parts.count == 4 else { return nil }
        return "\(parts[1].dropLast()) 0x\(parts[3].dropFirst(2).uppercased())"
    }

    /// "1.5 sec", "250 ms" or "2 min" → seconds.
    static func seconds(_ any: Any?) -> Double? {
        guard let s = any as? String,
              let r = s.range(of: #"^[0-9]{1,6}(\.[0-9]{1,6})? ?(ms|sec|s|min)$"#, options: .regularExpression) else { return nil }
        let text = String(s[r])
        let number = Double(text.prefix { $0.isNumber || $0 == "." }) ?? 0
        if text.hasSuffix("ms") { return number / 1000 }
        if text.hasSuffix("min") { return number * 60 }
        return number
    }

    /// The attributed thread's frames (else the first thread's), depth first, at most `maxFrames`: a binary's name, its
    /// UUID and the offset only. A name that isn't wholly a binary's is "?".
    static func frames(_ any: Any?) -> [Report.Frame] {
        guard let tree = any as? [String: Any], let stacks = tree["callStacks"] as? [[String: Any]], !stacks.isEmpty else { return [] }
        let stack = stacks.first { ($0["threadAttributed"] as? Bool) == true } ?? stacks[0]
        var out: [Report.Frame] = []
        func walk(_ list: Any?) {
            for f in list as? [[String: Any]] ?? [] {
                guard out.count < maxFrames else { return }
                if let offset = int(f["offsetIntoBinaryTextSegment"]) {
                    out.append(.init(binary: kept(f["binaryName"], #"^[A-Za-z0-9._+-]{1,64}$"#),
                                     uuid: kept(f["binaryUUID"], #"^[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}$"#),
                                     offset: offset))
                }
                walk(f["subFrames"])
            }
        }
        walk(stack["callStackRootFrames"])
        return out
    }

    static func date(_ any: Any?) -> Date? {
        guard let s = any as? String else { return nil }
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd HH:mm:ss Z"
        return f.date(from: s) ?? ISO8601DateFormatter().date(from: s)
    }

    // MARK: Keeping

    /// One change, then the order, the limits and the file, under the lock.
    private func change(_ body: (inout Snapshot) -> Void) {
        lock.lock(); defer { lock.unlock() }
        body(&state)
        let cutoff = now().addingTimeInterval(-Self.keepDays * 86_400)
        // Oldest first, the order they came in for the same date.
        state.reports = state.reports.enumerated().sorted { ($0.element.date, $0.offset) < ($1.element.date, $1.offset) }.map(\.element)
        state.reports.removeAll { $0.date < cutoff }
        if state.reports.count > Self.maxReports { state.reports.removeFirst(state.reports.count - Self.maxReports) }
        state.windows = state.windows.enumerated().sorted { ($0.element.end, $0.offset) < ($1.element.end, $1.offset) }.map(\.element)
        state.windows.removeAll { $0.end < cutoff }
        if state.windows.count > Self.maxWindows { state.windows.removeFirst(state.windows.count - Self.maxWindows) }
        save()
    }

    private func save() {
        guard var url, let data = try? JSONEncoder().encode(state) else { return }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        guard (try? data.write(to: url, options: .atomic)) != nil else { return }
        // On the device only: the atomic write makes a new file, so it's marked again each time.
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? url.setResourceValues(values)
    }

    // MARK: Copy

    private static let words: [ExitReason: String] = [
        .memoryLimit: "ran out of memory", .cpuLimit: "used too much processing", .watchdog: "took too long to respond",
        .badAccess: "crashed (bad access)", .illegalInstruction: "crashed (illegal instruction)", .abnormal: "crashed (abnormal exit)",
        .backgroundTimeout: "background time ran out", .lockedFile: "kept a file locked", .memoryPressure: "the system needed memory",
        .normal: "closed normally",
    ]

    /// The page's Copy: plain text, the counts and the reports, nothing else.
    public func copyText() -> String {
        let s = snapshot
        var lines = ["Vory crash and freeze reports, kept on this device"]
        if let first = s.windows.first, let last = s.windows.last {
            lines.append("Counts from \(Self.day(first.begin)) to \(Self.day(last.end))")
        }
        for (title, counts) in [("Closed while you were using it", s.foreground), ("Closed in the background", s.background)] where !counts.isEmpty {
            let parts = ExitReason.allCases.compactMap { r in counts[r].map { "\(Self.words[r] ?? r.rawValue) \($0)" } }
            lines.append("\(title): \(parts.joined(separator: ", "))")
        }
        for r in s.reports {
            // A freeze whose length didn't read says only its day.
            let what = r.kind == .crash ? "Crash on \(Self.day(r.date))"
                : r.freezeSeconds.map { "Froze for \(Self.number($0)) seconds on \(Self.day(r.date))" } ?? "Froze on \(Self.day(r.date))"
            lines.append("\(what): Vory \(r.appVersion) (\(r.appBuild)), \(r.osVersion), \(r.device)")
            var codes: [String] = []
            if let t = r.exceptionType { codes.append("exception type \(t)") }
            if let c = r.exceptionCode { codes.append("code \(c)") }
            if let g = r.signal { codes.append("signal \(g)") }
            if let t = r.termination { codes.append(t) }
            if !codes.isEmpty { lines.append("  " + codes.joined(separator: ", ")) }
            for f in r.frames { lines.append("  \(f.binary) \(f.uuid) +\(f.offset)") }
        }
        return lines.joined(separator: "\n")
    }

    /// A date's day, in UTC, the same on every device.
    static func day(_ d: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX"); f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "yyyy-MM-dd"
        return f.string(from: d)
    }

    static func number(_ x: Double) -> String {
        x == x.rounded() ? String(Int(x)) : String(format: "%.1f", x)
    }
}
