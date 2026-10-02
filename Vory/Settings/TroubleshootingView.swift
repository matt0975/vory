import SwiftUI

/// What to check when connecting, signing in, the Companion or notifications go wrong. Plain
/// lists, one section per symptom, written for someone standing at a gateway they run themselves.
struct TroubleshootingView: View {
    private struct Topic: Identifiable {
        let id: String
        let title: String
        let symbol: String
        let checks: [String]
    }

    private let topics: [Topic] = [
        Topic(id: "connect", title: "The connection test stops", symbol: "wifi.exclamationmark", checks: [
            "Open the same URL in Safari on \(DeviceWords.this). If the Hermes dashboard does not load there, the \(DeviceWords.kind) cannot reach the gateway and the app cannot either.",
            "Use the dashboard's address (hermes serve, port 9119 unless you changed it), not a chat web UI or an SSH app.",
            "At home or on a tailnet the address is plain http. Type http:// yourself if the form guessed https, or https:// if you put a certificate in front.",
            "Tailscale: the Tailscale app on \(DeviceWords.this) must be connected, and the gateway machine must be on the same tailnet.",
            "Behind a reverse proxy: put the proxy's path in Path prefix (for example /hermes), and make sure the proxy passes WebSocket upgrades through.",
            "Cloudflare Access: always https, with a service token. A browser login for Access cannot be used by the app.",
        ]),
        Topic(id: "signin", title: "Sign-in fails", symbol: "person.badge.key", checks: [
            "Sign in with browser needs a Hermes with native sign-in. If the app says the gateway lacks it, update Hermes on the gateway, or use a session token from the dashboard instead.",
            "Nginx Proxy Manager with Block Common Exploits on used to reject the sign-in request; the app now encodes it fully. If a proxy still answers 403, check its rules for the /api path.",
            "The browser closed without handing the app its code: the gateway's callback must reach \(DeviceWords.this). A dashboard that only listens on the gateway machine cannot call back over the internet.",
            "Username and password only works on a gateway that offers password sign-in. A browser-only gateway says so in the test; use the browser there.",
            "Session token: copy HERMES_DASHBOARD_SESSION_TOKEN from the gateway's environment. It is refused when the gateway has its auth gate on.",
        ]),
        Topic(id: "companion", title: "The Companion will not install or restart", symbol: "puzzlepiece.extension", checks: [
            "Install writes files through the dashboard's file API. If it fails, the signed-in account needs permission to write under the profile's home.",
            "Restart reports through the dashboard that is restarting, so its status often never comes back. The app watches for the Companion's first heartbeat instead; give it two minutes.",
            "If the restart says the session expired, the app renews it once and tries again. If it still fails, sign in again from the card; if Settings › Companion already shows it running, the restart happened.",
            "After a restart, the gateway must be able to start the plugin: run hermes serve by hand once and read its output if the Companion never reports in.",
            "Update the Companion from Settings › Software Update whenever a build asks for it; old versions miss newer features.",
        ]),
        Topic(id: "push", title: DeviceWords.isMac ? "No notifications" : "No notifications or Live Activity", symbol: "bell.slash", checks: [
            "Settings › Companion › This device must show the relay registered and the device file published. Register again if either is missing.",
            "\(DeviceWords.settings) › Notifications › Vory must allow alerts\(DeviceWords.kind == "phone" ? ", and Live Activities must be on" : "").",
            "The Companion sends only for chats it mirrors: it attaches to running sessions when they start, so a turn already running when it was installed will not report.",
            "Focus modes and Notification Summary hold alerts back; check the Focus that is on.",
            "One device, one registration: signing in on a second one does not stop the first.",
        ]),
        Topic(id: "approvals", title: "No approval cards", symbol: "checkmark.shield", checks: [
            "Settings › Companion › This device › Approval requests says whether the gateway agreed to send them and how many arrived. \"Not acknowledged\" means an older Hermes: update it on the gateway.",
            "Only actions the gateway's approval mode holds for a person reach \(DeviceWords.this). In a mode that approves low-risk commands on its own, most turns never ask.",
            "A card answered on another client (the dashboard, a terminal) disappears here too; the first answer wins.",
            DeviceWords.isMac ? "With Confirm from notifications on, an Approve from a notification opens the chat and asks once more for risky actions. Settings › Security changes that." : "With Confirm from the Lock Screen on, an Approve from the Live Activity opens the chat and asks once more for risky actions. Settings › Security changes that.",
        ]),
    ]

    var body: some View {
        SettingsList {
            SettingsHeaderSection(title: "Troubleshooting", symbol: "wrench.and.screwdriver", color: .orange, description: "What to check, symptom by symptom. Each item is something to look at on \(DeviceWords.this) or on the gateway machine.")
            ForEach(topics) { t in
                Section {
                    ForEach(Array(t.checks.enumerated()), id: \.offset) { i, c in
                        HStack(alignment: .firstTextBaseline, spacing: 10) {
                            Text("\(i + 1)").font(.footnote.weight(.semibold).monospacedDigit()).foregroundStyle(.secondary).frame(width: 16, alignment: .trailing)
                            Text(c).font(.subheadline)
                        }
                        .padding(.vertical, 2)
                    }
                } header: {
                    Label(t.title, systemImage: t.symbol)
                }
            }
            Section {
                Text("Still stuck? Take a screenshot in the app to send it through TestFlight, or write to matt@vory.dev with what the connection test showed.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
        }
        .untitledPage()
    }
}
