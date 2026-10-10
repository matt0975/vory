import AppIntents
#if canImport(UIKit)
import UIKit
#endif
import VoryCore

// MARK: Siri, Shortcuts, Spotlight and the Action Button
//
// Two App Shortcuts: "Ask Vory" puts a question to the bot without opening the app and Siri
// reads the short answer (or says it will let you know, when the bot takes longer than Siri
// waits); "Start voice mode" opens the app on a new chat with hands-free on (the Mac's floating
// voice window). Generic phrases only: nothing here names anyone's bot or gateway.

/// A question to the bot, answered in a few spoken sentences. The same "Siri" chat takes every
/// question, so a follow-up ("and yesterday?") makes sense to the bot.
struct AskVoryIntent: AppIntent {
    static let title: LocalizedStringResource = "Ask Vory"
    static let description = IntentDescription("Asks your bot a question and reads out the short answer.")
    static let openAppWhenRun = false

    @Parameter(title: "Question", requestValueDialog: "What do you want to ask?")
    var question: String
    /// Which bot: the default one when none is named (#310).
    @Parameter(title: "Bot")
    var bot: BotEntity?

    static var parameterSummary: some ParameterSummary {
        Summary("Ask \(\.$question)") { \.$bot }
    }

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let answer = await SiriAsk.ask(question, bot: bot)
        return .result(dialog: IntentDialog(stringLiteral: answer))
    }
}

/// Opens one of the recent chats by its title (Siri, Shortcuts, Spotlight).
struct OpenChatIntent: AppIntent {
    static let title: LocalizedStringResource = "Open Chat"
    static let description = IntentDescription("Opens one of your recent chats in Vory.")
    static let openAppWhenRun = true

    @Parameter(title: "Chat")
    var chat: ChatEntity

    static var parameterSummary: some ParameterSummary { Summary("Open \(\.$chat)") }

    @MainActor
    func perform() async throws -> some IntentResult {
        #if os(macOS)
        MacWindow.bringMainForward()
        #endif
        AppModel.shared.openStoredChat(id: chat.id, profile: chat.bot)
        return .result()
    }
}

/// A new chat, with the named bot or the default one.
struct NewChatIntent: AppIntent {
    static let title: LocalizedStringResource = "New Chat"
    static let description = IntentDescription("Starts a new chat in Vory, with the bot you name or the default one.")
    static let openAppWhenRun = true

    @Parameter(title: "Bot")
    var bot: BotEntity?

    static var parameterSummary: some ParameterSummary { Summary("New chat with \(\.$bot)") }

    @MainActor
    func perform() async throws -> some IntentResult {
        #if os(macOS)
        MacWindow.bringMainForward()
        #endif
        AppModel.shared.requestNewChat(profile: bot?.id)
        return .result()
    }
}

/// "What's my bot doing?": what is running and how many approvals wait, in a sentence or two.
struct BotStatusIntent: AppIntent {
    static let title: LocalizedStringResource = "Bot Status"
    static let description = IntentDescription("Says what your bot is working on and whether anything waits for you.")
    static let openAppWhenRun = false

    @Parameter(title: "Bot")
    var bot: BotEntity?

    static var parameterSummary: some ParameterSummary { Summary("What is \(\.$bot) doing") }

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let line = await SiriAsk.status(bot: bot)
        return .result(dialog: IntentDialog(stringLiteral: line))
    }
}

/// Answers the one waiting approval, by voice, only with the switch on, on an unlocked device,
/// and after a confirmation that names the bot and what it wants to do (#311). Voice mode
/// keeps the standing rule and never answers approvals.
struct AnswerApprovalIntent: AppIntent {
    static let title: LocalizedStringResource = "Answer Approval"
    static let description = IntentDescription("Approves or denies the approval waiting in Vory, after reading it to you.")
    static let openAppWhenRun = false
    static let authenticationPolicy: IntentAuthenticationPolicy = .requiresAuthentication

    @Parameter(title: "Answer", default: .approve)
    var answer: ApprovalAnswer

    static var parameterSummary: some ParameterSummary { Summary("\(\.$answer) the waiting approval") }

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        guard SiriCatalog.answersApprovals else {
            return .result(dialog: "Siri does not answer approvals. Turn on Let Siri answer approvals in Settings, under Siri, if you want that.")
        }
        guard let found = await SiriAsk.waitingApproval() else {
            return .result(dialog: IntentDialog(stringLiteral: await SiriAsk.noApprovalLine()))
        }
        let question = SiriWords.approvalQuestion(bot: found.bot, request: found.request, answer: answer)
        try await requestConfirmation(result: .result(dialog: IntentDialog(stringLiteral: question)))
        await found.chat.respond(card: found.card, result: ["choice": .string(answer == .approve ? "once" : "deny")])
        return .result(dialog: answer == .approve ? "Approved." : "Denied.")
    }
}

/// Opens the app on a new chat with the default bot and starts hands-free on it (the Action
/// Button's natural job).
struct StartVoiceModeIntent: AppIntent {
    static let title: LocalizedStringResource = "Start Voice Mode"
    static let description = IntentDescription("Opens Vory and starts a voice conversation with your bot.")
    static let openAppWhenRun = true

    /// Which bot: the default one when none is named (#310).
    @Parameter(title: "Bot")
    var bot: BotEntity?

    static var parameterSummary: some ParameterSummary { Summary("Start voice mode with \(\.$bot)") }

    @MainActor
    func perform() async throws -> some IntentResult {
        #if os(macOS)
        // The app may be running with its window closed (the menu bar keeps it alive): the
        // window comes back first, or the new chat the request opens has no list to open in.
        MacWindow.bringMainForward()
        #endif
        AppModel.shared.requestVoiceMode(profile: bot?.id)
        return .result()
    }
}

struct VoryShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(intent: AskVoryIntent(),
                    phrases: ["Ask \(.applicationName)", "Ask \(.applicationName) a question", "Ask \(.applicationName) something",
                              "Ask \(\.$bot) in \(.applicationName)", "Ask \(\.$bot) something in \(.applicationName)"],
                    shortTitle: "Ask Vory", systemImageName: "bubble.left.and.text.bubble.right")
        AppShortcut(intent: StartVoiceModeIntent(),
                    phrases: ["Start voice mode in \(.applicationName)", "Talk to \(.applicationName)", "\(.applicationName) voice mode",
                              "Talk to \(\.$bot) in \(.applicationName)"],
                    shortTitle: "Voice Mode", systemImageName: "waveform.badge.mic")
        AppShortcut(intent: OpenChatIntent(),
                    phrases: ["Open my \(\.$chat) chat in \(.applicationName)", "Open \(\.$chat) in \(.applicationName)"],
                    shortTitle: "Open Chat", systemImageName: "bubble.left")
        AppShortcut(intent: NewChatIntent(),
                    phrases: ["New chat in \(.applicationName)", "Start a new chat in \(.applicationName)", "New chat with \(\.$bot) in \(.applicationName)"],
                    shortTitle: "New Chat", systemImageName: "square.and.pencil")
        AppShortcut(intent: BotStatusIntent(),
                    phrases: ["What is my bot doing in \(.applicationName)", "\(.applicationName) status", "What is \(\.$bot) doing in \(.applicationName)"],
                    shortTitle: "Bot Status", systemImageName: "waveform.path.ecg")
        AppShortcut(intent: AnswerApprovalIntent(),
                    phrases: ["Answer the approval in \(.applicationName)", "\(.applicationName) approval"],
                    shortTitle: "Answer Approval", systemImageName: "checkmark.shield")
    }
}

/// "Ask Vory" without the app on screen: the saved gateway is brought up, the Siri chat opened
/// (or made), the question sent as a spoken turn, and the reply waited for as long as Siri
/// allows. Longer than that, Siri says the bot is on it; the answer lands in the chat (and
/// arrives as a notification where the Companion is installed).
@MainActor
enum SiriAsk {
    static let chatKey = "siri.chatID"
    static let chatTitle = "Siri"
    /// Siri gives an intent about half a minute; the bot gets most of it.
    static let waitLimit: TimeInterval = 22
    static let answerLimit = 700

    /// The gateway brought up and its socket open, or the line Siri says instead.
    enum Connected { case ready(GatewayRuntime), failed(String) }
    static func connectedRuntime() async -> Connected {
        let model = AppModel.shared
        guard model.hasConnections else { return .failed("Set up a gateway in Vory first.") }
        if model.runtime == nil { await model.activateSavedConnection() }
        guard let rt = model.runtime else { return .failed("Vory could not reach your gateway.") }
        let deadline = Date().addingTimeInterval(10)
        while !rt.socketState.isOpen, Date() < deadline { try? await Task.sleep(for: .milliseconds(250)) }
        guard rt.socketState.isOpen else { return .failed("Your gateway isn't answering right now.") }
        return .ready(rt)
    }

    /// What is running and what waits, as Siri says it (#310).
    static func status(bot: BotEntity?) async -> String {
        #if os(iOS)
        let time = BackgroundTime("vory.siri.status")
        defer { time.end() }
        #endif
        let rt: GatewayRuntime
        switch await connectedRuntime() {
        case .failed(let why): return why
        case .ready(let r): rt = r
        }
        let running = rt.chats.filter(\.isRunning).map { (bot: $0.profileName, title: $0.title.isEmpty ? "a chat" : $0.title) }
        let waiting = Set(rt.chats.filter(\.needsAttention).map(\.storedID)).union(rt.needsAttention).count
        return SiriWords.status(running: running, waiting: waiting, bot: bot?.label)
    }

    /// The one approval waiting across the open chats, with its chat and bot; nil when none
    /// or several wait (then the screen is the place to choose).
    static func waitingApproval() async -> (chat: ChatSession, card: PendingCard, request: ApprovalRequest, bot: String)? {
        guard case .ready(let rt) = await connectedRuntime() else { return nil }
        let found = rt.chats.flatMap { chat in chat.cards.compactMap { card in card.approval.map { (chat: chat, card: card, request: $0, bot: chat.profileName) } } }
        return found.count == 1 ? found.first : nil
    }

    static func noApprovalLine() async -> String {
        guard case .ready(let rt) = await connectedRuntime() else { return "Vory could not reach your gateway." }
        let n = rt.chats.flatMap { $0.cards.filter { $0.approval != nil } }.count
        return n > 1 ? "\(n) approvals are waiting; open Vory to pick one." : "No approval is waiting."
    }

    static func ask(_ question: String, bot: BotEntity? = nil) async -> String {
        let q = question.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return "I didn't catch a question." }
        #if os(iOS)
        let time = BackgroundTime("vory.siri.ask")
        defer { time.end() }
        #endif
        let rt: GatewayRuntime
        switch await connectedRuntime() {
        case .failed(let why): return why
        case .ready(let r): rt = r
        }
        guard let chat = await siriChat(on: rt, bot: bot) else { return "Vory could not open a chat on your gateway." }
        // A spoken answer within Siri's time: quick answers for this question, put back after.
        await chat.beginQuickAnswers()
        defer { Task { await chat.endQuickAnswers() } }
        let waiter = ReplyWaiter(storedID: chat.storedID)
        if let problem = await chat.send(q, voice: VoiceTurn()) { waiter.stop(); return problem }
        if let reply = await waiter.wait(seconds: waitLimit, chat: chat) {
            let spoken = SpokenText.forSpeech(reply)
            if spoken.isEmpty { return "The bot answered; the answer is in the chat." }
            return spoken.count > answerLimit ? String(spoken.prefix(answerLimit - 1)) + "…" : spoken
        }
        return "I'm on it. I'll let you know when it's done; the answer will be in the Siri chat."
    }

    /// The one chat Siri talks in with a bot, reopened each time; a new one when it is gone.
    /// The default bot keeps the "Siri" chat from before; each other bot has its own.
    private static func siriChat(on rt: GatewayRuntime, bot: BotEntity?) async -> ChatSession? {
        let profile = SiriCatalog.profile(for: bot, on: rt)
        let key = bot == nil ? chatKey : chatKey + "." + (bot?.id ?? "")
        if let id = UserDefaults.standard.string(forKey: key), !id.isEmpty,
           let chat = try? await rt.openChat(storedID: id, title: chatTitle, profile: profile, waitForResume: true), chat.resumeError == nil {
            return chat
        }
        if let p = profile, rt.selectedProfile != p { rt.selectedProfile = p }
        guard let chat = try? await rt.newChat() else { return nil }
        if !chat.storedID.isEmpty { UserDefaults.standard.set(chat.storedID, forKey: key) }
        await chat.rename(chatTitle)
        return chat
    }

    /// Waits for the chat's next finished reply, or for its turn to end without one.
    @MainActor
    final class ReplyWaiter {
        private var reply: String?
        private var observer: Any?
        private let storedID: String

        init(storedID: String) {
            self.storedID = storedID
            observer = NotificationCenter.default.addObserver(forName: .hermesReplyCompleted, object: nil, queue: .main) { [weak self] n in
                guard let id = n.userInfo?["storedID"] as? String, let text = n.userInfo?["text"] as? String else { return }
                Task { @MainActor in
                    guard let self, id == self.storedID else { return }
                    self.reply = text
                }
            }
        }

        func stop() {
            if let o = observer { NotificationCenter.default.removeObserver(o); observer = nil }
        }

        func wait(seconds: TimeInterval, chat: ChatSession) async -> String? {
            defer { stop() }
            let deadline = Date().addingTimeInterval(seconds)
            var sawRunning = false
            while Date() < deadline {
                if let reply { return reply }
                if chat.isRunning { sawRunning = true } else if sawRunning { return reply ?? lastReply(in: chat) }
                try? await Task.sleep(for: .milliseconds(200))
            }
            return reply
        }

        private func lastReply(in chat: ChatSession) -> String? {
            for item in chat.items.reversed() {
                if case .assistant(let text, _, let streaming) = item.kind, !streaming, !text.trimmingCharacters(in: .whitespaces).isEmpty { return text }
            }
            return nil
        }
    }
}
