import ActivityKit
import Foundation
import UIKit
import VoryCore

/// ActivityKit's `Activity` is not marked Sendable; Apple documents it as safe to drive from any context.
private final class ActivityHandle: @unchecked Sendable {
    let activity: Activity<HermesTurnAttributes>
    init(_ a: Activity<HermesTurnAttributes>) { activity = a }

    func update(_ state: HermesTurnAttributes.ContentState) {
        Task.detached { await self.activity.update(.init(state: state, staleDate: Date().addingTimeInterval(3600))) }
    }

    /// An update that also alerts: the Island expands and the phone buzzes, like a push with an
    /// alert would. Used when the app itself has the news while it is not in front.
    func alert(_ state: HermesTurnAttributes.ContentState, title: String, body: String) {
        let config = AlertConfiguration(title: LocalizedStringResource(String.LocalizationValue(title)),
                                        body: LocalizedStringResource(String.LocalizationValue(body)), sound: .default)
        Task.detached { await self.activity.update(.init(state: state, staleDate: Date().addingTimeInterval(3600)), alertConfiguration: config) }
    }

    /// In front of the user the result is on screen already, so the activity goes at once; away
    /// from the app the finished card lingers for `linger` seconds (the reply arrives as a
    /// notification meanwhile), then the system removes it.
    func end(_ state: HermesTurnAttributes.ContentState, linger: TimeInterval? = nil) {
        let policy: ActivityUIDismissalPolicy = linger.map { .after(Date().addingTimeInterval($0)) } ?? .immediate
        Task.detached { await self.activity.end(.init(state: state, staleDate: nil), dismissalPolicy: policy) }
    }

    func observeState() -> Task<Void, Never> {
        Task.detached {
            for await st in self.activity.activityStateUpdates { LiveActivityController.note("state → \(st)") }
        }
    }

    func observePushTokens(storedID: String, startedAt: Date) -> Task<Void, Never> {
        Task.detached {
            for await token in self.activity.pushTokenUpdates {
                let hex = token.map { String(format: "%02x", $0) }.joined()
                LiveActivityController.note("push token received")
                NotificationCenter.default.post(name: .hermesLiveActivityToken, object: nil,
                                                userInfo: ["token": hex, "storedID": storedID, "startedAt": startedAt.timeIntervalSince1970])
            }
        }
    }
}

/// Starts/updates/ends the Live Activity for one chat's running turn.
@MainActor
final class LiveActivityController: TurnActivityReporting {
    private var handle: ActivityHandle?
    private var tokenTask: Task<Void, Never>?
    private var startedAt = Date()

    static var isEnabled: Bool { UserDefaults.standard.object(forKey: "liveActivitiesEnabled") as? Bool ?? true }
    /// Activities being ended right now: `Activity.activities` still lists them for a moment, and a
    /// new turn must not adopt one instead of starting its own.
    nonisolated(unsafe) static var endingIDs: Set<String> = []
    /// The last reason `Activity.request` refused, for the diagnostics page.
    static var lastStartError: String?
    static var lastStartedAt: Date?
    /// After the turn ends (app not in front): the card stays in the Dynamic Island this long (an
    /// ended activity leaves the Island at once, so it stays active meanwhile)…
    nonisolated static let finishedIsland: TimeInterval = 30
    /// …then it is ended and lingers on the Lock Screen this much longer.
    nonisolated static let finishedLinger: TimeInterval = 60
    /// The last dozen things that happened to activities, newest last, for the diagnostics page.
    /// Written from the main thread and from the detached token/state observers at once: the
    /// lock is what keeps two appends from corrupting the array (a malloc abort on 1.1 (6), right
    /// after a second chat started its activity while the first was running).
    private nonisolated static let logLock = NSLock()
    nonisolated(unsafe) private static var logStorage: [String] = []
    nonisolated static var log: [String] { logLock.lock(); defer { logLock.unlock() }; return logStorage }
    nonisolated static func note(_ what: String) {
        let stamp = Date().formatted(.dateTime.hour().minute().second())
        logLock.lock(); defer { logLock.unlock() }
        logStorage.append("\(stamp) \(what)")
        if logStorage.count > 12 { logStorage.removeFirst(logStorage.count - 12) }
    }
    private var stateTask: Task<Void, Never>?

    // MARK: Push to start

    /// Tokens the gateway can use to START an activity while the app is closed (iOS 17.2+). The
    /// system hands one out per attributes type; it goes into the device file like the others.
    nonisolated(unsafe) private static var pushToStartTask: Task<Void, Never>?
    nonisolated(unsafe) private static var startedByPushTask: Task<Void, Never>?
    nonisolated(unsafe) private static var adoptedTokenTasks: [String: Task<Void, Never>] = [:]

    /// Called once at launch. Publishes the push-to-start token, and for every activity the
    /// system starts on a push, publishes that activity's own update token under its session so
    /// the companion can keep driving it and end it.
    static func observePushStarts() {
        guard pushToStartTask == nil else { return }
        pushToStartTask = Task.detached {
            for await token in Activity<HermesTurnAttributes>.pushToStartTokenUpdates {
                let hex = token.map { String(format: "%02x", $0) }.joined()
                note("push-to-start token received")
                NotificationCenter.default.post(name: .hermesLiveActivityPushToStartToken, object: nil, userInfo: ["token": hex])
            }
        }
        startedByPushTask = Task.detached {
            for await a in Activity<HermesTurnAttributes>.activityUpdates {
                Self.adopt(a, why: "push start")
                // The system launched the app in the background for this one: nothing else opens
                // the gateway connection, and until it is open the token stays on the phone, the
                // companion never learns it, and the card sits in the Dynamic Island "Thinking…"
                // long after the turn ended.
                await Self.connectToPublishTokens()
            }
        }
        // After a relaunch the system may still show activities this process knows nothing about:
        // their tokens must reach the gateway again, or the companion cannot end them.
        for a in Activity<HermesTurnAttributes>.activities where a.activityState == .active && a.content.state.endedAt == nil {
            Self.adopt(a, why: "showing at launch")
        }
    }

    /// Observes one activity's token and publishes the token it already holds (`pushTokenUpdates`
    /// only reports changes). Once per activity.
    nonisolated private static func adopt(_ a: Activity<HermesTurnAttributes>, why: String) {
        let id = a.id
        guard adoptedTokenTasks[id] == nil else { return }
        note("activity \(id.prefix(6)) appeared (\(why))")
        let h = ActivityHandle(a)
        adoptedTokenTasks[id] = h.observePushTokens(storedID: a.attributes.storedSessionID, startedAt: a.content.state.startedAt)
        if let token = a.pushToken {
            let hex = token.map { String(format: "%02x", $0) }.joined()
            NotificationCenter.default.post(name: .hermesLiveActivityToken, object: nil,
                                            userInfo: ["token": hex, "storedID": a.attributes.storedSessionID, "startedAt": a.content.state.startedAt.timeIntervalSince1970])
        }
    }

    /// Background launch for a push-started activity: open the saved gateway connection so the
    /// device file (with the new token) is published before the system suspends the app. The
    /// runtime's start returns once that publish has run. In the foreground the runtime is
    /// already there and the registration sync publishes it on its own.
    @MainActor private static func connectToPublishTokens() async {
        let model = AppModel.shared
        guard model.runtime == nil else { return }
        note("connecting to publish the token (launched in the background)")
        let task = UIApplication.shared.beginBackgroundTask(withName: "vory.live-activity.token") {}
        await model.activateSavedConnection()
        UIApplication.shared.endBackgroundTask(task)
    }

    /// Ends activities nobody is driving any more: ones whose turn already ended, or that belong to
    /// a chat this app has open and knows is idle. Called when the app comes to the foreground.
    static func endOrphans(runningStoredIDs: Set<String>, knownStoredIDs: Set<String>) {
        for a in Activity<HermesTurnAttributes>.activities {
            let sid = a.attributes.storedSessionID
            let finished = a.content.state.endedAt != nil
            let idleHere = knownStoredIDs.contains(sid) && !runningStoredIDs.contains(sid)
            let ancient = Date().timeIntervalSince(a.content.state.startedAt) > 3 * 3600
            guard finished || idleHere || ancient else { continue }
            let h = ActivityHandle(a)
            var st = a.content.state
            st.endedAtUnix = st.endedAtUnix ?? Date().timeIntervalSince1970
            h.end(st)
            // Its push token dies with it; the gateway must not keep aiming at a dead activity.
            NotificationCenter.default.post(name: .hermesLiveActivityToken, object: nil, userInfo: ["token": "", "storedID": sid, "startedAt": 0.0])
        }
    }

    func start(for chat: ChatSession) {
        guard Self.isEnabled, handle == nil else { return }
        guard ActivityAuthorizationInfo().areActivitiesEnabled else { Self.lastStartError = "Live Activities are turned off for Vory in iOS Settings"; return }
        // After a relaunch the system may still show this chat's activity: adopt it instead of stacking a second one.
        if let existing = Activity<HermesTurnAttributes>.activities.first(where: {
            $0.attributes.storedSessionID == chat.storedID && $0.content.state.endedAt == nil && $0.activityState == .active && !Self.endingIDs.contains($0.id)
        }) {
            startedAt = existing.content.state.startedAt
            let h = ActivityHandle(existing)
            handle = h
            tokenTask = h.observePushTokens(storedID: chat.storedID, startedAt: startedAt)
            // `pushTokenUpdates` only reports changes; the token this activity already holds must
            // reach the gateway too, or the companion cannot end it.
            if let token = existing.pushToken {
                let hex = token.map { String(format: "%02x", $0) }.joined()
                NotificationCenter.default.post(name: .hermesLiveActivityToken, object: nil,
                                                userInfo: ["token": hex, "storedID": chat.storedID, "startedAt": startedAt.timeIntervalSince1970])
            }
            return
        }
        // A finished card from the previous turn that the app has not been opened to clear yet must
        // not sit next to the new one.
        for a in Activity<HermesTurnAttributes>.activities where a.attributes.storedSessionID == chat.storedID && a.content.state.endedAt != nil {
            Self.endingIDs.insert(a.id)
            ActivityHandle(a).end(a.content.state)
        }
        startedAt = Date()
        let shortModel = chat.modelName.split(separator: "/").last.map(String.init) ?? chat.modelName
        let botName = chat.runtime.profiles.first { $0.name == chat.profileName }?.label ?? chat.profileName
        let attributes = HermesTurnAttributes(sessionTitle: chat.title, storedSessionID: chat.storedID,
                                              connectionID: chat.runtime.connection.id.uuidString, profile: chat.profileName,
                                              model: shortModel, tintHex: BotColors.hex(for: chat.profileName), botName: botName,
                                              avatar: BotAvatarStore.choice(for: chat.profileName).raw)
        let state = HermesTurnAttributes.ContentState(phase: "thinking", detail: "Thinking…", outputTokens: chat.usage?.output ?? 0,
                                                       contextPercent: chat.usage?.contextPercent, needsAttention: false, startedAt: startedAt,
                                                       contextUsed: chat.usage?.contextUsed, contextMax: chat.usage?.contextMax)
        do {
            let a = try Activity.request(attributes: attributes, content: .init(state: state, staleDate: Date().addingTimeInterval(3600)), pushType: .token)
            let h = ActivityHandle(a)
            handle = h
            tokenTask = h.observePushTokens(storedID: chat.storedID, startedAt: startedAt)
            stateTask = h.observeState()
            Self.lastStartError = nil; Self.lastStartedAt = Date()
            Self.note("started for “\(chat.title.prefix(24))” (session \(chat.storedID.prefix(12)))")
        } catch {
            handle = nil
            Self.lastStartError = error.localizedDescription
            Self.note("start refused: \(error.localizedDescription)")
        }
    }

    private var alertedAttention = false

    func update(for chat: ChatSession, attention: Bool, detail: String?) {
        guard let handle else { return }
        let card = chat.firstCard
        let inputKind = attention && card != nil && card?.method != "approval"
        let text = detail ?? (attention ? (card?.method == "sudo" ? "sudo password needed" : (card?.approval?.description ?? (inputKind ? "Your input is needed" : "Needs your answer"))) : (chat.statusLine ?? "Thinking…"))
        // brain while it reasons, speech bubble while it writes, wrench while a tool runs
        let phase = attention ? "waiting"
            : (detail ?? chat.statusLine ?? "").hasPrefix("Running") || (chat.statusLine ?? "").hasPrefix("Preparing") ? "tool"
            : (chat.statusLine ?? "Thinking…").hasPrefix("Thinking") || (chat.statusLine ?? "").hasPrefix("Sending") || (chat.statusLine ?? "").hasPrefix("Queued") ? "thinking"
            : "streaming"
        var state = HermesTurnAttributes.ContentState(phase: phase, detail: text, outputTokens: chat.usage?.output ?? 0,
                                                       contextPercent: chat.usage?.contextPercent, needsAttention: attention, startedAt: startedAt,
                                                       contextUsed: chat.usage?.contextUsed, contextMax: chat.usage?.contextMax)
        state.attentionKind = attention ? (inputKind ? "input" : "approval") : nil
        // Away from the app the alert (the Island expanding, the buzz) comes from the
        // companion's push when one is installed; only without it does the app raise its own.
        if attention, !alertedAttention, UIApplication.shared.applicationState != .active, !LocalNotifier.companionDelivers {
            alertedAttention = true
            let botName = handle.activity.attributes.botName ?? chat.profileName
            handle.alert(state, title: botName, body: inputKind ? "Your input is needed — tap to answer. It waits for you." : "Approval needed — tap to answer. It waits for you.")
            Self.note("approval alert from the app (background)")
            return
        }
        if !attention { alertedAttention = false }
        handle.update(state)
    }

    func end(for chat: ChatSession, phase: String) {
        BotAmbient.shared.turnFinished(profile: chat.profileName)
        tokenTask?.cancel()
        tokenTask = nil
        stateTask?.cancel()
        stateTask = nil
        let inFront = UIApplication.shared.applicationState == .active
        let state = HermesTurnAttributes.ContentState(phase: phase, detail: phase == "error" ? "The turn failed" : "Turn finished",
                                                      outputTokens: chat.usage?.output ?? 0, contextPercent: chat.usage?.contextPercent, needsAttention: false,
                                                      startedAt: startedAt, endedAt: Date(), contextUsed: chat.usage?.contextUsed, contextMax: chat.usage?.contextMax)
        var keepToken = false
        var finishing: String?
        if let handle {
            Self.endingIDs.insert(handle.activity.id); self.handle = nil
            if inFront {
                handle.end(state)
                Self.note("end (\(phase)) now, app in front")
            } else {
                // Away from the app the card switches to "Finished" without expanding the Island and
                // stays there half a minute, then lingers on the Lock Screen; the reply itself arrives
                // as a notification (the companion's, or the local one when none is registered), which
                // is where the buzz and the Reply action live.
                handle.update(state)
                finishing = handle.activity.id
                Task.detached {
                    try? await Task.sleep(for: .seconds(Self.finishedIsland))
                    handle.end(state, linger: Self.finishedLinger)
                }
                // The app may be suspended before that timer fires; the companion's own end push
                // reaches this same activity as long as its token stays registered.
                keepToken = LocalNotifier.companionDelivers
                Self.note("finished (\(phase)) in the background: Island \(Int(Self.finishedIsland)) s, Lock Screen \(Int(Self.finishedLinger)) s more")
            }
        }
        // The companion routes finish/approval alerts through an active activity; tell it there is none
        // now — unless that activity is still finishing and the companion's end push should reach it.
        if !keepToken {
            NotificationCenter.default.post(name: .hermesLiveActivityToken, object: nil, userInfo: ["token": "", "storedID": chat.storedID, "startedAt": 0.0])
        }
        // Whatever else the system still shows for this chat (an activity from before a relaunch, or one
        // whose end push never arrived) goes with it.
        for a in Activity<HermesTurnAttributes>.activities where a.attributes.storedSessionID == chat.storedID && a.id != finishing {
            Self.endingIDs.insert(a.id)
            ActivityHandle(a).end(state, linger: inFront ? nil : Self.finishedLinger)
        }
    }
}

extension Notification.Name {
    static let hermesLiveActivityToken = Notification.Name("hermesLiveActivityToken")
}
