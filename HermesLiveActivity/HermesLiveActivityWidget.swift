import ActivityKit
import SwiftUI
import WidgetKit

@main
struct HermesLiveActivityBundle: WidgetBundle {
    var body: some Widget {
        HermesTurnLiveActivity()
        StatusWidget()
        AttentionWidget()
        ActivityWidget()
        ContextWidget()
        OverviewWidget()
        BlocksWidget()
    }
}

extension HermesTurnAttributes {
    /// A tap anywhere on the activity opens this chat, on its bot.
    var chatURL: URL? {
        var c = URLComponents(); c.scheme = "vory"; c.host = "chat"; c.path = "/" + storedSessionID
        if !profile.isEmpty { c.queryItems = [URLQueryItem(name: "profile", value: profile)] }
        return c.url
    }
}

/// Lock Screen banner + Dynamic Island for a running agent turn.
struct HermesTurnLiveActivity: Widget {
    var body: some WidgetConfiguration {
        // Each view draws the activity with its sealed names and goal line opened (`unsealed`, #497): a relay-mode push
        // carries them sealed with this install's key. Where they can't be opened it shows "Chat" and the default look.
        ActivityConfiguration(for: HermesTurnAttributes.self) { context in
            let attributes = context.attributes.unsealed(), state = context.state.unsealed()
            LockScreenTurnView(attributes: attributes, state: state)
                .widgetURL(attributes.chatURL)
                // Translucent over the wallpaper rather than a flat black slab; the system
                // still guarantees legibility with its own material underneath.
                .activityBackgroundTint(Color.black.opacity(0.35))
                .activitySystemActionForegroundColor(.white)
        } dynamicIsland: { context in
            let attributes = context.attributes.unsealed(), state = context.state.unsealed()
            // No centre region: the leading and trailing regions sit beside the sensor cut-out and
            // a third column there only leaves the title a few letters. Everything wide goes below.
            return DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    IslandExpandedLeading(attributes: attributes, state: state)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    IslandExpandedTrailing(attributes: attributes, state: state)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    IslandExpandedBottom(attributes: attributes, state: state)
                        .widgetURL(attributes.chatURL)
                }
            } compactLeading: {
                // The island on iPhone 18 Pro is smaller and holds three activities at once, so
                // the compact view is the bot alone with its phase in a corner badge: one glyph
                // per side, nothing that needs width.
                IslandBot(attributes: attributes, state: state, size: 24)
                    .padding(.leading, 2)
                    .widgetURL(attributes.chatURL)
            } compactTrailing: {
                IslandCompactTrailing(state: state)
            } minimal: {
                // Minimal is what each activity gets when several share the island: the bot's
                // face, ringed yellow when it needs you, so three bots read as three bots.
                IslandBot(attributes: attributes, state: state, size: 22)
                    .widgetURL(attributes.chatURL)
            }
            .keylineTint(state.needsAttention ? .yellow : PhaseStyle.tint(state.phase, bot: attributes.tintHex))
        }
    }
}
