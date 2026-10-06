#if os(iOS)
import Photos
#endif
import SwiftUI
import VoryCore

/// What a row scans for pictures, with a cheap look first: most rows have none, and the rows
/// are evaluated often.
enum TranscriptMedia {
    static func images(in text: String) -> [MediaRef] {
        guard text.contains("MEDIA:") || text.contains("![") || text.contains("\n/") || text.contains("\n~/") || text.hasPrefix("/") || text.hasPrefix("~/")
                || text.contains("\r\n/") || text.contains("\r\n~/") else { return [] }
        return MediaScan.images(in: text)
    }
    static func attachedImages(in text: String, profile: String?) -> [MediaRef] {
        guard text.contains("[User attached image:") else { return [] }
        return MediaScan.attachedImageNames(in: text).map { MediaScan.attachedImageRef(name: $0, profile: profile) }
    }
}

/// The pictures a row refers to, as thumbnails fetched through the gateway: never the full
/// bitmap in the thread (a thread of screenshots is what ran phones out of memory), the file
/// itself only in the viewer. A picture the gateway cannot give shows as its name.
struct MediaThumbStrip: View {
    var refs: [MediaRef]
    var profile: String?
    var side: CGFloat = 150
    var alignment: HorizontalAlignment = .leading
    @State private var viewing: MediaRef?

    var body: some View {
        let shown = Array(refs.prefix(12))
        Group {
            if shown.count <= 2 {
                HStack(spacing: 8) { ForEach(shown) { thumb($0) } }
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) { ForEach(shown) { thumb($0) } }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: alignment == .trailing ? .trailing : .leading)
        .sheet(item: $viewing) { ImageViewerSheet(ref: $0, profile: profile).withAppModel() }
    }

    private func thumb(_ ref: MediaRef) -> some View {
        Button { viewing = ref } label: { MediaThumb(ref: ref, profile: profile, side: side) }
            .buttonStyle(.plain)
            .accessibilityLabel("Image \(ref.name)")
            .accessibilityHint("Opens it full screen")
            #if os(macOS)
            // The Mac: drag the picture out as its original file, or right-click for the rest.
            .onDrag { MediaSave.dragProvider(for: ref, profile: profile) }
            .contextMenu { MacMediaMenu(ref: ref, profile: profile, onOpen: { viewing = ref }) }
            #endif
    }
}

#if os(macOS)
/// A picture's menu on the Mac: open it, save the original to Downloads, copy it, share it.
struct MacMediaMenu: View {
    var ref: MediaRef
    var profile: String?
    var onOpen: () -> Void
    @Environment(AppModel.self) private var model

    var body: some View {
        Button { onOpen() } label: { Label("Open", systemImage: "arrow.up.left.and.arrow.down.right") }
        Button { Task { await save() } } label: { Label("Save to Downloads", systemImage: "square.and.arrow.down") }
        Button { Task { if let url = await file() { MediaSave.copyImage(at: url) } } } label: { Label("Copy Image", systemImage: "doc.on.doc") }
        // The file is handed over when the share happens, fetched then if it is not here yet.
        ShareLink(item: MediaFile(ref: ref, profile: profile), preview: SharePreview(ref.name)) { Label("Share", systemImage: "square.and.arrow.up") }
    }

    /// The original, fetched if it is not here yet.
    private func file() async -> URL? {
        guard let rt = model.runtime else { return nil }
        return try? await MediaStore.shared.localURL(for: ref, gateway: rt.connection.id.uuidString, api: GatewayMediaAPI(api: rt.api, profile: profile))
    }

    private func save() async {
        guard let url = await file(), let saved = try? MediaSave.toDownloads(url, name: ref.name) else { return }
        MediaSave.showInFinder(saved)
    }
}
#endif

struct MediaThumb: View {
    var ref: MediaRef
    var profile: String?
    var side: CGFloat
    @State private var image: UIImage?
    @State private var failed = false

    var body: some View {
        Group {
            if let image {
                Image(uiImage: image).resizable().scaledToFill()
                    .frame(width: side, height: side).clipShape(.rect(cornerRadius: 12))
            } else if failed {
                VStack(spacing: 6) {
                    Image(systemName: "photo").font(.title2).foregroundStyle(.secondary)
                    Text(ref.name).font(.caption2).foregroundStyle(.secondary).lineLimit(2).multilineTextAlignment(.center)
                }
                .padding(8)
                .frame(width: side, height: side)
                .background(Color(.secondarySystemBackground), in: .rect(cornerRadius: 12))
            } else {
                ProgressView().frame(width: side, height: side)
                    .background(Color(.secondarySystemBackground), in: .rect(cornerRadius: 12))
            }
        }
        .task(id: ref.id) { await load() }
    }

    private func load() async {
        guard let rt = AppModel.shared.runtime else { failed = true; return }
        let gateway = rt.connection.id.uuidString
        if let url = await MediaStore.shared.cached(ref, gateway: gateway) {
            image = await AttachmentThumbs.imageAsync(at: url, side: side)
            failed = image == nil
            return
        }
        do {
            let url = try await MediaStore.shared.localURL(for: ref, gateway: gateway, api: GatewayMediaAPI(api: rt.api, profile: profile))
            guard !Task.isCancelled else { return }
            image = await AttachmentThumbs.imageAsync(at: url, side: side)
            failed = image == nil
        } catch {
            failed = true
        }
    }
}

/// One picture, full screen: pinch to zoom, double-tap to zoom in and out, drag when zoomed;
/// Save to Photos and Share. Decoded once here, bounded to a few thousand pixels a side.
struct ImageViewerSheet: View {
    var ref: MediaRef
    var profile: String?
    @Environment(\.dismiss) private var dismiss
    @State private var url: URL?
    @State private var image: UIImage?
    @State private var error: String?
    @State private var scale: CGFloat = 1
    @State private var settledScale: CGFloat = 1
    @State private var offset: CGSize = .zero
    @State private var settledOffset: CGSize = .zero
    @State private var saved = false
    @State private var saving = false

    #if os(iOS)
    private func saveToPhotos(_ url: URL) {
        saving = true
        Task {
            do {
                try await Self.addToPhotos(url)
                saved = true
            } catch {
                self.error = error.localizedDescription
            }
            saving = false
        }
    }

    /// The picture into the library, from outside the main actor. Photos runs the change block
    /// (and answers) on its own queue: written inside the view, the block took the view's main
    /// actor isolation, and Swift's runtime check stopped the app the moment Photos ran it, so
    /// Save to Photos crashed every time.
    nonisolated private static func addToPhotos(_ url: URL) async throws {
        try await PHPhotoLibrary.shared().performChanges {
            _ = PHAssetChangeRequest.creationRequestForAssetFromImage(atFileURL: url)
        }
    }
    #endif

    var body: some View {
        NavigationStack {
            ZStack {
                Color.black.ignoresSafeArea()
                if let image {
                    Image(uiImage: image).resizable().scaledToFit()
                        .scaleEffect(scale)
                        .offset(offset)
                        .gesture(
                            MagnifyGesture()
                                .onChanged { v in scale = max(1, min(6, settledScale * v.magnification)) }
                                .onEnded { _ in settledScale = scale; if scale <= 1 { withAnimation(.snappy) { offset = .zero; settledOffset = .zero } } }
                        )
                        .simultaneousGesture(
                            DragGesture()
                                .onChanged { v in if scale > 1 { offset = CGSize(width: settledOffset.width + v.translation.width, height: settledOffset.height + v.translation.height) } }
                                .onEnded { _ in settledOffset = offset }
                        )
                        .onTapGesture(count: 2) {
                            withAnimation(.snappy) {
                                scale = scale > 1 ? 1 : 2.5
                                settledScale = scale
                                offset = .zero; settledOffset = .zero
                            }
                        }
                        #if os(macOS)
                        // Drag the original file out to the Finder, the Desktop or another app.
                        .onDrag { MediaSave.dragProvider(for: ref, profile: profile) }
                        #endif
                        .accessibilityLabel("Image \(ref.name)")
                } else if let error {
                    VStack(spacing: 8) {
                        Image(systemName: "photo").font(.largeTitle).foregroundStyle(.secondary)
                        Text(ref.name).font(.headline)
                        Text(error).font(.footnote).foregroundStyle(.secondary).multilineTextAlignment(.center)
                    }
                    .padding()
                } else {
                    ProgressView().tint(.white)
                }
            }
            .navigationTitle(ref.name)
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Done") { dismiss() } }
                ToolbarItemGroup(placement: .primaryAction) {
                    #if os(iOS)
                    if let url, image != nil {
                        // The original file goes to Photos, and "Saved" only once Photos has it
                        // (it used to say so before the permission was answered, and saved the
                        // viewer's downsized copy).
                        Button { saveToPhotos(url) } label: {
                            Label(saved ? "Saved" : saving ? "Saving…" : "Save to Photos", systemImage: saved ? "checkmark" : "square.and.arrow.down")
                        }
                        .disabled(saved || saving)
                    }
                    #else
                    // The Mac: the original file into Downloads under its own name, never over
                    // another; then a word that it is there, with the Finder a click away.
                    if let url {
                        if let savedTo {
                            Button { MediaSave.showInFinder(savedTo) } label: { Label("Saved · Show in Finder", systemImage: "checkmark") }
                                .accessibilityIdentifier("media.showInFinder")
                        } else {
                            Button { saveToDownloads(url) } label: { Label("Save to Downloads", systemImage: "square.and.arrow.down") }
                                .accessibilityIdentifier("media.save")
                        }
                    }
                    #endif
                    if let url { ShareLink(item: url) { Label("Share", systemImage: "square.and.arrow.up") } }
                }
            }
            .preferredColorScheme(.dark)
        }
        .task { await load() }
    }

    #if os(macOS)
    /// Where the picture was saved this time, for the Show in Finder that follows.
    @State private var savedTo: URL?

    private func saveToDownloads(_ url: URL) {
        do { savedTo = try MediaSave.toDownloads(url, name: ref.name) } catch { self.error = "Could not save: \(error.localizedDescription)" }
    }
    #endif

    private func load() async {
        guard let rt = AppModel.shared.runtime else { error = "Connect a gateway first."; return }
        let gateway = rt.connection.id.uuidString
        do {
            let file = try await MediaStore.shared.localURL(for: ref, gateway: gateway, api: GatewayMediaAPI(api: rt.api, profile: profile))
            url = file
            image = await AttachmentThumbs.imageAsync(at: file, side: 2400)
            if image == nil { error = "This file is not an image the device can show." }
        } catch {
            self.error = "The gateway could not give this file: \(error.localizedDescription)"
        }
    }
}
