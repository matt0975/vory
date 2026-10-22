import SwiftUI
import VoryCore

/// A voice note a reply hands back: play and pause in place, with its position and a bar to
/// scrub. The file comes through the same cache as a file card; one player is shared, so a
/// second clip replaces the first and the read-aloud voice stops while a clip plays.
struct AudioCard: View {
    var ref: MediaRef
    var profile: String?
    @Environment(AppModel.self) private var model
    @State private var source: FileSource
    #if os(iOS)
    @State private var exporting: URL?
    #endif

    init(ref: MediaRef, profile: String?) {
        self.ref = ref
        self.profile = profile
        _source = State(initialValue: FileSource(ref: ref, profile: profile))
    }

    private static let notConnected = "Vory is not connected to a gateway."

    private var loaded: Bool { ClipPlayer.shared.refID == ref.id }
    private var playing: Bool { loaded && ClipPlayer.shared.isPlaying }
    private var fraction: Double {
        let duration = ClipPlayer.shared.duration
        guard duration > 0 else { return 0 }
        return min(max(ClipPlayer.shared.current / duration, 0), 1)
    }

    var body: some View {
        HStack(spacing: 12) {
            Button { Task { await tap() } } label: {
                ZStack {
                    Circle().fill(Color.accentColor.opacity(0.15)).frame(width: 40, height: 40)
                    if source.fetching {
                        ProgressView().controlSize(.small)
                    } else {
                        Image(systemName: playing ? "pause.fill" : "play.fill")
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundStyle(Color.accentColor)
                            .accessibilityHidden(true)
                    }
                }
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("audio.card")
            .accessibilityLabel(source.failure ?? (playing && loaded ? "Pause \(ref.name)" : "Play \(ref.name)"))

            VStack(alignment: .leading, spacing: 4) {
                Text(ref.name).font(.subheadline.weight(.medium)).lineLimit(1)
                track
                HStack {
                    Text(ClipTime.string(ClipPlayer.shared.current))
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                        .accessibilityIdentifier("audio.elapsed")
                    Spacer()
                    Text(ClipTime.string(ClipPlayer.shared.duration))
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                        .accessibilityIdentifier("audio.duration")
                }
                if let failure = source.failure {
                    Text(failure).font(.caption).foregroundStyle(.red).lineLimit(3)
                } else if source.local == nil, !source.fetching {
                    Text("Tap to play").font(.caption).foregroundStyle(.secondary)
                }
            }
            .contentShape(.rect)
            .onTapGesture { Task { await tap() } }
            Spacer(minLength: 0)
        }
        .padding(10)
        .frame(maxWidth: 360, alignment: .leading)
        .background(FileCard.cardFill, in: .rect(cornerRadius: 14))
        .contentShape(.rect)
        .contextMenu {
            if let local = source.local {
                ShareLink(item: local, preview: SharePreview(ref.name)) { Label("Share", systemImage: "square.and.arrow.up") }
                #if os(iOS)
                Button { exporting = local } label: { Label("Save to Files", systemImage: "folder") }
                #else
                Button { save(local) } label: { Label("Save to Downloads", systemImage: "square.and.arrow.down") }
                #endif
            } else {
                Button { Task { await download() } } label: { Label("Download", systemImage: "arrow.down.circle") }
            }
        }
        #if os(iOS)
        .background { FilesExporter(url: $exporting) }
        #endif
        .task(id: ref.id) {
            guard let rt = model.runtime else { return }
            await source.loadCached(gateway: rt.connection.id.uuidString)
        }
    }

    private var track: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(.quaternary)
                Capsule().fill(Color.accentColor).frame(width: geo.size.width * CGFloat(fraction))
            }
            .contentShape(.rect)
            .simultaneousGesture(
                DragGesture(minimumDistance: 0, coordinateSpace: .local)
                    .onChanged { v in
                        let duration = ClipPlayer.shared.duration
                        guard source.local != nil, duration > 0 else { return }
                        let f = min(max(Double(v.location.x) / max(Double(geo.size.width), 1), 0), 1)
                        ClipPlayer.shared.seek(to: f * duration)
                    }
            )
        }
        .frame(height: 4)
    }

    private func tap() async {
        if let local = source.local {
            ClipPlayer.shared.toggle(ref: ref.id, file: local, name: ref.name)
            return
        }
        guard let rt = model.runtime else { source.setFailure(Self.notConnected); return }
        await source.ensure(runtime: rt)
        if let local = source.local { ClipPlayer.shared.toggle(ref: ref.id, file: local, name: ref.name) }
    }

    private func download() async {
        guard let rt = model.runtime else { source.setFailure(Self.notConnected); return }
        await source.ensure(runtime: rt)
    }

    #if os(macOS)
    private func save(_ url: URL) {
        do { MediaSave.showInFinder(try MediaSave.toDownloads(url, name: ref.name)) }
        catch { MediaSave.explainFailure(name: ref.name, error: error) }
    }
    #endif
}