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

    static var parameterSummary: some ParameterSummary { Summary("Ask \(\.$question)") }

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let answer = await SiriAsk.ask(question)
        return .result(dialog: IntentDialog(stringLiteral: answer))
    }
}

/// Opens the app on a new chat with the default bot and starts hands-free on it (the Action
/// Button's natural job).
struct StartVoiceModeIntent: AppIntent {
    static let title: LocalizedStringResource = "Start Voice Mode"
    static let description = IntentDescription("Opens Vory and starts a voice conversation with your bot.")
    static let openAppWhenRun = true

    @MainActor
    func perform() async throws -> some IntentResult {
        #if os(macOS)
        // The app may be running with its window closed (the menu bar keeps it alive): the
        // window comes back first, or the new chat the request opens has no list to open in.
        MacWindow.bringMainForward()
        #endif
        AppModel.shared.requestVoiceMode()
        return .result()
    }
}

struct VoryShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(intent: AskVoryIntent(),
                    phrases: ["Ask \(.applicationName)", "Ask \(.applicationName) a question", "Ask \(.applicationName) something"],
                    shortTitle: "Ask Vory", systemImageName: "bubble.left.and.text.bubble.right")
        AppShortcut(intent: StartVoiceModeIntent(),
                    phrases: ["Start voice mode in \(.applicationName)", "Talk to \(.applicationName)", "\(.applicationName) voice mode"],
                    shortTitle: "Voice Mode", systemImageName: "waveform.badge.mic")
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

    static func ask(_ question: String) async -> String {
        let q = question.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return "I didn't catch a question." }
        let model = AppModel.shared
        guard model.hasConnections else { return "Set up a gateway in Vory first." }
        #if os(iOS)
        let assertion = UIApplication.shared.beginBackgroundTask(withName: "vory.siri.ask")
        defer { if assertion != .invalid { UIApplication.shared.endBackgroundTask(assertion) } }
        #endif
        if model.runtime == nil { await model.activateSavedConnection() }
        guard let rt = model.runtime else { return "Vory could not reach your gateway." }
        let deadline = Date().addingTimeInterval(10)
        while !rt.socketState.isOpen, Date() < deadline { try? await Task.sleep(for: .milliseconds(250)) }
        guard rt.socketState.isOpen else { return "Your gateway isn't answering right now." }
        guard let chat = await siriChat(on: rt) else { return "Vory could not open a chat on your gateway." }
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

    /// The one chat Siri talks in, reopened each time; a new one when it is gone.
    private static func siriChat(on rt: GatewayRuntime) async -> ChatSession? {
        let profile = rt.defaultProfile ?? rt.selectedProfile
        if let id = UserDefaults.standard.string(forKey: chatKey), !id.isEmpty,
           let chat = try? await rt.openChat(storedID: id, title: chatTitle, profile: profile, waitForResume: true), chat.resumeError == nil {
            return chat
        }
        guard let chat = try? await rt.newChat() else { return nil }
        if !chat.storedID.isEmpty { UserDefaults.standard.set(chat.storedID, forKey: chatKey) }
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
