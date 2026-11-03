import Foundation
import SwiftUI
import Testing
@testable import Vory
@testable import VoryCore

/// #573: two gateways whose bots share a name (each gateway's own "default", say) keep their own looks. A colour, an
/// avatar or a name set on one gateway's bot never shows on the other's, and a look kept from before looks were per
/// gateway still shows where a gateway has none of its own. Each test puts the stored looks and the gateway in use back.
@MainActor
@Suite(.serialized)
struct BotLooksPerGatewayTests {
    private let a = UUID(uuidString: "00000000-0000-4000-8000-0000000573A1")!
    private let b = UUID(uuidString: "00000000-0000-4000-8000-0000000573B2")!
    private let bot = "default"

    /// Two palette colours, neither the bot's own default, as the app writes them.
    private var red: String { Color(hex: "#BF5AF2")!.hexString }
    private var green: String { Color(hex: "#30D158")!.hexString }

    private func keepingStoredLooks(_ body: () -> Void) {
        let d = UserDefaults.standard
        let keys = [BotColors.storageKey, BotAvatarStore.storageKey, BotNames.storageKey]
        let before = keys.map { d.string(forKey: $0) }
        let gateway = BotLookGateway.current
        defer {
            for (k, v) in zip(keys, before) { if let v { d.set(v, forKey: k) } else { d.removeObject(forKey: k) } }
            BotLookGateway.current = gateway
            BotLooksMirror.mirror()
        }
        for k in keys { d.removeObject(forKey: k) }
        body()
    }

    @Test func aColourSetOnOneGatewaysBotStaysOnThatGateway() {
        keepingStoredLooks {
            #expect(red != BotPalette.defaultHex(for: bot))
            BotLookGateway.current = a
            BotColors.set(Color(hex: red)!, for: bot)
            #expect(BotColors.hex(for: bot) == red)
            BotLookGateway.current = b
            #expect(BotColors.hex(for: bot) == BotPalette.defaultHex(for: bot), "gateway B's bot took the colour set on gateway A's")
            BotLookGateway.current = a
            #expect(BotColors.hex(for: bot) == red)
        }
    }

    @Test func anAvatarChosenOnOneGatewaysBotStaysOnThatGateway() {
        keepingStoredLooks {
            BotLookGateway.current = b
            let fresh = BotAvatarStore.choice(for: bot)
            let chosen = BotAvatarChoice.studio(shape: "cloud", eyes: "classic")
            #expect(chosen.raw != fresh.raw)
            BotLookGateway.current = a
            BotAvatarStore.set(chosen, for: bot)
            #expect(BotAvatarStore.choice(for: bot).raw != fresh.raw)
            BotLookGateway.current = b
            #expect(BotAvatarStore.choice(for: bot) == fresh, "gateway B's bot took the avatar chosen on gateway A's")
        }
    }

    @Test func aNameGivenOnOneGatewaysBotStaysOnThatGateway() {
        keepingStoredLooks {
            BotLookGateway.current = a
            BotNames.set(displayName: "Sprout", title: "Gardener", for: bot)
            #expect(BotNames.names(for: bot)?.displayName == "Sprout")
            BotLookGateway.current = b
            #expect(BotNames.names(for: bot) == nil, "gateway B's bot took the name given on gateway A's")
        }
    }

    @Test func aLookFromBeforeShowsWhereAGatewayHasNoneOfItsOwn() {
        keepingStoredLooks {
            // As 43 stored it: by the bot's name alone.
            UserDefaults.standard.set(#"{"\#(bot)":"\#(green)"}"#, forKey: BotColors.storageKey)
            BotLookGateway.current = b
            #expect(BotColors.hex(for: bot) == green)
            BotLookGateway.current = a
            BotColors.set(Color(hex: red)!, for: bot)
            #expect(BotColors.hex(for: bot) == red)
            BotLookGateway.current = b
            #expect(BotColors.hex(for: bot) == green, "a colour set on gateway A moved gateway B's look from before")
        }
    }
}
