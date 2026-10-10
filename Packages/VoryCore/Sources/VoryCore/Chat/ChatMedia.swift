import CryptoKit
import Foundation

// MARK: Images in a chat
//
// Three ways an image gets into a conversation, none of which the gateway sends as bytes:
// the person attaches one (the stored user row then reads "[User attached image: <name>]"
// and the file sits in the profile's images dir), the bot sends one back ("MEDIA:/path"
// lines, the gateway's own convention for files in a reply, or a markdown image with a path),
// or a tool returns a path to one. The app finds the references, fetches the bytes through
// the gateway (GET /api/media?path=, else GET /api/files/read?path=), keeps them on disk, and
// shows downsampled thumbnails; the full image is decoded only in the viewer.

/// One picture referred to in the chat.
public struct MediaRef: Hashable, Sendable, Identifiable {
    /// Absolute paths on the gateway (several when the exact directory is a guess).
    public var candidates: [String]
    public var name: String
    public var id: String { candidates.first ?? name }

    public init(candidates: [String], name: String? = nil) {
        self.candidates = candidates
        self.name = name ?? (candidates.first.map { ($0 as NSString).lastPathComponent } ?? "image")
    }
    public init(path: String) { self.init(candidates: [path]) }

    public static let imageExtensions: Set<String> = ["png", "jpg", "jpeg", "gif", "webp", "heic", "heif", "bmp"]
    public static func isImage(_ path: String) -> Bool {
        imageExtensions.contains(((path as NSString).pathExtension).lowercased())
    }
}

public enum MediaScan {
    /// Pictures a reply refers to: `MEDIA:/path` lines, markdown images with a path on the
    /// gateway, and bare absolute paths to image files on their own line.
    public static func images(in text: String) -> [MediaRef] {
        let text = lineFeeds(text)
        var out: [MediaRef] = []
        var seen = Set<String>()
        func add(_ raw: String) {
            let path = clean(raw)
            guard !path.isEmpty, MediaRef.isImage(path), path.hasPrefix("/") || path.hasPrefix("~"), !seen.contains(path) else { return }
            seen.insert(path)
            out.append(MediaRef(path: path))
        }
        for m in text.matches(of: /MEDIA:(\S+)/) { add(String(m.1)) }
        for m in text.matches(of: /!\[[^\]]*\]\(([^)\s]+)\)/) { add(String(m.1)) }
        for line in text.split(separator: "\n") {
            let t = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if t.hasPrefix("/") || t.hasPrefix("~/"), !t.contains(" ") { add(t) }
        }
        return out
    }

    /// A CRLF reply, line by line: "\r\n" is one character to Swift, so a split on "\n" saw
    /// the whole reply as one line and a path on its own line was never found. (The look for
    /// a CR is on the bytes: to `contains`, "\r" is not in "\r\n" either.)
    static func lineFeeds(_ text: String) -> String {
        text.utf8.contains(13) ? text.replacingOccurrences(of: "\r\n", with: "\n") : text
    }

    /// Paths with image extensions anywhere in a tool's output (a screenshot tool's result, say).
    public static func imagePaths(inToolOutput text: String) -> [MediaRef] {
        var out: [MediaRef] = []
        var seen = Set<String>()
        for m in text.matches(of: /(?:^|[\s"'`(=:])((?:~|\/)[^\s"'`)<>]+\.(?:png|jpe?g|gif|webp|heic|heif|bmp))/.ignoresCase()) {
            let path = clean(String(m.1))
            guard !seen.contains(path) else { continue }
            seen.insert(path)
            out.append(MediaRef(path: path))
        }
        return out
    }

    /// The reply with its media lines taken out, for the bubble (the pictures are shown under it).
    public static func textWithoutMedia(_ text: String) -> String {
        var lines: [String] = []
        for raw in lineFeeds(text).split(separator: "\n", omittingEmptySubsequences: false) {
            var line = String(raw)
            line = line.replacing(/\s*MEDIA:\S+/) { _ in "" }
            // A markdown image with a path on the gateway leaves its words behind; one with a
            // web address stays for the markdown to render.
            line = line.replacing(/!\[([^\]]*)\]\(([^)\s]+)\)/) { m in
                let target = String(m.2)
                return target.hasPrefix("/") || target.hasPrefix("~") ? String(m.1) : String(m.0)
            }
            // A link to a file on the gateway leaves its words behind (the card is under the bubble).
            line = line.replacing(/(^|[^!])\[([^\]]*)\]\(<([^>]+)>\)/) { m in
                let lead = String(m.1), words = String(m.2), target = String(m.3)
                return isFilePath(clean(target)) ? lead + words : String(m.0)
            }
            line = line.replacing(/(^|[^!])\[([^\]]*)\]\(([^)\s<]+)\)/) { m in
                let lead = String(m.1), words = String(m.2), target = String(m.3)
                return isFilePath(clean(target)) ? lead + words : String(m.0)
            }
            let t = line.trimmingCharacters(in: .whitespacesAndNewlines)
            // A path with a full stop or a bracket after it is still that path.
            if (t.hasPrefix("/") || t.hasPrefix("~/")), !t.contains(" "), MediaRef.isImage(clean(t)) || isFilePath(clean(t)) { continue }
            if t.isEmpty, !raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { continue }
            lines.append(line)
        }
        var joined = lines.joined(separator: "\n")
        while joined.contains("\n\n\n") { joined = joined.replacingOccurrences(of: "\n\n\n", with: "\n\n") }
        return joined.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Names in a stored user row's "[User attached image: name]" marks (one per picture).
    public static func attachedImageNames(in userText: String) -> [String] {
        userText.matches(of: /\[User attached image: ([^\]]+)\]/).map { String($0.1).trimmingCharacters(in: .whitespaces) }
    }

    /// The user's words without the attachment marks.
    public static func userTextWithoutAttachments(_ text: String) -> String {
        text.replacing(/\s*\[User attached image: [^\]]+\]/) { _ in "" }.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Where an attached image lives on the gateway: the profile's images dir
    /// (tui_gateway/prompt_attachments.py `_session_images_dir`), under the Hermes home. The
    /// exact home is the gateway's; these are the usual places, tried in order.
    public static func attachedImageRef(name: String, profile: String?) -> MediaRef {
        var candidates: [String] = []
        if let p = profile, !p.isEmpty, p != "default" { candidates.append("~/.hermes/profiles/\(p)/images/\(name)") }
        candidates.append("~/.hermes/images/\(name)")
        candidates.append("~/.hermes/profiles/default/images/\(name)")
        return MediaRef(candidates: candidates, name: name)
    }

    // MARK: Files a reply names (#309)

    /// Files a reply refers to that are not pictures: `MEDIA:/path` lines, markdown links with
    /// a path on the gateway (`[name](/path)`, or `[name](</a path with spaces.csv>)`), and bare
    /// absolute paths on their own line. A path counts only with a file name and an extension
    /// (a bare folder, or a word that merely starts with a slash, does not); the same file
    /// named twice is one card. Pictures are left to `images(in:)`.
    public static func files(in text: String) -> [MediaRef] {
        let text = lineFeeds(text)
        var out: [MediaRef] = []
        var seen = Set<String>()
        func add(_ raw: String, name: String? = nil) {
            let path = clean(raw)
            guard isFilePath(path), !MediaRef.isImage(path), !seen.contains(path) else { return }
            seen.insert(path)
            out.append(MediaRef(candidates: [path], name: name?.isEmpty == false ? name : nil))
        }
        for m in text.matches(of: /MEDIA:(\S+)/) { add(String(m.1)) }
        // A link's target in angle brackets may hold spaces; a plain one stops at a space.
        // Not an image's "![": the character before the bracket is matched and left alone.
        for m in text.matches(of: /(?:^|[^!])\[([^\]]*)\]\(<([^>]+)>\)/) { add(String(m.2)) }
        for m in text.matches(of: /(?:^|[^!])\[([^\]]*)\]\(([^)\s<]+)\)/) {
            let target = String(m.2)
            add(target.removingPercentEncoding ?? target)
        }
        for line in text.split(separator: "\n") {
            let t = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if t.hasPrefix("/") || t.hasPrefix("~/"), !t.contains(" ") { add(t) }
        }
        return out
    }

    /// An absolute path on the gateway to a named file: starts at the root or the home, ends in
    /// a name with an extension of one to six letters or digits, and is not a web address.
    public static func isFilePath(_ path: String) -> Bool {
        guard path.hasPrefix("/") || path.hasPrefix("~/"), !path.hasSuffix("/"), !path.contains("://") else { return false }
        let name = (path as NSString).lastPathComponent
        let ext = (name as NSString).pathExtension
        guard !ext.isEmpty, ext.count <= 6, ext.allSatisfy({ $0.isLetter || $0.isNumber }), name.count > ext.count + 1 else { return false }
        return true
    }

    /// The kind a file card shows, by extension.
    public enum FileKind: String, Sendable {
        case pdf, table, archive, audio, video, text, code, other
        public static func of(_ name: String) -> FileKind {
            switch ((name as NSString).pathExtension).lowercased() {
            case "pdf": return .pdf
            case "csv", "tsv", "xls", "xlsx", "numbers": return .table
            case "zip", "gz", "tgz", "tar", "7z", "bz2", "xz", "dmg": return .archive
            case "mp3", "m4a", "wav", "aac", "flac", "ogg", "opus", "aiff": return .audio
            case "mp4", "mov", "m4v", "webm", "mkv", "avi": return .video
            case "txt", "md", "markdown", "log", "rtf", "json", "yaml", "yml", "toml", "xml", "html", "htm": return .text
            case "swift", "py", "js", "ts", "rb", "go", "rs", "c", "h", "cpp", "java", "kt", "sh", "sql", "css": return .code
            default: return .other
            }
        }
    }

    static func clean(_ raw: String) -> String {
        var s = raw.trimmingCharacters(in: .whitespaces)
        while let last = s.last, ".,;:)]}>\"'`".contains(last) { s.removeLast() }
        while let first = s.first, "\"'`<([".contains(first) { s.removeFirst() }
        return s
    }
}

/// The gateway's picture routes. GET /api/media?path= (hermes_cli/web_routers/files.py) serves
/// an image under the Hermes home as a data URL; /api/files/read does the same for a readable
/// file anywhere the gateway allows. Both are size-capped by the gateway.
public struct GatewayMediaAPI: Sendable {
    let api: HermesAPI
    public var profile: String?
    public init(api: HermesAPI, profile: String? = nil) { self.api = api; self.profile = profile }

    struct DataURLReply: Decodable { var data_url: String? ; var dataUrl: String?; var size: Int?; var mime_type: String? }

    /// The bytes of one picture, by the first candidate path the gateway can serve.
    public func fetch(_ ref: MediaRef) async throws -> (Data, String) {
        var lastError: Error = HermesAPIError.transport("No path to try.")
        for path in ref.candidates {
            do { return (try await fetch(path: path), path) } catch { lastError = error }
        }
        throw lastError
    }

    public func fetch(path: String) async throws -> Data {
        let q = [URLQueryItem(name: "path", value: path)]
        do {
            let r: DataURLReply = try await api.get("/api/media", query: q, profile: profile)
            if let d = decode(r) { return d }
        } catch let e as HermesAPIError {
            // Outside the media roots: the files route may still read it.
            if case .http(let status, _) = e, status != 403, status != 404, status != 415 { throw e }
        }
        let r: DataURLReply = try await api.get("/api/files/read", query: q, profile: profile)
        guard let d = decode(r) else { throw HermesAPIError.transport("The gateway sent no image data.") }
        return d
    }

    private func decode(_ r: DataURLReply) -> Data? {
        guard let url = r.data_url ?? r.dataUrl else { return nil }
        return GatewayVoiceAPI.Speech.decode(dataURL: url)
    }
}

/// Pictures fetched once and kept on disk (the caches directory; the system may clear it),
/// keyed by gateway and path. One download per picture however many rows show it.
public actor MediaStore {
    public static let shared = MediaStore()
    private var inflight: [String: Task<URL, Error>] = [:]
    private let directory: URL

    public init() {
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first ?? FileManager.default.temporaryDirectory
        directory = base.appendingPathComponent("vory-media", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    public nonisolated static func key(gateway: String, path: String) -> String {
        let digest = SHA256.hash(data: Data((gateway + "|" + path).utf8))
        return digest.prefix(16).map { String(format: "%02x", $0) }.joined()
    }

    /// The picture's file on disk, fetched through `api` the first time.
    public func localURL(for ref: MediaRef, gateway: String, api: GatewayMediaAPI) async throws -> URL {
        for path in ref.candidates {
            let url = file(gateway: gateway, path: path)
            if FileManager.default.fileExists(atPath: url.path) { return url }
        }
        let token = gateway + "|" + ref.id
        if let t = inflight[token] { return try await t.value }
        let task = Task<URL, Error> {
            let (data, path) = try await api.fetch(ref)
            let url = file(gateway: gateway, path: path)
            try data.write(to: url, options: .atomic)
            return url
        }
        inflight[token] = task
        defer { inflight[token] = nil }
        return try await task.value
    }

    /// Already fetched? The file, without a network round trip.
    public func cached(_ ref: MediaRef, gateway: String) -> URL? {
        for path in ref.candidates {
            let url = file(gateway: gateway, path: path)
            if FileManager.default.fileExists(atPath: url.path) { return url }
        }
        return nil
    }

    private func file(gateway: String, path: String) -> URL {
        let ext = ((path as NSString).pathExtension).lowercased()
        return directory.appendingPathComponent(Self.key(gateway: gateway, path: path) + (ext.isEmpty ? "" : "." + ext))
    }
}
