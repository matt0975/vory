import SwiftUI
import WidgetKit

/// The desktop and Notification Center widgets: the same four as the iPhone's Home Screen ones,
/// drawn from the snapshot the app writes into the shared Keychain group.
@main
struct VoryMacWidgetsBundle: WidgetBundle {
    var body: some Widget {
        StatusWidget()
        AttentionWidget()
        ActivityWidget()
        OverviewWidget()
        ContextWidget()
    }
}
