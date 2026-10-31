import Foundation
import SwiftUI
import Testing
@testable import Vory
@testable import VoryCore

/// Demo mode's app side (#392): while the demo runs its bots wear its own looks, five bodies, five eyes, five colours,
/// whatever is stored; a look or colour picked in the demo stays in memory; none of it is ever written to the stored
/// looks (and so to iCloud or the extensions), and it all goes when the demo ends. Leaving the demo brings back the
/// saved gateway that was in use.
@MainActor
@Suite(.serialized) struct DemoLooksTests {
    @Test func theDemosBotsWearTheirOwnLooksAndNothingIsStored() {
        let avatarsBefore = UserDefaults.standard.string(forKey: BotAvatarStore.storageKey)
        let colorsBefore = UserDefaults.standard.string(forKey: BotColors.storageKey)
        defer { DemoLooks.set(on: false) }
        DemoLooks.set(on: true)
        // Five bots, five different bodies and colours, each from the app's own lists.
        #expect(Set(DemoBots.all.map(\.shape)).count == DemoBots.all.count)
        #expect(Set(DemoBots.all.map(\.hex)).count == DemoBots.all.count)
        for bot in DemoBots.all {
            #expect(BotLookSpec.shapes.contains(bot.shape) && BotLookSpec.eyeStyles.contains(bot.eyes), "\(bot.display): not in the app's lists")
            let spec = BotAvatarStore.choice(for: bot.name).spec(hex: BotColors.hex(for: bot.name))
            #expect(spec.shape == bot.shape && spec.eyes == bot.eyes && spec.hex == bot.hex, "\(bot.display) wears \(spec)")
            // A view's own copy of the stored looks doesn't hide the demo's.
            #expect(BotAvatarStore.choice(for: bot.name, overrides: ["default": "studio:cloud:tall"]).spec(hex: "").shape == bot.shape)
        }
        // A look and a colour picked during the demo: kept for it, not stored.
        BotAvatarStore.set(.studio(shape: "gem", eyes: "bold"), for: "default")
        BotColors.set(.red, for: "default")
        #expect(BotAvatarStore.choice(for: "default").spec(hex: "").shape == "gem")
        #expect(UserDefaults.standard.string(forKey: BotAvatarStore.storageKey) == avatarsBefore)
        #expect(UserDefaults.standard.string(forKey: BotColors.storageKey) == colorsBefore)
        // The demo ends: its looks go, and the stored ones are what they were.
        DemoLooks.set(on: false)
        #expect(BotAvatarStore.choice(for: "default").raw == BotAvatarStore.choice(for: "default", overrides: BotAvatarStore.stored()).raw)
        #expect(!DemoLooks.isOn)
    }

    /// The demo's folders are the usual ones ("default" among them): a name this person gave their own default bot
    /// doesn't show on the demo's, and a name given in the demo doesn't reach theirs.
    @Test func theDemosBotsKeepTheirOwnNames() {
        let d = UserDefaults(suiteName: "dev.vory.tests.demonames." + UUID().uuidString)!
        BotNames.set(displayName: "Ada", title: "My helper", for: "default", d)
        #expect(BotNames.names(for: "default", d)?.displayName == "Ada")
        defer { DemoLooks.set(on: false) }
        DemoLooks.set(on: true)
        // The demo's own name and title, as the tour shows them, never the person's own.
        #expect(BotNames.names(for: "default", d)?.displayName == "Sprout", "the person's own name shows on the demo's bot")
        #expect(BotNames.names(for: "default", d)?.title == "Research")
        BotNames.set(displayName: "Sprouty", title: nil, for: "default", d)
        #expect(BotNames.names(for: "default", d)?.displayName == "Sprouty")
        #expect(BotNames.stored(d)["default"]?["n"] == "Ada", "a name given in the demo reached the stored names")
        DemoLooks.set(on: false)
        #expect(BotNames.names(for: "default", d)?.displayName == "Ada")
    }

    @Test func leavingTheDemoBringsTheSavedGatewayBack() {
        let name = "dev.vory.tests.demoleave." + UUID().uuidString
        let home = GatewayConnection(name: "Home", gateway: try! GatewayURL.normalize("https://gateway.example.test"), authMode: .sessionToken)
        let store = ConnectionStore(defaults: UserDefaults(suiteName: name)!, connections: [home])
        #expect(store.active?.id == home.id)
        store.activeConnectionID = GatewayConnection.demoID
        #expect(store.active?.isDemo == true && store.active?.name == "Vory demo")
        store.leaveDemo()
        #expect(store.active?.id == home.id)
        #expect(store.demo == nil)
    }
}
