import SwiftUI

/// The small "Demo" tag by the gateway's name while the demo runs (#392).
struct DemoTag: View {
    var body: some View {
        Text("Demo")
            .font(.caption2.weight(.semibold))
            .padding(.horizontal, 6).padding(.vertical, 1)
            .background(Color.accentColor.opacity(0.18), in: .capsule)
            .foregroundStyle(Color.accentColor)
    }
}

/// What a page shows in the demo when it needs a gateway of one's own (#392): the Companion, push setup.
struct DemoNeedsGateway: View {
    let description: String
    var body: some View {
        ContentUnavailableView {
            Label("Connect your gateway", systemImage: "network")
        } description: {
            Text(description)
        }
    }

    /// Notifications in the demo (#501): its replies and approvals are notifications while the app is open or just put
    /// away; with the app closed they need the Companion on a gateway of one's own.
    static let notifications = "In the demo, Vory shows its replies and approvals as notifications while it's open or just put away. To get them with Vory closed, connect your own gateway with the Vory Companion in Settings › Gateway."
}
