import Foundation
import SwiftUI
import Testing
@testable import Vory
@testable import VoryCore

/// #573's other sides: the demo keeps its looks in memory and leaves none under its gateway, a push draws with its own
/// gateway's looks, and a copy of the looks written before they were per gateway still reads.
@MainActor
@Suite(.serialized)
struct BotLooksGatewaySideTests {
    private let a = UUID(uuidString: "00000000-0000-4000-8000-0000000573A1")!
    private let b = UUID(uuidString: "00000000-0000-4000-8000-0000000573B2")!
    private let bot = "default"
    /// Two palette colours, neither the bot's own default (#FF375F for "default"), as the app writes them.
    private var red: String { Color(hex: "#BF5AF2")!.hexString }
    private var green: String { Color(hex: "#30D158")!.hexString }

    private func keepingStoredLooks(_ body: () -> Void) {
        let d = UserDefaults.standard
        let keys = [BotColors.storageKey, BotAvatarStore.storageKey, BotNames.storageKey]
        let before = keys.map { d.string(forKey: $0) }
        let gateway = BotLookGateway.current
        defer {
            for (k, v) in zip(keys, before) { if let v { d.set(v, forKey: k) } else { d.removeObject(forKey: k) } }
            DemoLooks.set(on: false)
            BotLookGateway.current = gateway
            BotLooksMirror.mirror()
        }
        for k in keys { d.removeObject(forKey: k) }
        body()
    }

    /// The look editor's colour row (`set(hex:for:)`): the gateway in use's own.
    @Test func aColourPickedInTheEditorStaysOnItsGateway() {
        keepingStoredLooks {
            BotLookGateway.current = a
            BotColors.set(hex: red, for: bot)
            #expect(BotColors.hex(for: bot) == red)
            BotLookGateway.current = b
            #expect(BotColors.hex(for: bot) == BotPalette.defaultHex(for: bot), "gateway B's bot took the colour picked on gateway A's")
        }
    }

    /// The look editor's "Reset to default" (`reset(for:)`): this gateway's bot goes back to the palette's colour, and the
    /// colour from before, which other gateways show, is left as it was.
    @Test func resetOnOneGatewayLeavesTheLookFromBeforeAlone() {
        keepingStoredLooks {
            UserDefaults.standard.set(#"{"\#(bot)":"\#(green)"}"#, forKey: BotColors.storageKey)
            BotLookGateway.current = a
            BotColors.set(hex: red, for: bot)
            BotColors.reset(for: bot)
            #expect(BotColors.hex(for: bot) == BotPalette.defaultHex(for: bot), "reset on A didn't bring back the default")
            #expect(BotColors.stored()[bot] == green, "reset on A changed the colour from before")
            BotLookGateway.current = b
            #expect(BotColors.hex(for: bot) == green, "reset on A moved gateway B's look from before")
        }
    }

    /// The new-bot sheet's colour, picked under the draft name: the new bot's own on the gateway in use.
    @Test func aNewBotsDraftColourBecomesItsOwn() {
        keepingStoredLooks {
            BotLookGateway.current = a
            BotColors.set(hex: red, for: "new-bot")
            BotColors.moveDraft(from: "new-bot", to: "scribe")
            #expect(BotColors.hex(for: "scribe") == red)
            #expect(BotColors.stored().keys.allSatisfy { !$0.contains("new-bot") }, "the draft's colour was left behind")
            BotLookGateway.current = b
            #expect(BotColors.hex(for: "scribe") == BotPalette.defaultHex(for: "scribe"))
        }
    }

    /// The demo (#573 (c)): the editor's colour and its reset stay in memory, never under the demo's gateway.
    @Test func theEditorsColourInTheDemoIsKeptNowhere() {
        keepingStoredLooks {
            DemoLooks.set(on: true)
            BotLookGateway.current = GatewayConnection.demoID
            BotColors.set(hex: red, for: bot)
            BotColors.reset(for: bot)
            let demo = GatewayConnection.demoID.uuidString
            #expect(!(UserDefaults.standard.string(forKey: BotColors.storageKey) ?? "").contains(demo), "the demo's colour was kept under its gateway")
        }
    }

    /// The keychain copy's size on a few-gateway setup: three gateways' bots with looks and photos of their own, and the
    /// looks from before, each set beside the top level. Printed for a read, not held to a limit.
    @Test func theCopysSizeOnAFewGateways() throws {
        let c = UUID(uuidString: "00000000-0000-4000-8000-0000000573C3")!
        let names = (1...4).map { "size-check-\($0)" }
        let photo = Self.noisyJPEG()
        var keys: [String] = []
        keepingStoredLooks {
            defer {
                for k in keys { if let url = BotAvatarStore.photoURL(forKey: k) { try? FileManager.default.removeItem(at: url) } }
            }
            // The looks from before (by name alone), then each gateway's own.
            for gateway in [nil, a, b, c] as [UUID?] {
                BotLookGateway.current = gateway
                for n in names {
                    BotColors.set(hex: red, for: n)
                    BotAvatarStore.set(.photo, for: n)
                    try? BotAvatarStore.savePhoto(photo, for: n)
                    keys.append(BotLookGateway.key(n))
                }
            }
            BotLookGateway.current = a
            let copy = BotLooksMirror.build()
            let all = (try? JSONEncoder().encode(copy))?.count ?? 0
            let top = (try? JSONEncoder().encode(BotLooks(colors: copy.colors, avatars: copy.avatars, photos: copy.photos)))?.count ?? 0
            let photos = copy.photos.count + (copy.gateways?.values.map(\.photos.count).reduce(0, +) ?? 0) + (copy.shared?.photos.count ?? 0)
            print("BOTLOOKS-COPY-SIZE: \(all) bytes with \(copy.gateways?.count ?? 0) gateways and the looks from before, \(photos) photos; the top level alone \(top) bytes")
            #expect(copy.gateways?.count == 3 && copy.shared?.photos.count == names.count)
        }
    }

    /// A 320 px JPEG of coloured noise, nearer a photo's size than a flat colour's.
    private static func noisyJPEG() -> Data {
        var seed: UInt32 = 573
        func next() -> CGFloat { seed = seed &* 1_664_525 &+ 1_013_904_223; return CGFloat(seed >> 24) / 255 }
        let image = UIGraphicsImageRenderer(size: CGSize(width: 320, height: 320)).image { ctx in
            for y in stride(from: 0, to: 320, by: 4) {
                for x in stride(from: 0, to: 320, by: 4) {
                    ctx.cgContext.setFillColor(CGColor(red: next(), green: next(), blue: next(), alpha: 1))
                    ctx.cgContext.fill(CGRect(x: x, y: y, width: 4, height: 4))
                }
            }
        }
        return image.jpegData(compressionQuality: 0.85) ?? Data()
    }

    @Test func theDemoLeavesNoLookUnderItsGateway() {
        let d = UserDefaults.standard
        let keys = [BotColors.storageKey, BotAvatarStore.storageKey, BotNames.storageKey]
        let before = keys.map { d.string(forKey: $0) }
        let gateway = BotLookGateway.current
        defer {
            for (k, v) in zip(keys, before) { if let v { d.set(v, forKey: k) } else { d.removeObject(forKey: k) } }
            DemoLooks.set(on: false)
            BotLookGateway.current = gateway
            BotLooksMirror.mirror()
        }
        DemoLooks.set(on: true)
        BotLookGateway.current = GatewayConnection.demoID
        BotColors.set(Color(hex: "#BF5AF2")!, for: "default")
        BotAvatarStore.set(.studio(shape: "cloud", eyes: "classic"), for: "default")
        BotNames.set(displayName: "Sprout", title: nil, for: "default")
        let demo = GatewayConnection.demoID.uuidString
        for k in keys { #expect(!(d.string(forKey: k) ?? "").contains(demo), "\(k) keeps a look under the demo's gateway") }
    }

    @Test func aPushDrawsWithItsOwnGatewaysLooks() {
        let a = BotLooks.Gateway(colors: ["default": "#AA0000"]), shared = BotLooks.Gateway(colors: ["default": "#00BB00"])
        let looks = BotLooks(colors: ["default": "#0000CC"], gateways: ["A": a], shared: shared)
        #expect(looks.forGateway("A").colors["default"] == "#AA0000")
        // A gateway with no looks of its own here: the ones from before.
        #expect(looks.forGateway("B").colors["default"] == "#00BB00")
        // A push that names no gateway: the gateway in use's, as before.
        #expect(looks.forGateway(nil).colors["default"] == "#0000CC")
        // A copy made before looks were per gateway: the same.
        #expect(BotLooks(colors: ["default": "#0000CC"]).forGateway("A").colors["default"] == "#0000CC")
    }

    @Test func aCopyFromBeforeStillReads() throws {
        let old = Data(##"{"colors":{"default":"#0000CC"},"avatars":{"default":"initial"},"photos":{}}"##.utf8)
        let looks = try JSONDecoder().decode(BotLooks.self, from: old)
        #expect(looks.colors == ["default": "#0000CC"] && looks.gateways == nil && looks.shared == nil)
    }
}
