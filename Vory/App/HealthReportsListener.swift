import Foundation
import MetricKit
import VoryCore

/// MetricKit's deliveries into this device's own store (#668): the exit counts, and the crash and freeze reports. The
/// classic MXMetricManager, on every OS version Vory runs on (its headers mark it to be replaced by the Swift MetricManager
/// of iOS and macOS 27; this one adapter is what would change). Registered at launch on both platforms, where the payloads
/// already waiting are read too. Each payload goes to `HealthReportStore` as its JSON, and the store keeps only what its
/// allow-list names. Nothing is sent.
final class HealthReportsListener: NSObject, MXMetricManagerSubscriber, @unchecked Sendable {
    static let shared = HealthReportsListener()
    private let store = HealthReportStore.shared

    /// From the app delegate's launch, once.
    func start() {
        let manager = MXMetricManager.shared
        manager.add(self)
        // The payloads become JSON here, then the store works off the launch's thread.
        let metrics = manager.pastPayloads.map { $0.jsonRepresentation() }
        let diagnostics = manager.pastDiagnosticPayloads.map { $0.jsonRepresentation() }
        guard !metrics.isEmpty || !diagnostics.isEmpty else { return }
        DispatchQueue.global(qos: .utility).async { [store] in
            metrics.forEach { store.ingest(metricJSON: $0) }
            diagnostics.forEach { store.ingest(diagnosticJSON: $0) }
        }
    }

    func didReceive(_ payloads: [MXMetricPayload]) {
        payloads.forEach { store.ingest(metricJSON: $0.jsonRepresentation()) }
    }

    func didReceive(_ payloads: [MXDiagnosticPayload]) {
        payloads.forEach { store.ingest(diagnosticJSON: $0.jsonRepresentation()) }
    }
}
