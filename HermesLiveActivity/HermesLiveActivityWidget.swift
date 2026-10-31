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
        ActivityConfiguration(for: HermesTurnAttributes.self) { context in
            LockScreenTurnView(attributes: context.attributes, state: context.state)
                .widgetURL(context.attributes.chatURL)
                // Translucent over the wallpaper rather than a flat black slab; the system
                // still guarantees legibility with its own material underneath.
                .activityBackgroundTint(Color.black.opacity(0.35))
                .activitySystemActionForegroundColor(.white)
        } dynamicIsland: { context in
            // No centre region: the leading and trailing regions sit beside the sensor cut-out and
            // a third column there only leaves the title a few letters. Everything wide goes below.
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    IslandExpandedLeading(attributes: context.attributes, state: context.state)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    IslandExpandedTrailing(attributes: context.attributes, state: context.state)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    IslandExpandedBottom(attributes: context.attributes, state: context.state)
                        .widgetURL(context.attributes.chatURL)
                }
            } compactLeading: {
                // The island on iPhone 18 Pro is smaller and holds three activities at once, so
                // the compact view is the bot alone with its phase in a corner badge: one glyph
                // per side, nothing that needs width.
                IslandBot(attributes: context.attributes, state: context.state, size: 24)
                    .padding(.leading, 2)
                    .widgetURL(context.attributes.chatURL)
            } compactTrailing: {
                IslandCompactTrailing(state: context.state)
            } minimal: {
                // Minimal is what each activity gets when several share the island: the bot's
                // face, ringed yellow when it needs you, so three bots read as three bots.
                IslandBot(attributes: context.attributes, state: context.state, size: 22)
                    .widgetURL(context.attributes.chatURL)
            }
            .keylineTint(context.state.needsAttention ? .yellow : PhaseStyle.tint(context.state.phase, bot: context.attributes.tintHex))
        }
    }
}
