import QuickLook
import SwiftUI
import UniformTypeIdentifiers
import VoryCore
#if os(iOS)
import UIKit
#endif

/// Files a reply hands back that are not pictures (#309): one card each under the reply, with
/// the file's kind, its name and its size once it is here. A tap fetches the file through the
/// gateway (the same route pictures use, kept in the same cache) and opens it in Quick Look;
/// a long press or the Mac's right-click offers Share and, on the iPhone, Save to Files (the
/// Mac has Save to Downloads). Only the paths the reply itself names are ever fetched.
struct FileCardStrip: View {
    var refs: [MediaRef]
    var profile: String?
    var alignment: HorizontalAlignment = .leading
    @State private var preview: URL?

    var body: some View {
        VStack(alignment: alignment, spacing: 8) {
            ForEach(Array(refs.prefix(12))) { ref in
                FileCard(ref: ref, profile: profile) { preview = $0 }
            }
        }
        .frame(maxWidth: .infinity, alignment: alignment == .trailing ? .trailing : .leading)
        .quickLookPreview($preview)
    }
}

struct FileCard: View {
    var ref: MediaRef
    var profile: String?
    var onOpen: (URL) -> Void
    @Environment(AppModel.self) private var model
    @State private var local: URL?
    @State private var fetching = false
    @State private var failure: String?
    #if os(iOS)
    @State private var exporting: URL?
    #endif

    private var kind: MediaScan.FileKind { MediaScan.FileKind.of(ref.name) }
    private var symbol: String {
        switch kind {
        case .pdf: "doc.richtext"
        case .table: "tablecells"
        case .archive: "archivebox"
        case .audio: "waveform"
        case .video: "film"
        case .text: "doc.text"
        case .code: "chevron.left.forwardslash.chevron.right"
        case .other: "doc"
        }
    }
    private var line: String {
        if let failure { return failure }
        if fetching { return "Downloading…" }
        if let local, let size = try? FileManager.default.attributesOfItem(atPath: local.path)[.size] as? Int {
            return ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .file)
        }
        return "Tap to download"
    }

    var body: some View {
        Button { Task { await open() } } label: {
            HStack(spacing: 12) {
                ZStack {
                    RoundedRectangle(cornerRadius: 10).fill(Color.accentColor.opacity(0.15)).frame(width: 40, height: 40)
                    if fetching { ProgressView().controlSize(.small) }
                    else { Image(systemName: symbol).font(.system(size: 18, weight: .semibold)).foregroundStyle(Color.accentColor) }
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text(ref.name).font(.subheadline.weight(.medium)).lineLimit(2).multilineTextAlignment(.leading)
                    Text(line).font(.caption).foregroundStyle(failure == nil ? AnyShapeStyle(.secondary) : AnyShapeStyle(.red)).lineLimit(3).multilineTextAlignment(.leading)
                }
                Spacer(minLength: 0)
            }
            .padding(10)
            .frame(maxWidth: 360, alignment: .leading)
            .background(Self.cardFill, in: .rect(cornerRadius: 14))
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("File \(ref.name), \(line)")
        .accessibilityHint("Opens it")
        .accessibilityIdentifier("file.card")
        .contextMenu {
            if let local {
                ShareLink(item: local, preview: SharePreview(ref.name)) { Label("Share", systemImage: "square.and.arrow.up") }
                #if os(iOS)
                Button { exporting = local } label: { Label("Save to Files", systemImage: "folder") }
                #else
                Button { save(local) } label: { Label("Save to Downloads", systemImage: "square.and.arrow.down") }
                #endif
            } else {
                Button { Task { await fetch() } } label: { Label("Download", systemImage: "arrow.down.circle") }
            }
        }
        #if os(iOS)
        .background { FilesExporter(url: $exporting) }
        #endif
        #if os(macOS)
        .onDrag { local.map { NSItemProvider(contentsOf: $0) ?? NSItemProvider() } ?? NSItemProvider() }
        #endif
        .task(id: ref.id) {
            guard let rt = model.runtime else { return }
            if let cached = await MediaStore.shared.cached(ref, gateway: rt.connection.id.uuidString) { local = Self.named(cached, as: ref.name) }
        }
    }

    private static var cardFill: Color {
        #if os(iOS)
        Color(.secondarySystemBackground)
        #else
        Color(nsColor: .controlBackgroundColor)
        #endif
    }

    private func open() async {
        if local == nil { await fetch() }
        if let local { onOpen(local) }
    }

    /// The cache keeps a file under a hash; the preview, Share and Save show the file's own
    /// name, so a copy lives under it (once; the same bytes).
    static func named(_ cached: URL, as name: String) -> URL {
        let dir = cached.deletingLastPathComponent().appendingPathComponent("named", isDirectory: true)
            .appendingPathComponent(cached.deletingPathExtension().lastPathComponent, isDirectory: true)
        let url = dir.appendingPathComponent(name)
        if !FileManager.default.fileExists(atPath: url.path) {
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try? FileManager.default.copyItem(at: cached, to: url)
        }
        return FileManager.default.fileExists(atPath: url.path) ? url : cached
    }

    /// Through the gateway, into the media cache; a refusal is said in plain words.
    private func fetch() async {
        guard !fetching else { return }
        guard let rt = model.runtime else { failure = "Vory is not connected to a gateway."; return }
        fetching = true; failure = nil
        defer { fetching = false }
        do {
            let cached = try await MediaStore.shared.localURL(for: ref, gateway: rt.connection.id.uuidString, api: GatewayMediaAPI(api: rt.api, profile: profile))
            local = Self.named(cached, as: ref.name)
        } catch {
            failure = FileFetchFailure.describe(error, name: ref.name)
        }
    }

    #if os(macOS)
    private func save(_ url: URL) {
        do { MediaSave.showInFinder(try MediaSave.toDownloads(url, name: ref.name)) }
        catch { MediaSave.explainFailure(name: ref.name, error: error) }
    }
    #endif
}

/// Why a file did not come, in plain words (the style of the attachment refusals, #284).
enum FileFetchFailure {
    static func describe(_ error: Error, name: String) -> String {
        if let e = error as? HermesAPIError, case .http(let status, _) = e {
            switch status {
            case 403, 401: return "The gateway did not allow reading \(name)."
            case 404: return "\(name) is no longer on the gateway."
            case 413: return "\(name) is too large for the gateway to send."
            default: break
            }
        }
        if let e = error as? HermesAPIError, case .transport = e { return "Vory could not reach the gateway for \(name)." }
        if let e = error as? URLError, [.notConnectedToInternet, .networkConnectionLost, .cannotConnectToHost, .timedOut].contains(e.code) {
            return "Vory is offline; \(name) will download when the gateway is reachable."
        }
        return "\(name) could not be downloaded: \(error.localizedDescription)"
    }
}

#if os(iOS)
/// The system's Save to Files sheet for one file already on this device.
struct FilesExporter: UIViewControllerRepresentable {
    @Binding var url: URL?

    func makeUIViewController(context: Context) -> UIViewController { UIViewController() }

    func updateUIViewController(_ host: UIViewController, context: Context) {
        guard let url, context.coordinator.presented != url else { return }
        context.coordinator.presented = url
        let picker = UIDocumentPickerViewController(forExporting: [url], asCopy: true)
        picker.delegate = context.coordinator
        host.present(picker, animated: true)
    }

    func makeCoordinator() -> Coordinator { Coordinator(url: $url) }

    final class Coordinator: NSObject, UIDocumentPickerDelegate {
        var url: Binding<URL?>
        var presented: URL?
        init(url: Binding<URL?>) { self.url = url }
        func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) { url.wrappedValue = nil; presented = nil }
        func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) { url.wrappedValue = nil; presented = nil }
    }
}
#endif
