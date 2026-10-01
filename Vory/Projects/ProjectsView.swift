import SwiftUI
import VoryCore

/// Settings › Projects, and Chats › Filters › Manage projects: the gateway's projects for the
/// selected bot. A project is a name over folders on the gateway; a chat is in a project when
/// it works inside one of those folders, so a new chat started in a project begins there.
struct ProjectsView: View {
    @Environment(AppModel.self) private var model
    @State private var showCreate = false
    @State private var renaming: Project?
    @State private var newName = ""
    @State private var pendingDelete: Project?
    @State private var error: String?

    @State private var searchText = ""

    var body: some View {
        SettingsList {
            SettingsHeaderSection(title: "Projects", symbol: "folder.fill", color: .indigo,
                                  description: "A project is a name over one or more folders on the gateway. Chats that work inside a project's folder belong to it, and a new chat started in a project begins in that folder.")
            if let rt = model.runtime {
                let store = rt.projects
                if store.available == false {
                    Section { Text("This gateway's Hermes has no projects yet. Update Hermes on the gateway to use them.").foregroundStyle(.secondary) }
                } else {
                    if let error { Section { Text(error).foregroundStyle(.red).font(.footnote) } }
                    Section {
                        if store.open.isEmpty {
                            Text(store.available == nil ? "Loading…" : "No projects yet. \(DeviceWords.Tap) + to make one.").foregroundStyle(.secondary)
                        }
                        ForEach(store.open.filter { searchText.isEmpty || $0.name.localizedCaseInsensitiveContains(searchText) }) { p in row(p, store: store) }
                    } header: { Text("Projects") } footer: {
                        if !store.open.isEmpty { Text(DeviceWords.isMac ? "Right-click a project to archive it, edit it or more." : "Swipe a project to archive it. Press and hold for more.") }
                    }
                    let archived = store.projects.filter { $0.isArchived && (searchText.isEmpty || $0.name.localizedCaseInsensitiveContains(searchText)) }
                    if !archived.isEmpty {
                        Section("Archived") { ForEach(archived) { p in row(p, store: store) } }
                    }
                }
            } else {
                Section { Text("Connect a gateway first.").foregroundStyle(.secondary) }
            }
        }
        .navigationTitle("").navigationBarTitleDisplayMode(.inline)
        .searchable(text: $searchText, placement: .navigationBarDrawer(displayMode: .automatic), prompt: "Search projects")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button { showCreate = true } label: { Label("New project", systemImage: "plus") }
                    .disabled(model.runtime?.projects.available != true)
            }
        }
        .sheet(isPresented: $showCreate) { if let rt = model.runtime { NewProjectSheet(runtime: rt).sheetFrame() } }
        .alert("Rename project", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
            TextField("Name", text: $newName)
            Button("Rename") {
                if let p = renaming, let store = model.runtime?.projects { run { try await store.rename(p, to: newName) } }
                renaming = nil
            }
            Button("Cancel", role: .cancel) { renaming = nil }
        }
        .alert("Delete project?", isPresented: Binding(get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } })) {
            Button("Delete", role: .destructive) {
                if let p = pendingDelete, let store = model.runtime?.projects { run { try await store.delete(p) } }
                pendingDelete = nil
            }
            Button("Cancel", role: .cancel) { pendingDelete = nil }
        } message: { Text("The folders and the chats stay on the gateway. Only the grouping goes.") }
        .task { await model.runtime?.projects.refresh() }
        .reloadable { await model.runtime?.projects.refresh() }
    }

    private func row(_ p: Project, store: ProjectsStore) -> some View {
        let count = store.membership.values.filter { $0 == p.id }.count
        return HStack(spacing: 12) {
            ProjectIcon(project: p)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(p.name)
                    if store.activeID == p.id {
                        Text("Active").font(.caption2.weight(.semibold)).padding(.horizontal, 6).padding(.vertical, 2)
                            .background(.tint.opacity(0.15), in: Capsule())
                    }
                }
                Text(p.startPath ?? "").font(.caption.monospaced()).foregroundStyle(.secondary).lineLimit(1).truncationMode(.head)
            }
            Spacer()
            if count > 0 { Text("\(count) \(count == 1 ? "chat" : "chats")").font(.caption).foregroundStyle(.secondary) }
        }
        .contentShape(Rectangle())
        .contextMenu {
            Button { renaming = p; newName = p.name } label: { Label("Rename", systemImage: "pencil") }
            if store.activeID == p.id {
                Button { run { try await store.setActive(nil) } } label: { Label("Clear active", systemImage: "star.slash") }
            } else if !p.isArchived {
                Button { run { try await store.setActive(p) } } label: { Label("Make active", systemImage: "star") }
            }
            if p.isArchived {
                Button { run { try await store.archive(p, restore: true) } } label: { Label("Restore", systemImage: "arrow.uturn.backward") }
            } else {
                Button { run { try await store.archive(p) } } label: { Label("Archive", systemImage: "archivebox") }
            }
            Button(role: .destructive) { pendingDelete = p } label: { Label("Delete", systemImage: "trash") }
        }
        .swipeActions(edge: .trailing) {
            Button(role: .destructive) { pendingDelete = p } label: { Label("Delete", systemImage: "trash") }
            if p.isArchived {
                Button { run { try await store.archive(p, restore: true) } } label: { Label("Restore", systemImage: "arrow.uturn.backward") }.tint(.blue)
            } else {
                Button { run { try await store.archive(p) } } label: { Label("Archive", systemImage: "archivebox") }.tint(.orange)
            }
        }
    }

    private func run(_ op: @escaping @MainActor () async throws -> Void) {
        Task { @MainActor in
            do { try await op(); error = nil } catch { self.error = error.localizedDescription }
        }
    }
}

/// The name + folder form. The folder must exist on the gateway machine; a path under the
/// gateway's home is offered as a start.
struct NewProjectSheet: View {
    let runtime: GatewayRuntime
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var folder = ""
    @State private var makeActive = false
    @State private var busy = false
    @State private var error: String?

    private var ready: Bool { !busy && !name.trimmingCharacters(in: .whitespaces).isEmpty && !folder.trimmingCharacters(in: .whitespaces).isEmpty }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Name", text: $name).textInputAutocapitalization(.words)
                    TextField("Folder on the gateway", text: $folder).font(.body.monospaced()).textInputAutocapitalization(.never).autocorrectionDisabled()
                } footer: {
                    Text("The folder must already exist on the gateway machine. Chats started in this project work inside it, and the gateway reads the AGENTS.md and project skills it finds there.")
                }
                Section { Toggle("Make it the active project", isOn: $makeActive) } footer: { Text("The active project is where the gateway's own terminal starts.") }
                if let error { Section { Text(error).foregroundStyle(.red).font(.footnote) } }
            }
            .navigationTitle("New Project").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) { Button(busy ? "Creating…" : "Create") { Task { await create() } }.disabled(!ready) }
            }
            .onAppear { if folder.isEmpty, let home = runtime.profileHome { folder = (home as NSString).deletingLastPathComponent + "/" } }
        }
    }

    private func create() async {
        busy = true; defer { busy = false }
        do {
            try await runtime.projects.create(name: name.trimmingCharacters(in: .whitespaces), folder: folder.trimmingCharacters(in: .whitespaces), makeActive: makeActive)
            dismiss()
        } catch { self.error = error.localizedDescription }
    }
}

/// The painted folder on project rows: the project's own hue when the gateway set one.
struct ProjectIcon: View {
    let project: Project
    var size: CGFloat = 28
    var body: some View {
        Image(systemName: "folder.fill")
            .font(.system(size: size * 0.5, weight: .semibold))
            .foregroundStyle(.white)
            .frame(width: size, height: size)
            .background(ProjectChip.color(for: project), in: RoundedRectangle(cornerRadius: size * 0.28, style: .continuous))
    }
}

/// On a chat row: which project the chat is in.
struct ProjectChip: View {
    let project: Project
    static func color(for p: Project) -> Color { p.hue.map { Color(hue: $0, saturation: 0.55, brightness: 0.78) } ?? .indigo }
    var body: some View {
        let c = Self.color(for: project)
        HStack(spacing: 3) {
            Image(systemName: "folder.fill").font(.system(size: 8))
            Text(project.name).lineLimit(1)
        }
        .font(.caption2.weight(.medium))
        .foregroundStyle(c)
        .padding(.horizontal, 6).padding(.vertical, 2)
        .background(c.opacity(0.14), in: Capsule())
    }
}
