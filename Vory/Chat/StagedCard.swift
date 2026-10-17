import QuickLookThumbnailing
import SwiftUI
import UniformTypeIdentifiers
import VoryCore

/// A staged attachment in the composer: a square card with a real preview of the file (the
/// photo itself, or the document's first page rendered by Quick Look), the kind on a small pill
/// along the bottom edge and a remove button on the top corner.
struct StagedCard: View {
    var attachment: AttachmentPreview
    var onOpen: () -> Void
    var onRemove: () -> Void
    @State private var thumbnail: UIImage?
    @Environment(\.displayScale) private var displayScale

    static let side: CGFloat = 92

    /// What the pill says: the broad kind, with text files called out (a long paste becomes one).
    private var label: String {
        switch attachment.kind {
        case .image: return "Image"
        case .pdf: return "PDF"
        case .audio: return "Audio"
        case .video: return "Video"
        case .file:
            let ext = (attachment.name as NSString).pathExtension.lowercased()
            if let t = UTType(filenameExtension: ext), t.conforms(to: .text) || t.conforms(to: .sourceCode) { return "Text" }
            return ext.isEmpty ? "File" : ext.uppercased()
        }
    }

    private var symbol: String {
        switch attachment.kind {
        case .image: return "photo"
        case .pdf: return "doc.richtext"
        case .audio: return "waveform"
        case .video: return "video"
        case .file: return "doc.text"
        }
    }

    var body: some View {
        ZStack(alignment: .topTrailing) {
            Button(action: onOpen) {
                ZStack {
                    RoundedRectangle(cornerRadius: 18).fill(Color(.secondarySystemGroupedBackground))
                    if let thumbnail {
                        if attachment.kind == .image || attachment.kind == .video {
                            Image(uiImage: thumbnail).resizable().scaledToFill()
                        } else {
                            // A document: the page on its own paper, inset like a sheet on a desk.
                            Image(uiImage: thumbnail).resizable().scaledToFit()
                                .clipShape(.rect(cornerRadius: 4))
                                .shadow(color: .black.opacity(0.12), radius: 2, y: 1)
                                .padding(.horizontal, 16).padding(.top, 10).padding(.bottom, 14)
                        }
                    } else {
                        Image(systemName: symbol).font(.system(size: 28, weight: .light)).foregroundStyle(.secondary)
                    }
                }
                .frame(width: Self.side, height: Self.side)
                .clipShape(.rect(cornerRadius: 18))
                .overlay(RoundedRectangle(cornerRadius: 18).strokeBorder(Color.primary.opacity(0.08), lineWidth: 1))
                .overlay(alignment: .bottom) {
                    Text(label)
                        .font(.caption.weight(.semibold))
                        .padding(.horizontal, 12).padding(.vertical, 5)
                        .voryGlassEffect(.regular, in: .capsule)
                        .offset(y: 6)
                }
            }
            .buttonStyle(.plain)
            .accessibilityLabel("\(label): \(attachment.name)")
            Button(action: onRemove) {
                Image(systemName: "xmark")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: 24, height: 24)
                    .background(Circle().fill(.black.opacity(0.75)))
                    .overlay(Circle().strokeBorder(.white.opacity(0.9), lineWidth: 1.5))
            }
            .buttonStyle(.plain)
            .offset(x: 6, y: -6)
            .accessibilityLabel("Remove \(attachment.name)")
        }
        .padding(.top, 6).padding(.trailing, 6).padding(.bottom, 8)
        .task(id: attachment.id) { await loadThumbnail() }
    }

    private func loadThumbnail() async {
        guard let url = attachment.localURL else { return }
        if attachment.kind == .image, let img = UIImage(contentsOfFile: url.path) {
            thumbnail = img.preparingThumbnail(of: CGSize(width: Self.side * displayScale, height: Self.side * displayScale)) ?? img
            return
        }
        // Quick Look draws the first page of a PDF, a text file's opening lines, a video frame.
        let size = CGSize(width: Self.side * 2, height: Self.side * 2)
        let request = QLThumbnailGenerator.Request(fileAt: url, size: size, scale: displayScale, representationTypes: .thumbnail)
        if let rep = try? await QLThumbnailGenerator.shared.generateBestRepresentation(for: request) {
            thumbnail = rep.uiImage
        }
    }
}
