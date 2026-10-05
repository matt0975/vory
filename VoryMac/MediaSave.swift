import AppKit
import CoreTransferable
import UniformTypeIdentifiers
import VoryCore

/// A picture from a chat as something to share: the original file, fetched from the gateway
/// when the share happens if it is not here yet.
struct MediaFile: Transferable {
    var ref: MediaRef
    var profile: String?

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(exportedContentType: .image) { item in
            guard let rt = await AppModel.shared.runtime else { throw HermesAPIError.transport("Connect a gateway first.") }
            let url = try await MediaStore.shared.localURL(for: item.ref, gateway: rt.connection.id.uuidString, api: GatewayMediaAPI(api: rt.api, profile: item.profile))
            return SentTransferredFile(url)
        }
    }
}

/// Pictures leaving the app on the Mac: saved to Downloads under their own name (never over
/// an existing file), shown in the Finder, copied to the pasteboard, or dragged out as the
/// original file, fetched from the gateway on the drop when it is not here yet.
enum MediaSave {
    /// The name a file gets in `folder`: its own, or with " 2", " 3"… before the extension
    /// when that name is taken, the way the Finder does it.
    static func uniqueName(_ name: String, taken: (String) -> Bool) -> String {
        guard taken(name) else { return name }
        let ext = (name as NSString).pathExtension
        let stem = ext.isEmpty ? name : (name as NSString).deletingPathExtension
        var n = 2
        while true {
            let candidate = ext.isEmpty ? "\(stem) \(n)" : "\(stem) \(n).\(ext)"
            if !taken(candidate) { return candidate }
            n += 1
        }
    }

    /// Copies the original file into ~/Downloads and returns where it landed.
    static func toDownloads(_ file: URL, name: String) throws -> URL {
        let folder = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Downloads")
        let safe = name.replacingOccurrences(of: "/", with: "-").trimmingCharacters(in: .whitespaces)
        let final = uniqueName(safe.isEmpty ? file.lastPathComponent : safe) { FileManager.default.fileExists(atPath: folder.appendingPathComponent($0).path) }
        let destination = folder.appendingPathComponent(final)
        try FileManager.default.copyItem(at: file, to: destination)
        return destination
    }

    static func showInFinder(_ url: URL) {
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    /// The picture on the pasteboard, as an image.
    @discardableResult
    static func copyImage(at url: URL) -> Bool {
        guard let image = NSImage(contentsOf: url) else { return false }
        let pb = NSPasteboard.general
        pb.clearContents()
        return pb.writeObjects([image])
    }

    /// What a drag hands over: the file as it is here, or fetched from the gateway on the drop.
    @MainActor
    static func dragProvider(for ref: MediaRef, profile: String?) -> NSItemProvider {
        let provider = NSItemProvider()
        provider.suggestedName = ref.name
        let type = UTType(filenameExtension: (ref.name as NSString).pathExtension) ?? .image
        guard let rt = AppModel.shared.runtime else { return provider }
        let gateway = rt.connection.id.uuidString
        let api = GatewayMediaAPI(api: rt.api, profile: profile)
        // The store answers at once for a file already here, and fetches otherwise.
        provider.registerFileRepresentation(forTypeIdentifier: type.identifier, fileOptions: [], visibility: .all) { completion in
            let progress = Progress(totalUnitCount: 1)
            Task {
                do {
                    let url = try await MediaStore.shared.localURL(for: ref, gateway: gateway, api: api)
                    progress.completedUnitCount = 1
                    completion(url, false, nil)
                } catch { completion(nil, false, error) }
            }
            return progress
        }
        return provider
    }
}
