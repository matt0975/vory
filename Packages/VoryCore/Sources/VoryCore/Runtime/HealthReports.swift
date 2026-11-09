import Foundation

/// MetricKit's exit counts and crash and freeze reports (#668), kept on this device only and shown in Settings ›
/// Troubleshooting with Copy. Nothing here sends anything anywhere.
///
/// The app's listener hands this store each payload's `jsonRepresentation()`, from the classic MetricKit (MXMetricManager,
/// on every OS version Vory runs on; the headers mark it to be replaced by the Swift MetricManager of iOS and macOS 27, and
/// moving later is one adapter, since nothing here depends on either API).
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
        /// Each reason's count over every window kept.
        public var foreground: [ExitReason: Int] { [:] }
        public var background: [ExitReason: Int] { [:] }
    }

    /// Where the app keeps it: Application Support/Vory/health-reports.json.
    public static var standardURL: URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("health-reports.json")
    }

    private let url: URL
    private let now: @Sendable () -> Date
    private let lock = NSLock()
    private var raw: [String] = []

    public init(url: URL = HealthReportStore.standardURL, now: @escaping @Sendable () -> Date = { Date() }) {
        self.url = url
        self.now = now
    }

    /// A metric payload's `jsonRepresentation()`.
    public func ingest(metricJSON: Data) { keep(metricJSON) }

    /// A diagnostic payload's `jsonRepresentation()`.
    public func ingest(diagnosticJSON: Data) { keep(diagnosticJSON) }

    public var snapshot: Snapshot { Snapshot() }

    /// The page's Copy: plain text.
    public func copyText() -> String {
        lock.lock(); defer { lock.unlock() }
        return raw.joined(separator: "\n")
    }

    private func keep(_ data: Data) {
        lock.lock(); defer { lock.unlock() }
        raw.append(String(decoding: data, as: UTF8.self))
        try? JSONEncoder().encode(raw).write(to: url, options: .atomic)
    }
}
