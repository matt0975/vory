import SwiftUI
import VoryCore

/// The Board: the gateway's kanban, one column at a time. Each card shows its facts (bot,
/// priority, age, comments, children done, warnings, a worker on it), and the actions the
/// dashboard has live on the card's menu and swipes: move (done asks for a summary, blocked for
/// a reason, archive for a yes), reassign, priority, comment, stop the worker, delete. The
/// detail sheet has the body, the comments, the runs and the worker's log.
struct KanbanView: View {
    /// Pushed from Settings rather than living on a tab: it is on screen when it appears.
    var embedded = false

    @Environment(AppModel.self) private var model
    @AppStorage("kanban.column") private var columnRaw = KanbanStatus.ready.rawValue
    @State private var showNew = false
    @State private var detailTask: KanbanTask?
    @State private var ask: KanbanAsk?
    @State private var answer = ""
    @State private var notice: String?
    @State private var appeared = false

    private var store: KanbanStore? { model.runtime?.kanban }
    private var column: KanbanStatus { KanbanStatus(rawValue: columnRaw) ?? .ready }
    private var active: Bool { embedded ? appeared : model.selectedTab == .kanban }

    var body: some View {
        Group {
            if let store { content(store) } else {
                ContentUnavailableView("No gateway", systemImage: "antenna.radiowaves.left.and.right.slash", description: Text("Connect a gateway in Settings to see its board."))
            }
        }
        .navigationTitle(store?.selectedBoardMeta?.displayName ?? "Board")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .toolbar { toolbar }
        .onAppear { appeared = true }
        .onDisappear { appeared = false }
        .task(id: active) { await follow() }
        .reloadable { await store?.refresh() }
        .sheet(item: $detailTask) { t in
            KanbanTaskSheet(taskID: t.id, onOpenChat: { sid, profile in detailTask = nil; openChat(sid, profile: profile) }).sheetFrame(.wide)
        }
        .sheet(isPresented: $showNew) { KanbanNewTaskSheet { warning in if let warning { notice = warning } }.sheetFrame() }
        .alert(ask?.title ?? "", isPresented: Binding(get: { ask?.asksForText == true }, set: { if !$0 { ask = nil } }), presenting: ask) { a in
            TextField(a.placeholder, text: $answer)
            Button(a.verb) { Task { await answerAsk(a) } }
            Button("Cancel", role: .cancel) { ask = nil }
        } message: { a in Text(a.message) }
        .confirmationDialog(ask?.title ?? "", isPresented: Binding(get: { ask?.asksForText == false }, set: { if !$0 { ask = nil } }), titleVisibility: .visible, presenting: ask) { a in
            Button(a.verb, role: a.destructive ? .destructive : nil) { Task { await answerAsk(a) } }
            Button("Cancel", role: .cancel) { ask = nil }
        } message: { a in Text(a.message) }
        .alert("Board", isPresented: Binding(get: { notice != nil }, set: { if !$0 { notice = nil } })) {
            Button("OK") { notice = nil }
        } message: { Text(notice ?? "") }
    }

    // MARK: Pages

    @ViewBuilder private func content(_ store: KanbanStore) -> some View {
        if store.effective == .absent {
            ContentUnavailableView("Kanban is off on this gateway", systemImage: "rectangle.split.3x1",
                                   description: Text("Turn on the kanban plugin on the gateway (its dashboard, under Plugins) and the Board appears here."))
        } else if let board = store.board {
            list(store, board)
        } else if let e = store.lastError, !store.loading {
            ContentUnavailableView("Could not read the board", systemImage: "exclamationmark.triangle", description: Text(e))
        } else {
            ProgressView("Reading the board…")
        }
    }

    private func list(_ store: KanbanStore, _ board: KanbanBoard) -> some View {
        let tasks = board.tasks(in: column)
        return List {
            if let e = store.lastError {
                Section { Label(e, systemImage: "exclamationmark.triangle").font(.footnote).foregroundStyle(.orange) }
            }
            if tasks.isEmpty {
                ContentUnavailableView("Nothing in \(column.title)", systemImage: column.symbol, description: Text(emptyWords))
                    .listRowBackground(Color.clear)
            }
            ForEach(tasks) { task in
                Button { detailTask = task } label: {
                    KanbanCardRow(task: task, worker: store.worker(for: task))
                }
                .tint(.primary)
                .contextMenu { menu(for: task, store: store) }
                .swipeActions(edge: .leading, allowsFullSwipe: false) {
                    if task.column != .done, task.column != .archived {
                        Button { ask = .done(task) } label: { Label("Done", systemImage: "checkmark") }.tint(.green)
                    }
                    if task.column == .blocked {
                        Button { Task { await move(task, to: .ready, store: store) } } label: { Label("Unblock", systemImage: "play") }.tint(.blue)
                    }
                }
                .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                    Button(role: .destructive) { ask = .delete(task) } label: { Label("Delete", systemImage: "trash") }
                    if task.isWorking {
                        Button { ask = .stop(task) } label: { Label("Stop", systemImage: "stop.fill") }.tint(.orange)
                    } else if task.column != .blocked, task.column != .done, task.column != .archived {
                        Button { ask = .block(task) } label: { Label("Block", systemImage: "hand.raised") }.tint(.orange)
                    }
                }
            }
        }
        .safeAreaInset(edge: .top, spacing: 0) { columns(board) }
        .overlay(alignment: .bottomTrailing) {
            if store.liveConnected {
                Label("Live", systemImage: "dot.radiowaves.left.and.right").font(.caption2).foregroundStyle(.secondary)
                    .padding(.horizontal, 8).padding(.vertical, 4).background(.thinMaterial, in: .capsule).padding(12)
                    .accessibilityLabel("Live updates on")
            }
        }
    }

    private var emptyWords: String {
        switch column {
        case .ready: return "Cards here are picked up by the dispatcher and handed to their bot."
        case .running: return "A card moves here when a worker claims it."
        case .blocked: return "A worker that cannot go on parks its card here with a reason."
        case .review: return "A worker that wants a look before done asks for review."
        case .done: return "Finished work lands here; archive it to clear the board."
        default: return "Make a task with the plus, or move one here."
        }
    }

    /// The columns as chips with their counts; one is open at a time.
    private func columns(_ board: KanbanBoard) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(KanbanStatus.columns, id: \.self) { s in
                    let n = board.count(s)
                    Button { withAnimation(.snappy) { columnRaw = s.rawValue } } label: {
                        HStack(spacing: 5) {
                            Image(systemName: s.symbol).font(.caption)
                            Text(s.title).font(.subheadline.weight(.medium))
                            if n > 0 { Text("\(n)").font(.caption2.monospacedDigit()).padding(.horizontal, 5).padding(.vertical, 1).background(.quaternary, in: .capsule) }
                        }
                        .padding(.horizontal, 12).padding(.vertical, 7)
                    }
                    .buttonStyle(.plain)
                    .background(column == s ? Color.accentColor.opacity(0.18) : Color(.secondarySystemBackground), in: .capsule)
                    .foregroundStyle(column == s ? Color.accentColor : .primary)
                    .accessibilityLabel("\(s.title), \(n)")
                    .accessibilityAddTraits(column == s ? .isSelected : [])
                }
            }
            .padding(.horizontal, 16).padding(.vertical, 8)
        }
        .background(.bar)
    }

    @ToolbarContentBuilder private var toolbar: some ToolbarContent {
        if let store, store.boards.count > 1 {
            ToolbarItem(placement: .cancellationAction) {
                Menu {
                    ForEach(store.boards) { b in
                        Button { store.select(board: b.slug) } label: {
                            if b.slug == store.selectedBoard { Label(b.displayName, systemImage: "checkmark") } else { Text(b.displayName) }
                        }
                    }
                } label: { Label("Board", systemImage: "square.stack") }
                .accessibilityLabel("Choose a board")
            }
        }
        ToolbarItemGroup(placement: .primaryAction) {
            Menu {
                Button { Task { await store?.nudge() } } label: { Label("Nudge Dispatcher", systemImage: "hare") }
                Button { Task { await store?.refresh() } } label: { Label("Refresh", systemImage: "arrow.clockwise") }
            } label: { Label("Board options", systemImage: "ellipsis.circle") }
            Button { showNew = true } label: { Label("New Task", systemImage: "plus") }
                .disabled(store?.isPresent != true)
        }
    }

    // MARK: Menu and actions

    @ViewBuilder private func menu(for task: KanbanTask, store: KanbanStore) -> some View {
        Menu {
            ForEach(KanbanStatus.allCases.filter { $0 != task.column }, id: \.self) { s in
                if s.isMoveTarget {
                    Button { Task { await move(task, to: s, store: store) } } label: { Label(s.title, systemImage: s.symbol) }
                } else {
                    // Not a place a hand can put a card: the tap says why, in the server's terms.
                    Button { notice = s.notMovableReason } label: { Label("\(s.title) (gateway only)", systemImage: s.symbol) }
                }
            }
        } label: { Label("Move to", systemImage: "arrow.right.square") }
        Menu {
            Button { Task { await reassign(task, to: nil, store: store) } } label: {
                if task.assignee == nil { Label("Unassigned", systemImage: "checkmark") } else { Text("Unassigned") }
            }
            ForEach(store.assignees) { a in
                Button { Task { await reassign(task, to: a.name, store: store) } } label: {
                    if task.assignee == a.name { Label(a.name, systemImage: "checkmark") } else { Text(a.name) }
                }
            }
        } label: { Label("Reassign", systemImage: "person.crop.circle.badge.checkmark") }
        Menu {
            ForEach(0..<4, id: \.self) { p in
                Button { Task { await changed(store.setPriority(task, p), store) } } label: {
                    if (task.priority ?? 0) == p { Label(Self.priorityName(p), systemImage: "checkmark") } else { Text(Self.priorityName(p)) }
                }
            }
        } label: { Label("Priority", systemImage: "flag") }
        Button { ask = .comment(task) } label: { Label("Comment", systemImage: "bubble.left") }
        if task.isWorking { Button { ask = .stop(task) } label: { Label("Stop the Worker", systemImage: "stop.circle") } }
        if let sid = task.sessionId, !sid.isEmpty { Button { openChat(sid, profile: task.assignee) } label: { Label("Open Chat", systemImage: "bubble.left.and.bubble.right") } }
        Divider()
        if task.column != .archived { Button { ask = .archive(task) } label: { Label("Archive", systemImage: "archivebox") } }
        Button(role: .destructive) { ask = .delete(task) } label: { Label("Delete", systemImage: "trash") }
    }

    static func priorityName(_ p: Int) -> String {
        switch p {
        case 0: return "Normal"
        case 1: return "High"
        case 2: return "Urgent"
        default: return "Critical"
        }
    }

    private func move(_ task: KanbanTask, to status: KanbanStatus, store: KanbanStore) async {
        switch status {
        case .done: ask = .done(task)
        case .blocked: ask = .block(task)
        case .archived: ask = .archive(task)
        default: await changed(store.move(task, to: status), store)
        }
    }

    private func reassign(_ task: KanbanTask, to profile: String?, store: KanbanStore) async {
        await changed(store.reassign(task, to: profile), store)
    }

    /// After a write: the server's words when it refused, nothing when it took it.
    private func changed(_ ok: Bool, _ store: KanbanStore) async {
        if !ok, let e = store.lastError { notice = e }
    }

    private func answerAsk(_ a: KanbanAsk) async {
        guard let store else { return }
        let text = answer.trimmingCharacters(in: .whitespacesAndNewlines)
        answer = ""; ask = nil
        switch a {
        case .done(let t): await changed(store.move(t, to: .done, summary: text), store)
        case .block(let t): await changed(store.move(t, to: .blocked, blockReason: text), store)
        case .comment(let t): if !text.isEmpty { await changed(store.comment(t, text), store) }
        case .archive(let t): await changed(store.move(t, to: .archived), store)
        case .delete(let t): await changed(store.delete(t), store)
        case .stop(let t): await changed(store.stop(t, reason: "stopped from Vory"), store)
        }
    }

    private func openChat(_ storedID: String, profile: String?) {
        model.pendingRoute = PendingRoute(connectionID: model.runtime?.connection.id, storedSessionID: storedID, profile: profile?.isEmpty == false ? profile : nil)
        model.selectedTab = .chats
    }

    /// While the page is in front: a read now, the live socket, and a read every minute as the
    /// desktop client does. Off screen the socket is closed.
    private func follow() async {
        guard let store else { return }
        guard active else { store.stopEvents(); return }
        await store.refresh()
        store.startEvents()
        await store.loadAssignees()
        while !Task.isCancelled {
            try? await Task.sleep(for: .seconds(60))
            guard !Task.isCancelled else { break }
            await store.refresh()
        }
    }
}

/// A question before a change: done asks for a summary, blocked for a reason, a comment for its
/// words; archive, delete and stop ask for a yes.
enum KanbanAsk: Identifiable {
    case done(KanbanTask), block(KanbanTask), comment(KanbanTask), archive(KanbanTask), delete(KanbanTask), stop(KanbanTask)

    var task: KanbanTask {
        switch self { case .done(let t), .block(let t), .comment(let t), .archive(let t), .delete(let t), .stop(let t): return t }
    }
    var id: String { "\(verb)-\(task.id)" }
    var asksForText: Bool { switch self { case .done, .block, .comment: return true; default: return false } }
    var destructive: Bool { switch self { case .delete, .stop: return true; default: return false } }
    var title: String {
        switch self {
        case .done: return "Mark as done"
        case .block: return "Block this task"
        case .comment: return "Comment"
        case .archive: return "Archive this task?"
        case .delete: return "Delete this task?"
        case .stop: return "Stop the worker?"
        }
    }
    var verb: String {
        switch self {
        case .done: return "Done"
        case .block: return "Block"
        case .comment: return "Send"
        case .archive: return "Archive"
        case .delete: return "Delete"
        case .stop: return "Stop"
        }
    }
    var placeholder: String {
        switch self {
        case .done: return "What was done"
        case .block: return "Why it is blocked (optional)"
        case .comment: return "Your comment"
        default: return ""
        }
    }
    var message: String {
        switch self {
        case .done: return "A short summary of the result. The gateway asks for one unless the task comes from review."
        case .block: return "The reason is kept on the card for whoever picks it up."
        case .comment: return task.title
        case .archive: return "It leaves the board; the gateway keeps it."
        case .delete: return "This removes \"\(task.title)\" from the gateway, with its comments and runs."
        case .stop: return "The worker on \"\(task.title)\" is terminated and the card goes back to ready."
        }
    }
}

/// One card in a column.
struct KanbanCardRow: View {
    var task: KanbanTask
    var worker: KanbanWorker?

    private var workingFor: String? {
        guard task.isWorking, let s = task.currentRunStartedAt ?? worker?.startedAt else { return task.isWorking ? "working" : nil }
        let m = max(0, (Int(Date().timeIntervalSince1970) - s) / 60)
        return m < 1 ? "just started" : m < 60 ? "\(m) min" : "\(m / 60) h \(m % 60) min"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(alignment: .top, spacing: 8) {
                Text(task.title).font(.body.weight(.medium)).lineLimit(2).multilineTextAlignment(.leading)
                Spacer(minLength: 0)
                if let p = task.priority, p > 0 {
                    Text(KanbanView.priorityName(p)).font(.caption2.weight(.semibold))
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(p >= 2 ? Color.red.opacity(0.18) : Color.orange.opacity(0.18), in: .capsule)
                        .foregroundStyle(p >= 2 ? .red : .orange)
                }
            }
            if let preview = task.preview {
                Text(preview).font(.caption).foregroundStyle(.secondary).lineLimit(2).multilineTextAlignment(.leading)
            }
            HStack(spacing: 10) {
                if let a = task.assignee, !a.isEmpty {
                    HStack(spacing: 4) { BotAvatar(profile: a, size: 16); Text(a).font(.caption) }
                } else {
                    Label("Unassigned", systemImage: "person.slash").font(.caption).foregroundStyle(.tertiary)
                }
                if let w = workingFor {
                    HStack(spacing: 4) { ProgressView().controlSize(.mini); Text(w).font(.caption).foregroundStyle(.secondary) }
                        .accessibilityLabel("A worker is on it, \(w)")
                }
                if let c = task.commentCount, c > 0 { Label("\(c)", systemImage: "bubble.left").font(.caption).foregroundStyle(.secondary) }
                if let p = task.progress, p.total > 0 { Label("\(p.done)/\(p.total)", systemImage: "checklist").font(.caption).foregroundStyle(.secondary) }
                if !task.warnings.isEmpty {
                    Label("\(task.warnings.count)", systemImage: "exclamationmark.triangle.fill").font(.caption).foregroundStyle(.orange)
                        .accessibilityLabel(task.warnings.map(\.text).joined(separator: ". "))
                }
                Spacer(minLength: 0)
                if let s = task.age?.createdAgeSeconds {
                    Text(Date(timeIntervalSinceNow: -Double(s)), format: .relative(presentation: .named)).font(.caption2).foregroundStyle(.tertiary)
                }
            }
            .labelStyle(.titleAndIcon)
        }
        .padding(.vertical, 2)
        .contentShape(.rect)
    }
}

/// A task on its own: facts, body, result, comments with a composer, runs with their log, history.
struct KanbanTaskSheet: View {
    var taskID: String
    var onOpenChat: (String, String?) -> Void

    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var detail: KanbanTaskDetail?
    @State private var error: String?
    @State private var comment = ""
    @State private var sending = false
    @State private var confirmStop = false

    private var store: KanbanStore? { model.runtime?.kanban }

    var body: some View {
        NavigationStack {
            Group {
                if let d = detail { form(d) }
                else if let error { ContentUnavailableView("Could not read the task", systemImage: "exclamationmark.triangle", description: Text(error)) }
                else { ProgressView() }
            }
            .navigationTitle(detail?.task.title ?? "Task")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Done") { dismiss() } }
                if let d = detail, d.task.isWorking {
                    ToolbarItem(placement: .primaryAction) {
                        Button { confirmStop = true } label: { Label("Stop the Worker", systemImage: "stop.circle") }
                    }
                }
            }
            .confirmationDialog("Stop the worker?", isPresented: $confirmStop, titleVisibility: .visible) {
                Button("Stop", role: .destructive) { Task { if let d = detail, let store { _ = await store.stop(d.task, reason: "stopped from Vory"); await load() } } }
                Button("Cancel", role: .cancel) {}
            } message: { Text("The worker is terminated and the card goes back to ready.") }
            .task { await load() }
            // A worker on it: its runs and heartbeat move, so the sheet reads again now and then.
            .task(id: detail?.task.isWorking) {
                guard detail?.task.isWorking == true else { return }
                while !Task.isCancelled { try? await Task.sleep(for: .seconds(6)); guard !Task.isCancelled else { break }; await load() }
            }
        }
    }

    private func load() async {
        guard let store else { return }
        do { detail = try await store.detail(taskID); error = nil } catch { self.error = KanbanStore.message(error) }
    }

    @ViewBuilder private func form(_ d: KanbanTaskDetail) -> some View {
        let t = d.task
        List {
            Section {
                LabeledContent("Status") { Label(t.column?.title ?? t.status, systemImage: t.column?.symbol ?? "circle") }
                LabeledContent("Bot") {
                    if let a = t.assignee, !a.isEmpty { HStack(spacing: 6) { BotAvatar(profile: a, size: 18); Text(a) } } else { Text("Unassigned").foregroundStyle(.secondary) }
                }
                LabeledContent("Priority", value: KanbanView.priorityName(t.priority ?? 0))
                if let c = t.created { LabeledContent("Made") { Text(c, format: .relative(presentation: .named)) } }
                if let tenant = t.tenant, !tenant.isEmpty { LabeledContent("Tenant", value: tenant) }
                if let sid = t.sessionId, !sid.isEmpty {
                    Button { onOpenChat(sid, t.assignee) } label: { Label("Open Chat", systemImage: "bubble.left.and.bubble.right") }
                }
            }
            if !t.warnings.isEmpty {
                Section("Needs a look") {
                    ForEach(Array(t.warnings.enumerated()), id: \.offset) { _, w in Label(w.text, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange) }
                }
            }
            if let b = t.body, !b.isEmpty {
                Section("Task") { MarkdownView(text: b) }
            }
            if let r = t.result ?? t.latestSummary, !r.isEmpty {
                Section(t.result != nil ? "Result" : "Latest summary") { Text(r).textSelection(.enabled) }
            }
            if let cr = d.childResults, !cr.isEmpty {
                Section("Children") {
                    ForEach(cr) { c in
                        VStack(alignment: .leading, spacing: 2) {
                            Label(c.title, systemImage: KanbanStatus(rawValue: c.status)?.symbol ?? "circle")
                            if let r = c.result ?? c.latestSummary { Text(r).font(.caption).foregroundStyle(.secondary).lineLimit(2) }
                        }
                    }
                }
            }
            Section("Runs") {
                if d.runs.isEmpty { Text("No worker has taken it yet.").foregroundStyle(.secondary) }
                ForEach(d.runs.reversed()) { run in
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            HStack(spacing: 6) {
                                if let p = run.profile { BotAvatar(profile: p, size: 16); Text(p).font(.subheadline) }
                                Text(run.stateText).font(.caption).foregroundStyle(run.isOpen ? Color.accentColor : .secondary)
                            }
                            Text("\(run.started, format: .relative(presentation: .named)) · \(KanbanTaskSheet.duration(run.durationSeconds))").font(.caption2).foregroundStyle(.tertiary)
                            if let e = run.error, !e.isEmpty { Text(e).font(.caption).foregroundStyle(.red).lineLimit(2) }
                            if let s = run.summary, !s.isEmpty { Text(s).font(.caption).foregroundStyle(.secondary).lineLimit(3) }
                        }
                        Spacer()
                        if run.isOpen { ProgressView().controlSize(.small) }
                    }
                }
                NavigationLink { KanbanLogView(taskID: t.id, live: t.isWorking) } label: { Label("Worker log", systemImage: "doc.plaintext") }
            }
            Section("Comments") {
                ForEach(d.comments) { c in
                    VStack(alignment: .leading, spacing: 2) {
                        HStack { Text(c.author).font(.caption.weight(.semibold)); Spacer(); Text(c.created, format: .relative(presentation: .named)).font(.caption2).foregroundStyle(.tertiary) }
                        Text(c.body).font(.subheadline)
                    }
                }
                HStack {
                    TextField("Add a comment", text: $comment, axis: .vertical).lineLimit(1...4)
                    Button { Task { await send() } } label: { Image(systemName: "arrow.up.circle.fill").font(.title2) }
                        .disabled(comment.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || sending)
                        .accessibilityLabel("Send the comment")
                }
            }
            if !d.events.isEmpty {
                Section("History") {
                    ForEach(d.events.suffix(12).reversed()) { e in
                        HStack { Text(e.line).font(.caption); Spacer(); Text(e.created, format: .relative(presentation: .named)).font(.caption2).foregroundStyle(.tertiary) }
                    }
                }
            }
        }
    }

    private func send() async {
        guard let store, let d = detail else { return }
        let text = comment.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        sending = true; defer { sending = false }
        if await store.comment(d.task, text) { comment = ""; await load() } else { error = store.lastError }
    }

    static func duration(_ s: Int) -> String {
        s < 60 ? "\(s)s" : s < 3600 ? "\(s / 60) min" : "\(s / 3600) h \((s % 3600) / 60) min"
    }
}

/// The worker's stdout and stderr, re-read every few seconds while the task runs.
struct KanbanLogView: View {
    var taskID: String
    var live: Bool
    @Environment(AppModel.self) private var model
    @State private var log: KanbanLog?
    @State private var error: String?

    var body: some View {
        ScrollView {
            if let log {
                if log.exists {
                    Text(log.content).font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading).padding()
                    if log.truncated == true { Text("The start of the log is not shown.").font(.caption2).foregroundStyle(.tertiary).padding(.horizontal) }
                } else {
                    ContentUnavailableView("No log yet", systemImage: "doc.plaintext", description: Text("A worker writes one once it starts."))
                }
            } else if let error {
                ContentUnavailableView("Could not read the log", systemImage: "exclamationmark.triangle", description: Text(error))
            } else { ProgressView().padding() }
        }
        .navigationTitle("Worker log")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .task {
            await read()
            guard live else { return }
            while !Task.isCancelled { try? await Task.sleep(for: .seconds(4)); guard !Task.isCancelled else { break }; await read() }
        }
    }

    private func read() async {
        guard let store = model.runtime?.kanban else { return }
        do { log = try await store.log(taskID); error = nil } catch { self.error = KanbanStore.message(error) }
    }
}

/// A new task: title, body, the bot, priority, and whether it starts in triage.
struct KanbanNewTaskSheet: View {
    /// Called once made, with the dispatcher's warning when nothing would pick the task up.
    var onMade: (String?) -> Void

    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var title = ""
    @State private var body_ = ""
    @State private var assignee = ""
    @State private var priority = 0
    @State private var triage = false
    @State private var busy = false
    @State private var error: String?

    private var store: KanbanStore? { model.runtime?.kanban }
    private var bots: [String] {
        var names = store?.assignees.map(\.name) ?? []
        for p in model.runtime?.profiles ?? [] where !names.contains(p.name) { names.append(p.name) }
        return names
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Title", text: $title)
                    TextField("What to do", text: $body_, axis: .vertical).lineLimit(3...8)
                }
                Section {
                    Picker("Bot", selection: $assignee) {
                        Text("Unassigned").tag("")
                        ForEach(bots, id: \.self) { b in Text(b).tag(b) }
                    }
                    Picker("Priority", selection: $priority) {
                        ForEach(0..<4, id: \.self) { p in Text(KanbanView.priorityName(p)).tag(p) }
                    }
                    Toggle("Start in triage", isOn: $triage)
                } footer: {
                    Text(triage ? "It waits in Triage until someone moves it on." : "A task with a bot starts in Ready, and the dispatcher hands it to that bot.")
                }
                if let error { Section { Text(error).foregroundStyle(.red).font(.footnote) } }
            }
            .navigationTitle("New Task")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Create") { Task { await create() } }
                        .disabled(title.trimmingCharacters(in: .whitespaces).isEmpty || busy)
                }
            }
            .task { await store?.loadAssignees(); if assignee.isEmpty, let p = model.runtime?.selectedProfile, bots.contains(p) { assignee = p } }
        }
    }

    private func create() async {
        guard let store else { return }
        busy = true; defer { busy = false }
        let new = KanbanNewTask(title: title.trimmingCharacters(in: .whitespaces), body: body_.isEmpty ? nil : body_, assignee: assignee.isEmpty ? nil : assignee, priority: priority, triage: triage)
        if let made = await store.create(new) {
            dismiss()
            onMade(made.warning)
        } else {
            error = store.lastError ?? "The gateway did not take the task."
        }
    }
}
