import FoundationModels
import SwiftUI
import VoryCore

extension Notification.Name {
    /// A working chat's status line was written or rewritten. `userInfo`: "storedID" and "goal".
    static let voryGoalChanged = Notification.Name("vory.goalChanged")
}

/// The status line for a chat whose bot is working: what it is trying to get done ("Finding
/// why the export times out"), not the step it is on this second. Written by the on-device
/// model as part of Vory Summaries, from the prompt and the steps taken so far, shortly after
/// a turn starts and again as the work moves on, never more often than `Pace` allows.
/// Nothing is stored and nothing leaves the device. Where the model is off or cannot run
/// there is no line, and the places that show one fall back to the chat's current step.
@MainActor @Observable
final class ChatGoals {
    static let shared = ChatGoals()
    /// The third Vory Summaries switch. Unset, it follows the other two.
    static let enabledKey = "chats.aiSummaries.goals"
    static var isOn: Bool {
        UserDefaults.standard.object(forKey: enabledKey) as? Bool ?? (ChatSummarizer.titlesOn || ChatSummarizer.previewsOn)
    }

    struct Goal: Equatable {
        var text: String
        /// The turn it was written for: a line never outlives its turn.
        var turn: String
        var madeAt: Date
        /// How many steps the turn had taken when it was written.
        var steps: Int
    }

    /// What the model is given.
    struct Input: Equatable, Sendable {
        var prompt: String
        var steps: [String]
        var said: String?
        var earlier: String?
    }

    /// When a line is due. Kept apart from the model so it can be tested by itself.
    enum Pace {
        /// A turn this young gets no line: a quick answer is over before one would be read.
        static let firstDelay: TimeInterval = 2
        /// The first line is written from the prompt alone, so it is looked at again sooner.
        static let gapAfterFirst: TimeInterval = 15
        static let gap: TimeInterval = 45
        static let stepsAfterFirst = 2
        static let steps = 3

        static func due(goal: Goal?, turn: String, turnAge: TimeInterval, steps: Int, now: Date) -> Bool {
            guard let goal, goal.turn == turn else { return turnAge >= firstDelay }
            let fromPromptOnly = goal.steps == 0
            let waited = now.timeIntervalSince(goal.madeAt)
            return steps - goal.steps >= (fromPromptOnly ? stepsAfterFirst : Pace.steps) && waited >= (fromPromptOnly ? gapAfterFirst : gap)
        }
    }

    private(set) var goals: [String: Goal] = [:]
    /// Writes the line; nil when it cannot. Swapped out in tests.
    var writer: @Sendable (Input) async -> String? = ChatGoals.onDevice
    var now: () -> Date = Date.init
    /// The Vory Summaries switch for this line.
    var on: () -> Bool = { ChatGoals.isOn }

    /// When each running chat's turn was first seen, by stored id.
    private var turns: [String: (turn: String, since: Date)] = [:]
    private var writing: Set<String> = []
    private var loop: Task<Void, Never>?
    private weak var runtime: GatewayRuntime?

    /// The line for a chat, while its bot is working and one has been written.
    func goal(for storedID: String) -> String? {
        guard on(), !storedID.isEmpty else { return nil }
        return goals[storedID]?.text
    }

    /// A chat whose bot is working, reduced to what a line is written from.
    struct Working: Equatable, Sendable {
        var id: String
        var turn: String
        var steps: Int
        var input: Input

        @MainActor init(_ chat: ChatSession, earlier: String?) {
            id = chat.storedID
            turn = ChatGoals.turnKey(chat.items)
            steps = ChatGoals.stepCount(chat.items)
            input = ChatGoals.input(chat.items, earlier: earlier)
        }
        init(id: String, turn: String, steps: Int, input: Input) {
            self.id = id; self.turn = turn; self.steps = steps; self.input = input
        }
    }

    /// Follows the chats of `runtime` from now on (the gateway in use).
    func attach(_ runtime: GatewayRuntime?) {
        guard runtime !== self.runtime || loop == nil else { return }
        self.runtime = runtime
        goals = [:]; turns = [:]
        loop?.cancel()
        guard runtime != nil else { loop = nil; return }
        loop = Task { [weak self] in
            while !Task.isCancelled {
                guard let self, let rt = self.runtime else { return }
                let working = rt.chats.filter { $0.isRunning && !$0.storedID.isEmpty }.map { Working($0, earlier: self.goals[$0.storedID]?.text) }
                self.tick(working) { [weak rt] id in
                    rt?.chatForStored(id).flatMap { $0.isRunning ? ChatGoals.turnKey($0.items) : nil }
                }
                try? await Task.sleep(for: .seconds(working.isEmpty ? 5 : 2))
            }
        }
    }

    /// One look at the working chats: lines for turns that ended are dropped, and one that is
    /// due is written. `turnNow` answers the turn a chat is on when the model comes back (nil
    /// when it is no longer working), so a line never lands on a turn it was not written for.
    func tick(_ working: [Working], turnNow: @escaping @MainActor (String) -> String?) {
        let ids = Set(working.map(\.id))
        for id in goals.keys where !ids.contains(id) { goals[id] = nil }
        for id in turns.keys where !ids.contains(id) { turns[id] = nil }
        guard on() else { goals = [:]; return }
        let t = now()
        for chat in working {
            let id = chat.id, turn = chat.turn
            if turns[id]?.turn != turn { turns[id] = (turn, t) }
            if let g = goals[id], g.turn != turn { goals[id] = nil }
            // One at a time: the model is shared with the summaries.
            guard writing.isEmpty else { continue }
            guard !chat.input.prompt.isEmpty || !chat.input.steps.isEmpty else { continue }
            guard Pace.due(goal: goals[id], turn: turn, turnAge: t.timeIntervalSince(turns[id]?.since ?? t), steps: chat.steps, now: t) else { continue }
            writing.insert(id)
            let writer = self.writer
            Task(priority: .utility) { [weak self] in
                let text = await writer(chat.input)
                guard let self else { return }
                self.writing.remove(id)
                // The turn may have ended, or a new one begun, while the model was writing.
                guard turnNow(id) == turn else { return }
                guard let text = text.flatMap(Self.clean) else {
                    // No line this time: wait a full gap before asking again, so a model that
                    // is off or keeps refusing is not asked every two seconds.
                    if self.goals[id] == nil { self.turns[id] = (turn, self.now().addingTimeInterval(Pace.gap)) }
                    return
                }
                let changed = self.goals[id]?.text != text
                self.goals[id] = Goal(text: text, turn: turn, madeAt: self.now(), steps: chat.steps)
                if changed {
                    NotificationCenter.default.post(name: .voryGoalChanged, object: nil, userInfo: ["storedID": id, "goal": text])
                }
            }
        }
    }

    /// True while a line is being written (tests wait on this).
    var isWriting: Bool { !writing.isEmpty }

    // MARK: What the model reads

    /// The turn a chat is on: its last message from the user.
    static func turnKey(_ items: [TranscriptItem]) -> String {
        items.last(where: { if case .user = $0.kind { return true }; return false })?.id ?? "start"
    }

    private static func turnItems(_ items: [TranscriptItem]) -> ArraySlice<TranscriptItem> {
        let start = items.lastIndex(where: { if case .user = $0.kind { return true }; return false }) ?? items.startIndex
        return items[start...]
    }

    static func stepCount(_ items: [TranscriptItem]) -> Int {
        turnItems(items).reduce(0) { n, item in
            switch item.kind {
            case .tool, .subagent: return n + 1
            default: return n
            }
        }
    }

    static func input(_ items: [TranscriptItem], earlier: String?) -> Input {
        var prompt = "", steps: [String] = [], said: String?
        for item in turnItems(items) {
            switch item.kind {
            case .user(let text, let attachments):
                prompt = text.isEmpty && !attachments.isEmpty ? "(sent \(attachments.count == 1 ? "a file" : "\(attachments.count) files"))" : text
            case .steer(let text, _):
                // A message steered into the turn changes what it is for.
                if !text.isEmpty { prompt += "\nThen the user added: \(text)" }
            case .tool(let act):
                let detail = (act.context ?? act.summary ?? "").replacingOccurrences(of: "\n", with: " ")
                steps.append(detail.isEmpty ? act.displayName : "\(act.displayName): \(detail.prefix(120))")
            case .subagent(let goal, _):
                steps.append("handed a helper this: \(goal.prefix(120))")
            case .assistant(let text, _, _):
                let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
                if !t.isEmpty { said = String(t.suffix(320)) }
            case .system, .error:
                break
            }
        }
        return Input(prompt: String(prompt.prefix(800)), steps: Array(steps.suffix(8)), said: said, earlier: earlier)
    }

    // MARK: The model

    @Generable
    struct Line {
        @Guide(description: "What the assistant is working on right now, as one phrase of three to seven words that starts with a verb ending in -ing. It names the task, not the tool. No period, no quotes.")
        var goal: String
    }

    nonisolated static func onDevice(_ input: Input) async -> String? {
        guard case .available = SystemLanguageModel.default.availability else { return nil }
        var parts = ["The user asked: \(input.prompt.isEmpty ? "(nothing typed)" : input.prompt)"]
        if !input.steps.isEmpty { parts.append("Steps the assistant has taken, oldest first:\n" + input.steps.map { "- \($0)" }.joined(separator: "\n")) }
        if let said = input.said { parts.append("The assistant last wrote: \(said)") }
        if let earlier = input.earlier { parts.append("The status line until now: \(earlier)\nKeep it when it still fits; change it when the work has moved on to something else.") }
        do {
            let ai = LanguageModelSession(instructions: "You write the status line for an AI assistant that is busy with a task for its user. Say what it is trying to get done, in plain words that can be read at a glance. Do not name tools or commands. Do not address the user. Do not say that it is working or thinking.")
            return try await ai.respond(to: parts.joined(separator: "\n\n"), generating: Line.self).content.goal
        } catch {
            return nil   // refused, timed out or busy: the chat shows its current step
        }
    }

    /// The model's words made fit for one line: no quotes, no period, a capital, and not long.
    nonisolated static func clean(_ raw: String) -> String? {
        var t = raw.split(whereSeparator: \.isNewline).first.map(String.init) ?? ""
        t = t.trimmingCharacters(in: .whitespaces).trimmingCharacters(in: CharacterSet(charactersIn: "\"'“”‘’`*"))
        while let last = t.last, ".…!:;,".contains(last) { t.removeLast() }
        t = t.trimmingCharacters(in: .whitespaces)
        guard t.count >= 3 else { return nil }
        if t.count > 64 {
            // Cut at a word, so the line does not end mid-word.
            let cut = t.prefix(64)
            t = (cut.lastIndex(of: " ").map { String(cut[..<$0]) } ?? String(cut)) + "…"
        }
        return t.prefix(1).uppercased() + t.dropFirst()
    }
}

/// The line a working chat shows at a glance: its goal when one is written, else the step it
/// is on. `step` is the chat's own status ("Running terminal…").
struct ChatGoalLine: View {
    var storedID: String
    var step: String?
    var font: Font = .subheadline
    private var goals: ChatGoals { ChatGoals.shared }

    var body: some View {
        let goal = goals.goal(for: storedID)
        if let text = goal ?? step, !text.isEmpty {
            HStack(spacing: 4) {
                if goal != nil { Image(systemName: "sparkles").font(.caption2).accessibilityHidden(true) }
                Text(text).lineLimit(1)
            }
            .font(font)
            .foregroundStyle(.tint)
            .contentTransition(.opacity)
            .animation(.snappy, value: text)
            .accessibilityLabel(goal.map { "Working on: \($0)" } ?? text)
        }
    }
}
