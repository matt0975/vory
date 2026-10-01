import QuickLook
import SwiftUI
import UniformTypeIdentifiers
import VoryCore

/// Browse the gateway's managed files (`/api/files`), preview with Quick Look, upload from Files.
struct FilesView: View {
    @Environment(AppModel.self) private var model
    @State private var path: String? = nil
    @State private var listing: FilesListing?
    @State private var error: String?
    @State private var loading = false
    @State private var previewURL: URL?
    @State private var downloading: String?
    @State private var showImporter = false
    /// Dotfiles and dot-folders are noise most of the time (.git, .DS_Store, .env); hidden by
    /// default, shown with the eye in the toolbar. The choice is kept across launches.
    @AppStorage("files.showHidden") private var showHidden = false
    /// Typed path for when the gateway cannot list the current folder (a broken symlink under
    /// the home folder made the whole tab a red line with nowhere to go).
    @State private var goTo = ""
    @State private var triedHomeFallback = false
    /// The listing in flight, so a folder that takes forever (a network mount with thousands of
    /// files; the gateway stats every one) can be given up on.
    @State private var loadTask: Task<FilesListing?, Never>?
    @State private var slow = false
    /// How many entries are drawn; a huge folder is shown in pages so the list stays quick.
    @State private var shownCount = 300

    private var allVisible: [FileEntry] { showHidden ? (listing?.entries ?? []) : (listing?.entries ?? []).filter { !$0.name.hasPrefix(".") } }
    @State private var searchText = ""
    private var visibleEntries: [FileEntry] {
        let all = searchText.isEmpty ? allVisible : allVisible.filter { $0.name.localizedCaseInsensitiveContains(searchText) }
        return Array(all.prefix(shownCount))
    }
    private var hiddenCount: Int { (listing?.entries ?? []).filter { $0.name.hasPrefix(".") }.count }

    var body: some View {
        NavigationStack {
            List {
                if let error {
                    Section {
                        Text(error).foregroundStyle(.red).font(.footnote)
                        HStack(spacing: 8) {
                            TextField("Folder path", text: $goTo)
                                .font(.body.monospaced()).textInputAutocapitalization(.never).autocorrectionDisabled()
                                .onSubmit { open(path: goTo) }
                            Button("Go") { open(path: goTo) }.disabled(goTo.trimmingCharacters(in: .whitespaces).isEmpty)
                        }
                    } footer: {
                        Text("The gateway could not list that folder. Open another one by path, or use Up and Home. A broken link inside the folder is the usual cause.")
                    }
                }
                if let l = listing {
                    Section {
                        Text(l.path).font(.caption.monospaced()).foregroundStyle(.secondary).textSelection(.enabled)
                    }
                    Section {
                        if let parent = l.parent { Button { path = parent } label: { Label("Up", systemImage: "arrow.up.doc") } }
                        ForEach(visibleEntries) { e in
                            if e.isDirectory {
                                Button { path = e.path } label: { Label(e.name, systemImage: "folder") }
                            } else {
                                Button { Task { await open(e) } } label: {
                                    HStack {
                                        Label(e.name, systemImage: icon(for: e))
                                        Spacer()
                                        if downloading == e.path { ProgressView().controlSize(.small) }
                                        else if let s = e.size { Text(ByteCountFormatter.string(fromByteCount: Int64(s), countStyle: .file)).font(.caption).foregroundStyle(.secondary) }
                                    }
                                }
                                .contextMenu {
                                    Button { Task { await open(e) } } label: { Label("Preview", systemImage: "eye") }
                                    ShareLink(item: e.path) { Label("Copy path", systemImage: "doc.on.doc") }
                                }
                            }
                        }
                        if allVisible.count > shownCount {
                            Button { shownCount += 500 } label: { Label("Show more (\(allVisible.count - shownCount) left)", systemImage: "ellipsis.circle") }
                        }
                    } footer: {
                        if !showHidden, hiddenCount > 0 {
                            Text("\(hiddenCount) hidden \(hiddenCount == 1 ? "item" : "items") not shown. The eye above shows them.")
                        }
                    }
                }
            }
            .overlay {
                if loading && (listing == nil || slow) {
                    VStack(spacing: 10) {
                        ProgressView()
                        if slow {
                            Text("Still listing. A big folder on a network mount can take a while, and the gateway answers nothing else meanwhile.")
                                .font(.footnote).foregroundStyle(.secondary).multilineTextAlignment(.center).padding(.horizontal, 32)
                            Button("Stop waiting") { loadTask?.cancel() }.buttonStyle(.bordered)
                        }
                    }
                    .padding(20)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                }
            }
            .navigationTitle("Files")
            .tabRoot(.files)
            .background(InteractivePopEnabler())
            .searchable(text: $searchText, placement: .navigationBarDrawer(displayMode: .automatic), prompt: "Search this folder")
            .toolbar {
                ToolbarItem(placement: .topBarLeading) { Button { path = nil } label: { Label("Home", systemImage: "house") } }
                ToolbarItem(placement: .primaryAction) {
                    Button { withAnimation { showHidden.toggle() } } label: { Label(showHidden ? "Hide hidden files" : "Show hidden files", systemImage: showHidden ? "eye" : "eye.slash") }
                        .accessibilityValue(showHidden ? "Hidden files shown" : "Hidden files not shown")
                }
                ToolbarItem(placement: .primaryAction) { Button { showImporter = true } label: { Label("Upload", systemImage: "square.and.arrow.up") } }
            }
            .reloadable { await load() }
            .task(id: path) { shownCount = 300; await load() }
            .task(id: model.runtime?.connection.id) { await load() }
            .quickLookPreview($previewURL)
            .fileImporter(isPresented: $showImporter, allowedContentTypes: [.item], allowsMultipleSelection: true) { r in
                if case .success(let urls) = r { Task { await upload(urls) } }
            }
        }
    }

    private func icon(for e: FileEntry) -> String {
        let t = UTType(filenameExtension: (e.name as NSString).pathExtension)
        if t?.conforms(to: .image) == true { return "photo" }
        if t?.conforms(to: .movie) == true { return "video" }
        if t?.conforms(to: .audio) == true { return "waveform" }
        if t?.conforms(to: .pdf) == true { return "doc.richtext" }
        if t?.conforms(to: .sourceCode) == true || t?.conforms(to: .plainText) == true { return "doc.text" }
        return "doc"
    }

    private func load() async {
        guard let rt = model.runtime else { return }
        loadTask?.cancel()
        loading = true; slow = false
        defer { loading = false; slow = false }
        let slowTimer = Task { try? await Task.sleep(for: .seconds(4)); if !Task.isCancelled { slow = true } }
        defer { slowTimer.cancel() }
        let requested = path
        let task = Task { () -> FilesListing? in
            var q: [URLQueryItem] = []
            if let requested { q.append(URLQueryItem(name: "path", value: requested)) }
            return try? await rt.api.get("/api/files", query: q)
        }
        loadTask = task
        do {
            guard let l = await task.value else {
                if task.isCancelled { self.error = "Stopped waiting for \(requested ?? "the home folder"). The gateway may still be listing it; try a smaller folder."; return }
                throw HermesAPIError.transport("Could not list \(requested ?? "the home folder")")
            }
            listing = l
            error = nil
        } catch {
            self.error = error.localizedDescription
            // The default root failed (the home folder, say): land in the profile's own
            // folder instead of a dead tab, once.
            if path == nil, !triedHomeFallback {
                var home = rt.profileHome
                if home == nil {
                    // The profile's folder is learned once the socket is up; give it a moment.
                    try? await Task.sleep(for: .seconds(2))
                    home = rt.profileHome
                }
                if let home {
                    triedHomeFallback = true
                    path = home
                }
            }
        }
    }

    private func open(path p: String) {
        let t = p.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return }
        path = t
    }

    private func open(_ e: FileEntry) async {
        guard let rt = model.runtime else { return }
        downloading = e.path; defer { downloading = nil }
        do { previewURL = try await rt.api.download("/api/files/download", query: [URLQueryItem(name: "path", value: e.path)]) }
        catch { self.error = error.localizedDescription }
    }

    private func upload(_ urls: [URL]) async {
        guard let rt = model.runtime, let dir = listing?.path else { return }
        for u in urls {
            let scoped = u.startAccessingSecurityScopedResource()
            defer { if scoped { u.stopAccessingSecurityScopedResource() } }
            guard let data = try? Data(contentsOf: u) else { continue }
            let mime = UTType(filenameExtension: u.pathExtension)?.preferredMIMEType ?? "application/octet-stream"
            do {
                let _: ManagedUploadResult = try await rt.api.sendMultipart("/api/files/upload-stream", fields: ["path": dir + "/" + u.lastPathComponent, "overwrite": "true"], fileField: "file", filename: u.lastPathComponent, fileData: data, mimeType: mime)
            } catch { self.error = error.localizedDescription }
        }
        await load()
    }
}
