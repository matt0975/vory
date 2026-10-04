import AppKit
import SwiftUI
import VoryCore

/// The Board on the Mac: the gateway's kanban as columns side by side, a card dragged from one
/// to another to move it (done asks for a summary, blocked for a reason, archive for a yes;
/// the gateway's own columns refuse a drop and say why), the chosen card's inspector beside the
/// board, and the keyboard: arrows move the choice, ⌘[ and ⌘] move the card, Return opens it.
/// The rules, the reads and the writes are the shared store's; this file is the window.
struct MacBoardView: View {
    @Environment(AppModel.self) private var model
    @State private var commands = BoardCommands.shared
    @State private var selectedID: String?
    @State private var showNew = false
    @State private var openTaskID: String?
    @State private var ask: KanbanAsk?
    @State private var answer = ""
    @State private var notice: String?
    @State private var targeted: KanbanStatus?

    /// The gateway's board, else one handed in (previews and tests draw a board without a gateway).
    private let ownStore: KanbanStore?
    private var store: KanbanStore? { ownStore ?? model.runtime?.kanban }
    private var active: Bool { ownStore != nil || model.selectedTab == .kanban }
    private var selectedTask: KanbanTask? { selectedID.flatMap { store?.board?.task(id: $0) } }

    /// `initialSelection`: a card whose inspector is open from the start (previews and tests).
    init(store: KanbanStore? = nil, initialSelection: String? = nil) {
        ownStore = store
        _selectedID = State(initialValue: initialSelection)
    }

    /// Wide enough for a working card's footer (bot, time on it, comments, children, age) on one line.
    static let columnWidth: CGFloat = 292
    static let inspectorWidth: CGFloat = 360

    var body: some View {
        Group {
            if let store { content(store) } else {
                ContentUnavailableView("No gateway", systemImage: "antenna.radiowaves.left.and.right.slash", description: Text("Connect a gateway in Settings to see its board."))
            }
        }
        .navigationTitle(store?.selectedBoardMeta?.displayName ?? "Board")
        .toolbar { toolbar }
        .task(id: active) { await follow() }
        .onChange(of: selectedID) { _, id in commands.selectedID = id }
        .onChange(of: commands.newTaskRequest) { _, _ in if active, store?.isPresent == true { showNew = true } }
        .onChange(of: commands.moveRequest) { _, r in if let r, active { Task { await moveSelected(by: r.direction) } } }
        .onChange(of: commands.openRequest) { _, _ in if active, let id = selectedID { openTaskID = id } }
        .sheet(isPresented: $showNew) { KanbanNewTaskSheet { warning in if let warning { notice = warning } }.sheetFrame() }
        .sheet(item: Binding(get: { openTaskID.map { OpenTask(id: $0) } }, set: { openTaskID = $0?.id })) { t in
            KanbanTaskSheet(taskID: t.id, onOpenChat: { sid, profile in openTaskID = nil; openChat(sid, profile: profile) }).sheetFrame(.wide)
        }
        .kanbanAsks(ask: $ask, answer: $answer, notice: $notice) { a in await answerAsk(a) }
    }

    private struct OpenTask: Identifiable { var id: String }

    // MARK: Pages

    @ViewBuilder private func content(_ store: KanbanStore) -> some View {
        if store.effective == .absent {
            ContentUnavailableView("Kanban is off on this gateway", systemImage: "rectangle.split.3x1",
                                   description: Text("Turn on the kanban plugin on the gateway (its dashboard, under Plugins) and the Board appears here."))
        } else if let board = store.board {
            HStack(spacing: 0) {
                columns(store, board)
                if let id = selectedID, board.task(id: id) != nil {
                    Divider()
                    MacTaskInspector(taskID: id, store: store, onClose: { selectedID = nil }, onOpenChat: { sid, profile in openChat(sid, profile: profile) })
                        .frame(width: Self.inspectorWidth)
                }
            }
            .safeAreaInset(edge: .bottom, spacing: 0) { footer(store, board) }
        } else if let e = store.lastError, !store.loading {
            ContentUnavailableView("Could not read the board", systemImage: "exclamationmark.triangle", description: Text(e))
        } else {
            ProgressView("Reading the board…")
        }
    }

    /// The eight columns side by side; the board scrolls sideways when the window is narrower.
    private func columns(_ store: KanbanStore, _ board: KanbanBoard) -> some View {
        ScrollView(.horizontal) {
            HStack(alignment: .top, spacing: 10) {
                ForEach(KanbanStatus.columns, id: \.self) { s in column(s, store, board) }
            }
            .padding(12)
        }
        .scrollBounceBehavior(.basedOnSize, axes: .horizontal)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .overlay {
            if board.allTasks.isEmpty {
                ContentUnavailableView {
                    Label("No tasks on this board", systemImage: "rectangle.split.3x1")
                } description: {
                    Text("Make one with New Task; a task with a bot starts in Ready and the dispatcher hands it over.")
                } actions: {
                    Button("New Task") { showNew = true }
                }
                .allowsHitTesting(true)
            }
        }
        // The keys while the Board is in front: arrows move the choice, Return opens the card,
        // Delete asks to delete it, Escape clears the choice. Taken from the window's key
        // events rather than SwiftUI focus, which the inspector took away from the board each
        // time it appeared beside it; a text field being typed in keeps its keys.
        .task(id: active) {
            guard active else { return }
            let monitor = BoardKeys { key in handle(key) }
            defer { monitor.remove() }
            while !Task.isCancelled { try? await Task.sleep(for: .seconds(3600)) }
        }
    }

    private func handle(_ key: BoardKeys.Key) -> Bool {
        switch key {
        case .left: return step(columns: -1) == .handled
        case .right: return step(columns: 1) == .handled
        case .up: return step(rows: -1) == .handled
        case .down: return step(rows: 1) == .handled
        case .return: if let id = selectedID { openTaskID = id; return true }; return false
        case .delete: if let t = selectedTask { ask = .delete(t); return true }; return false
        case .escape: if selectedID != nil { selectedID = nil; return true }; return false
        }
    }

    private func column(_ s: KanbanStatus, _ store: KanbanStore, _ board: KanbanBoard) -> some View {
        let tasks = board.tasks(in: s)
        let isTarget = targeted == s
        return VStack(spacing: 0) {
            HStack(spacing: 6) {
                Image(systemName: s.symbol).font(.caption).foregroundStyle(.secondary)
                Text(s.title).font(.subheadline.weight(.semibold))
                Text("\(tasks.count)").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                    .padding(.horizontal, 6).padding(.vertical, 1).background(.quaternary, in: .capsule)
                Spacer(minLength: 0)
                if let why = s.notMovableReason {
                    Image(systemName: "lock").font(.caption2).foregroundStyle(.tertiary).help(why)
                        .accessibilityLabel("Set by the gateway: \(why)")
                }
            }
            .padding(.horizontal, 10).padding(.vertical, 8)
            ScrollView {
                LazyVStack(spacing: 8) {
                    ForEach(tasks) { task in card(task, store) }
                    if tasks.isEmpty {
                        Text(emptyWords(s)).font(.caption).foregroundStyle(.tertiary).multilineTextAlignment(.center)
                            .frame(maxWidth: .infinity).padding(.vertical, 24).padding(.horizontal, 12)
                    }
                }
                .padding(.horizontal, 8).padding(.bottom, 8)
            }
        }
        .frame(width: Self.columnWidth)
        .frame(maxHeight: .infinity, alignment: .top)
        .background(Color.primary.opacity(0.04), in: .rect(cornerRadius: 12))
        .overlay {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(isTarget ? (s.isMoveTarget ? Color.accentColor : Color.red) : .clear, lineWidth: 2)
        }
        .dropDestination(for: String.self) { ids, _ in drop(ids, into: s, store) } isTargeted: { targeted = $0 ? s : (targeted == s ? nil : targeted) }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(s.title), \(tasks.count) \(tasks.count == 1 ? "task" : "tasks")")
    }

    private func card(_ task: KanbanTask, _ store: KanbanStore) -> some View {
        let selected = task.id == selectedID
        return KanbanCardRow(task: task, worker: store.worker(for: task))
            .padding(10)
            .background(selected ? Color.accentColor.opacity(0.14) : Color(.controlBackgroundColor), in: .rect(cornerRadius: 10))
            .overlay {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(selected ? Color.accentColor : Color.primary.opacity(0.08), lineWidth: selected ? 1.5 : 1)
            }
            .contentShape(.rect)
            .onTapGesture(count: 2) { selectedID = task.id; openTaskID = task.id }
            .onTapGesture { selectedID = task.id }
            .draggable(task.id) {
                Text(task.title).font(.subheadline.weight(.medium)).lineLimit(2)
                    .padding(10).frame(width: Self.columnWidth - 16, alignment: .leading)
                    .background(Color(.controlBackgroundColor), in: .rect(cornerRadius: 10))
            }
            .contextMenu { MacCardMenu(task: task, store: store, ask: $ask, notice: $notice, onOpen: { selectedID = task.id; openTaskID = task.id }, onOpenChat: { openChat($0, profile: $1) }) }
            .accessibilityAddTraits(selected ? .isSelected : [])
            .accessibilityIdentifier("board.card.\(task.id)")
    }

    private func emptyWords(_ s: KanbanStatus) -> String {
        switch s {
        case .ready: return "Cards here are picked up by the dispatcher and handed to their bot."
        case .running: return "A card moves here when a worker claims it."
        case .blocked: return "A worker that cannot go on parks its card here with a reason."
        case .review: return "A worker that wants a look before done asks for review."
        case .done: return "Finished work lands here; archive it to clear the board."
        case .scheduled: return "A card given a time waits here."
        default: return "Drop a card here, or make one with New Task."
        }
    }

    /// Live state and the last read, under the board.
    private func footer(_ store: KanbanStore, _ board: KanbanBoard) -> some View {
        HStack(spacing: 12) {
            if store.liveConnected {
                Label("Live", systemImage: "dot.radiowaves.left.and.right").foregroundStyle(.secondary)
                    .accessibilityLabel("Live updates on")
            } else {
                Label("Reading every minute", systemImage: "clock").foregroundStyle(.tertiary)
            }
            if let e = store.lastError {
                Label(e, systemImage: "exclamationmark.triangle").foregroundStyle(.orange).lineLimit(1).truncationMode(.tail)
            }
            Spacer()
            if let t = store.lastRead { Text("Read \(t, format: .relative(presentation: .named))").foregroundStyle(.tertiary) }
            let n = board.needsAttention
            if n > 0 { Label("\(n) need\(n == 1 ? "s" : "") a look", systemImage: "hand.raised").foregroundStyle(.orange) }
        }
        .font(.caption)
        .padding(.horizontal, 14).padding(.vertical, 6)
        .background(.bar)
    }

    @ToolbarContentBuilder private var toolbar: some ToolbarContent {
        if let store, store.boards.count > 1 {
            ToolbarItem(placement: .navigation) {
                Menu {
                    ForEach(store.boards) { b in
                        Button { selectedID = nil; store.select(board: b.slug) } label: {
                            if b.slug == store.selectedBoard { Label(b.displayName, systemImage: "checkmark") } else { Text(b.displayName) }
                        }
                    }
                } label: { Label(store.selectedBoardMeta?.displayName ?? "Board", systemImage: "square.stack") }
                .help("Choose a board")
                .accessibilityLabel("Choose a board")
            }
        }
        ToolbarItemGroup(placement: .primaryAction) {
            Button { Task { await store?.nudge() } } label: { Label("Nudge Dispatcher", systemImage: "hare") }
                .help("Ask the dispatcher to look at the board now")
                .disabled(store?.isPresent != true)
            Button { Task { await store?.refresh() } } label: { Label("Refresh", systemImage: "arrow.clockwise") }
                .help("Read the board again")
                .disabled(store?.isPresent != true)
            Button { showNew = true } label: { Label("New Task", systemImage: "plus") }
                .help("New Task (⌘N)")
                .disabled(store?.isPresent != true)
                .accessibilityIdentifier("board.new")
        }
    }

    // MARK: Moves

    private func drop(_ ids: [String], into s: KanbanStatus, _ store: KanbanStore) -> Bool {
        guard let id = ids.first, let task = store.board?.task(id: id), task.column != s else { return false }
        guard s.isMoveTarget else { notice = s.notMovableReason; return false }
        selectedID = task.id
        Task { await move(task, to: s, store) }
        return true
    }

    private func move(_ task: KanbanTask, to status: KanbanStatus, _ store: KanbanStore) async {
        switch status {
        case .done: ask = .done(task)
        case .blocked: ask = .block(task)
        case .archived: ask = .archive(task)
        default: await changed(store.move(task, to: status), store)
        }
    }

    /// ⌘[ and ⌘]: the chosen card to the nearest column a hand may put it in, that way.
    private func moveSelected(by direction: Int) async {
        guard let store, let task = selectedTask, let from = task.column, let to = BoardNav.moveTarget(from: from, direction: direction) else { return }
        await move(task, to: to, store)
    }

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
        case .delete(let t): if selectedID == t.id { selectedID = nil }; await changed(store.delete(t), store)
        case .stop(let t): await changed(store.stop(t, reason: "stopped from Vory"), store)
        }
    }

    // MARK: Keys

    private func step(columns: Int) -> KeyPress.Result {
        guard let board = store?.board else { return .ignored }
        guard let id = selectedID, let task = board.task(id: id), let from = task.column else {
            if let first = board.allTasks.first { selectedID = first.id; return .handled }
            return .ignored
        }
        let row = board.tasks(in: from).firstIndex { $0.id == id } ?? 0
        guard let next = BoardNav.neighbour(of: from, direction: columns, filled: { !board.tasks(in: $0).isEmpty }) else { return .handled }
        let tasks = board.tasks(in: next)
        selectedID = tasks[min(row, tasks.count - 1)].id
        return .handled
    }

    private func step(rows: Int) -> KeyPress.Result {
        guard let board = store?.board else { return .ignored }
        guard let id = selectedID, let task = board.task(id: id), let from = task.column else {
            if let first = board.allTasks.first { selectedID = first.id; return .handled }
            return .ignored
        }
        let tasks = board.tasks(in: from)
        guard let i = tasks.firstIndex(where: { $0.id == id }) else { return .handled }
        selectedID = tasks[max(0, min(tasks.count - 1, i + rows))].id
        return .handled
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

/// The Board's keys, read from the window's key events while the page is in front. Nothing is
/// taken while a text field or text view is being typed in, and modifier keys are left to the
/// menus, so ⌘[ and ⌘] still reach the Board menu.
@MainActor
final class BoardKeys {
    enum Key { case left, right, up, down, `return`, delete, escape }
    private var monitor: Any?

    init(handler: @escaping (Key) -> Bool) {
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            guard event.modifierFlags.intersection([.command, .option, .control]).isEmpty,
                  let key = Self.key(for: event.keyCode),
                  let window = event.window, window.isKeyWindow,
                  !(window.firstResponder is NSTextView), !(window.firstResponder is NSTextField) else { return event }
            return MainActor.assumeIsolated { handler(key) } ? nil : event
        }
    }

    func remove() {
        if let m = monitor { NSEvent.removeMonitor(m); monitor = nil }
    }

    private static func key(for code: UInt16) -> Key? {
        switch code {
        case 123: return .left
        case 124: return .right
        case 126: return .up
        case 125: return .down
        case 36, 76: return .return
        case 51, 117: return .delete
        case 53: return .escape
        default: return nil
        }
    }
}

/// Where the keys take the choice and the card, worked out apart from the view.
enum BoardNav {
    /// The next column that way with a card in it; nil at the edge.
    static func neighbour(of column: KanbanStatus, direction: Int, filled: (KanbanStatus) -> Bool) -> KanbanStatus? {
        let order = KanbanStatus.columns
        guard let i = order.firstIndex(of: column), direction != 0 else { return nil }
        var j = i + direction
        while order.indices.contains(j) {
            if filled(order[j]) { return order[j] }
            j += direction
        }
        return nil
    }

    /// The nearest column that way a hand may put a card in (never archived, which has its
    /// own command); nil at the edge or when the card is not on the board's columns.
    static func moveTarget(from column: KanbanStatus, direction: Int) -> KanbanStatus? {
        let order = KanbanStatus.columns
        guard let i = order.firstIndex(of: column), direction != 0 else { return nil }
        var j = i + direction
        while order.indices.contains(j) {
            if order[j].isMoveTarget { return order[j] }
            j += direction
        }
        return nil
    }
}

/// What the Board menu asks of the page in front: a new task, the chosen card moved a column,
/// or opened. The page answers only while it is the one showing.
@MainActor @Observable
final class BoardCommands {
    static let shared = BoardCommands()
    struct Move: Equatable { var direction: Int; var at = Date() }
    var selectedID: String?
    var newTaskRequest: UUID?
    var moveRequest: Move?
    var openRequest: UUID?
    func move(_ direction: Int) { moveRequest = Move(direction: direction) }
}

/// A card's menu: the same choices as the phone's, from the same rules.
private struct MacCardMenu: View {
    var task: KanbanTask
    var store: KanbanStore
    @Binding var ask: KanbanAsk?
    @Binding var notice: String?
    var onOpen: () -> Void
    var onOpenChat: (String, String?) -> Void

    var body: some View {
        Button { onOpen() } label: { Label("Open", systemImage: "rectangle.expand.vertical") }
        Divider()
        Menu {
            ForEach(KanbanStatus.allCases.filter { $0 != task.column }, id: \.self) { s in
                if s.isMoveTarget {
                    Button { Task { await move(to: s) } } label: { Label(s.title, systemImage: s.symbol) }
                } else {
                    Button { notice = s.notMovableReason } label: { Label("\(s.title) (gateway only)", systemImage: s.symbol) }
                }
            }
        } label: { Label("Move to", systemImage: "arrow.right.square") }
        Menu {
            Button { Task { await reassign(nil) } } label: {
                if task.assignee == nil { Label("Unassigned", systemImage: "checkmark") } else { Text("Unassigned") }
            }
            ForEach(store.assignees) { a in
                Button { Task { await reassign(a.name) } } label: {
                    if task.assignee == a.name { Label(a.name, systemImage: "checkmark") } else { Text(a.name) }
                }
            }
        } label: { Label("Reassign", systemImage: "person.crop.circle.badge.checkmark") }
        Menu {
            ForEach(0..<4, id: \.self) { p in
                Button { Task { if !(await store.setPriority(task, p)), let e = store.lastError { notice = e } } } label: {
                    if (task.priority ?? 0) == p { Label(KanbanView.priorityName(p), systemImage: "checkmark") } else { Text(KanbanView.priorityName(p)) }
                }
            }
        } label: { Label("Priority", systemImage: "flag") }
        Button { ask = .comment(task) } label: { Label("Comment…", systemImage: "bubble.left") }
        if task.column == .blocked {
            Button { Task { await move(to: .ready) } } label: { Label("Unblock", systemImage: "play") }
        } else if task.column != .done, task.column != .archived, !task.isWorking {
            Button { ask = .block(task) } label: { Label("Block…", systemImage: "hand.raised") }
        }
        if task.column != .done, task.column != .archived { Button { ask = .done(task) } label: { Label("Done…", systemImage: "checkmark") } }
        if task.isWorking { Button { ask = .stop(task) } label: { Label("Stop the Worker…", systemImage: "stop.circle") } }
        if let sid = task.sessionId, !sid.isEmpty { Button { onOpenChat(sid, task.assignee) } label: { Label("Open Chat", systemImage: "bubble.left.and.bubble.right") } }
        Divider()
        if task.column != .archived { Button { ask = .archive(task) } label: { Label("Archive…", systemImage: "archivebox") } }
        Button(role: .destructive) { ask = .delete(task) } label: { Label("Delete…", systemImage: "trash") }
    }

    private func move(to status: KanbanStatus) async {
        switch status {
        case .done: ask = .done(task)
        case .blocked: ask = .block(task)
        case .archived: ask = .archive(task)
        default: if !(await store.move(task, to: status)), let e = store.lastError { notice = e }
        }
    }

    private func reassign(_ profile: String?) async {
        if !(await store.reassign(task, to: profile)), let e = store.lastError { notice = e }
    }
}

/// The questions a change asks first, and the notice for a refusal: the same words as the
/// phone's, as modifiers so the board and the inspector share them.
private struct KanbanAskModifier: ViewModifier {
    @Binding var ask: KanbanAsk?
    @Binding var answer: String
    @Binding var notice: String?
    var answerAsk: (KanbanAsk) async -> Void

    func body(content: Content) -> some View {
        content
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
}

private extension View {
    func kanbanAsks(ask: Binding<KanbanAsk?>, answer: Binding<String>, notice: Binding<String?>, answerAsk: @escaping (KanbanAsk) async -> Void) -> some View {
        modifier(KanbanAskModifier(ask: ask, answer: answer, notice: notice, answerAsk: answerAsk))
    }
}

/// The chosen card beside the board: what it is, where it is and whose it is (each changeable
/// in place), its body, result and children, the runs and the worker's log, the comments with
/// a composer, and its history. Reads again every few seconds while a worker is on it.
struct MacTaskInspector: View {
    var taskID: String
    var store: KanbanStore?
    var onClose: () -> Void
    var onOpenChat: (String, String?) -> Void

    @Environment(AppModel.self) private var model
    @State private var detail: KanbanTaskDetail?
    @State private var error: String?
    @State private var comment = ""
    @State private var sending = false
    @State private var editingBody = false
    @State private var bodyDraft = ""
    @State private var editingTitle = false
    @State private var titleDraft = ""
    @State private var showLog = false
    @State private var ask: KanbanAsk?
    @State private var answer = ""
    @State private var notice: String?

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            Group {
                if let d = detail { form(d) }
                else if let error { ContentUnavailableView("Could not read the task", systemImage: "exclamationmark.triangle", description: Text(error)) }
                else { ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity) }
            }
        }
        .background(Color(.windowBackgroundColor))
        .task(id: taskID) { editingBody = false; editingTitle = false; detail = nil; await load() }
        // The board read again (a move, an event): the card's facts follow.
        .onChange(of: store?.lastRead) { _, _ in Task { await load() } }
        .task(id: detail?.task.isWorking) {
            guard detail?.task.isWorking == true else { return }
            while !Task.isCancelled { try? await Task.sleep(for: .seconds(6)); guard !Task.isCancelled else { break }; await load() }
        }
        .kanbanAsks(ask: $ask, answer: $answer, notice: $notice) { a in await answerAsk(a) }
        .accessibilityIdentifier("board.inspector")
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 8) {
            if editingTitle {
                TextField("Title", text: $titleDraft).textFieldStyle(.roundedBorder).font(.headline)
                    .onSubmit { Task { await saveTitle() } }
                Button("Save") { Task { await saveTitle() } }.disabled(titleDraft.trimmingCharacters(in: .whitespaces).isEmpty)
                Button("Cancel") { editingTitle = false }
            } else {
                Text(detail?.task.title ?? "Task").font(.headline).lineLimit(3).textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .onTapGesture(count: 2) { if let t = detail?.task { titleDraft = t.title; editingTitle = true } }
                Button { if let t = detail?.task { titleDraft = t.title; editingTitle = true } } label: { Image(systemName: "pencil") }
                    .buttonStyle(.plain).foregroundStyle(.secondary).help("Rename")
                    .disabled(detail == nil)
                Button { onClose() } label: { Image(systemName: "xmark.circle.fill") }
                    .buttonStyle(.plain).foregroundStyle(.secondary).help("Close the inspector")
                    .accessibilityLabel("Close")
            }
        }
        .padding(12)
    }

    @ViewBuilder private func form(_ d: KanbanTaskDetail) -> some View {
        let t = d.task
        Form {
            Section {
                Picker("Status", selection: Binding(get: { t.column ?? .triage }, set: { s in if s != t.column { Task { await move(t, to: s) } } })) {
                    ForEach(KanbanStatus.allCases, id: \.self) { s in
                        Label(s.title, systemImage: s.symbol).tag(s)
                            .selectionDisabled(!s.isMoveTarget && s != t.column)
                    }
                }
                Picker("Bot", selection: Binding(get: { t.assignee ?? "" }, set: { p in if p != (t.assignee ?? "") { Task { await changed(store?.reassign(t, to: p.isEmpty ? nil : p) ?? false) } } })) {
                    Text("Unassigned").tag("")
                    ForEach(bots(t), id: \.self) { b in
                        HStack(spacing: 6) { BotAvatar(profile: b, size: 14); Text(b) }.tag(b)
                    }
                }
                Picker("Priority", selection: Binding(get: { t.priority ?? 0 }, set: { p in if p != (t.priority ?? 0) { Task { await changed(store?.setPriority(t, p) ?? false) } } })) {
                    ForEach(0..<4, id: \.self) { p in Text(KanbanView.priorityName(p)).tag(p) }
                }
                if let c = t.created { LabeledContent("Made") { Text(c, format: .relative(presentation: .named)) } }
                if let tenant = t.tenant, !tenant.isEmpty { LabeledContent("Tenant", value: tenant) }
                LabeledContent("Id") { Text(t.id).font(.caption.monospaced()).textSelection(.enabled) }
            }
            if t.isWorking || (t.sessionId?.isEmpty == false) {
                Section {
                    HStack {
                        if let sid = t.sessionId, !sid.isEmpty {
                            Button { onOpenChat(sid, t.assignee) } label: { Label("Open Chat", systemImage: "bubble.left.and.bubble.right") }
                        }
                        if t.isWorking {
                            Button(role: .destructive) { ask = .stop(t) } label: { Label("Stop the Worker…", systemImage: "stop.circle") }
                        }
                    }
                }
            }
            if !t.warnings.isEmpty {
                Section("Needs a look") {
                    ForEach(Array(t.warnings.enumerated()), id: \.offset) { _, w in Label(w.text, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange) }
                }
            }
            Section {
                if editingBody {
                    TextEditor(text: $bodyDraft).font(.body).frame(minHeight: 120)
                    HStack {
                        Spacer()
                        Button("Cancel") { editingBody = false }
                        Button("Save") { Task { await saveBody() } }.keyboardShortcut(.defaultAction)
                    }
                } else if let b = t.body, !b.isEmpty {
                    MarkdownView(text: b)
                } else {
                    Text("No description yet.").foregroundStyle(.secondary)
                }
            } header: {
                HStack {
                    Text("Task")
                    Spacer()
                    if !editingBody {
                        Button { bodyDraft = t.body ?? ""; editingBody = true } label: { Image(systemName: "pencil") }.buttonStyle(.plain).help("Edit the description")
                    }
                }
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
                            if let e = run.error, !e.isEmpty { Text(e).font(.caption).foregroundStyle(.red).lineLimit(3) }
                            if let s = run.summary, !s.isEmpty { Text(s).font(.caption).foregroundStyle(.secondary).lineLimit(4) }
                        }
                        Spacer()
                        if run.isOpen { ProgressView().controlSize(.small) }
                    }
                }
                DisclosureGroup("Worker log", isExpanded: $showLog) {
                    if showLog { KanbanLogView(taskID: t.id, live: t.isWorking).frame(minHeight: 160, maxHeight: 320) }
                }
            }
            Section("Comments") {
                if d.comments.isEmpty { Text("No comments yet.").foregroundStyle(.secondary) }
                ForEach(d.comments) { c in
                    VStack(alignment: .leading, spacing: 2) {
                        HStack { Text(c.author).font(.caption.weight(.semibold)); Spacer(); Text(c.created, format: .relative(presentation: .named)).font(.caption2).foregroundStyle(.tertiary) }
                        Text(c.body).font(.subheadline).textSelection(.enabled)
                    }
                }
                HStack(alignment: .bottom) {
                    TextField(t.isWorking ? "Message the running worker" : "Add a comment", text: $comment, axis: .vertical).lineLimit(1...5)
                        .onSubmit { Task { await send() } }
                    Button { Task { await send() } } label: { Image(systemName: "arrow.up.circle.fill").font(.title2) }
                        .buttonStyle(.plain).foregroundStyle(.tint)
                        .disabled(comment.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || sending)
                        .accessibilityLabel("Send the comment")
                }
            }
            if !d.events.isEmpty {
                Section("History") {
                    ForEach(d.events.suffix(16).reversed()) { e in
                        HStack { Text(e.line).font(.caption); Spacer(); Text(e.created, format: .relative(presentation: .named)).font(.caption2).foregroundStyle(.tertiary) }
                    }
                }
            }
        }
        .formStyle(.grouped)
    }

    private func bots(_ t: KanbanTask) -> [String] {
        var names = store?.assignees.map(\.name) ?? []
        for p in model.runtime?.profiles ?? [] where !names.contains(p.name) { names.append(p.name) }
        if let a = t.assignee, !a.isEmpty, !names.contains(a) { names.append(a) }
        return names
    }

    private func load() async {
        guard let store else { return }
        do { detail = try await store.detail(taskID); error = nil } catch { if detail == nil { self.error = KanbanStore.message(error) } }
    }

    private func move(_ t: KanbanTask, to status: KanbanStatus) async {
        guard status.isMoveTarget else { notice = status.notMovableReason; return }
        switch status {
        case .done: ask = .done(t)
        case .blocked: ask = .block(t)
        case .archived: ask = .archive(t)
        default: await changed(store?.move(t, to: status) ?? false)
        }
    }

    private func changed(_ ok: Bool) async {
        if !ok, let e = store?.lastError { notice = e }
        await load()
    }

    private func answerAsk(_ a: KanbanAsk) async {
        guard let store else { return }
        let text = answer.trimmingCharacters(in: .whitespacesAndNewlines)
        answer = ""; ask = nil
        switch a {
        case .done(let t): await changed(store.move(t, to: .done, summary: text))
        case .block(let t): await changed(store.move(t, to: .blocked, blockReason: text))
        case .comment(let t): if !text.isEmpty { await changed(store.comment(t, text)) }
        case .archive(let t): await changed(store.move(t, to: .archived))
        case .delete(let t): await changed(store.delete(t)); onClose()
        case .stop(let t): await changed(store.stop(t, reason: "stopped from Vory"))
        }
    }

    private func saveTitle() async {
        guard let store, let t = detail?.task else { return }
        let title = titleDraft.trimmingCharacters(in: .whitespaces)
        guard !title.isEmpty else { return }
        editingTitle = false
        if title != t.title { await changed(store.edit(t, title: title, body: nil)) }
    }

    private func saveBody() async {
        guard let store, let t = detail?.task else { return }
        editingBody = false
        if bodyDraft != (t.body ?? "") { await changed(store.edit(t, title: nil, body: bodyDraft)) }
    }

    private func send() async {
        guard let store, let d = detail else { return }
        let text = comment.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        sending = true; defer { sending = false }
        if await store.comment(d.task, text) { comment = ""; await load() } else { notice = store.lastError }
    }
}
