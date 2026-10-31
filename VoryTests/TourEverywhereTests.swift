#if os(iOS)
import Foundation
import Testing
@testable import Vory
@testable import VoryCore

/// Onboarding's beat 5 (#388, the order of 2026-10-20): the places in turn, each with its line, the iPad
/// without the Dynamic Island; and the Live Activity it shows, which is Sprout's ask from the demo and nothing else.
@MainActor
struct TourEverywhereTests {
    @Test func thePlacesComeInTheirOrder() {
        #expect(TourPlace.all(pad: false) == [.island, .lockScreen, .watch, .devices, .homeAway, .iCloud])
        // An iPad has no Dynamic Island.
        #expect(TourPlace.all(pad: true) == [.lockScreen, .watch, .devices, .homeAway, .iCloud])
        // About fifteen seconds left to run.
        let total = TourPlace.all(pad: false).dropLast().map(\.dwell).reduce(0, +)
        #expect(total >= 12 && total <= 18, "\(total) s")
        #expect(TourPlace.watch.smallPrint == "Notifications and Live Activities need the Vory Companion on your gateway.")
        #expect(TourPlace.devices.caption == nil)
    }

    @Test func vorysLineFollowsThePlace() {
        var lines = TourLines()
        lines.arrived(at: .everywhere)
        lines.placeShown(.island)
        let first = lines.key(for: .everywhere)
        #expect(lines.text(for: .everywhere) == "You\u{2019}ll see these wherever you are.")
        // The three places an ask reaches share the line: it isn't typed again.
        lines.placeShown(.lockScreen)
        lines.placeShown(.watch)
        #expect(lines.key(for: .everywhere) == first)
        // The clock leaves beat 5 to its places.
        lines.advance(on: .everywhere, demo: true)
        #expect(lines.text(for: .everywhere) == "You\u{2019}ll see these wherever you are.")
        lines.placeShown(.devices)
        #expect(lines.text(for: .everywhere) == "I\u{2019}m on your \(TourPlace.otherDevice) and Mac too.")
        lines.placeShown(.homeAway)
        #expect(lines.text(for: .everywhere) == "Give me a backup address and I\u{2019}ll still find you away from home.")
        lines.placeShown(.iCloud)
        #expect(lines.text(for: .everywhere) == "Your gateways and bot looks sync through iCloud.")
    }

    @Test func theWordsKeepToTheCopy() {
        var words = TourLines.lines(.everywhere, demo: true)
        words += TourPlace.allCases.compactMap(\.caption) + TourPlace.allCases.compactMap(\.smallPrint) + TourPlace.allCases.map(\.spoken)
        for w in words {
            #expect(!w.contains("\u{2014}"), "an em dash: \(w)")
            #expect(!w.contains("TODO("), "a placeholder: \(w)")
        }
        // Vory's bubbles stay short: 13 to 64 characters, as all his lines.
        for line in TourLines.lines(.everywhere, demo: true) { #expect((13...64).contains(line.count), "\(line.count): \(line)") }
    }

    @Test func theLiveActivityIsSproutsAskFromTheDemo() {
        let a = TourActivity.attributes, s = TourActivity.asking
        #expect(a.displayBotName == "Sprout")
        #expect(a.profile == TourChat.profile)
        #expect(a.connectionID == GatewayConnection.demoID.uuidString)
        let sprout = DemoBots.all.first { $0.display == "Sprout" }
        #expect(a.tintHex == sprout?.hex && a.avatar == sprout.map { "studio:\($0.shape):\($0.eyes)" })
        #expect(s.needsAttention && s.attentionKind == "approval")
        #expect(s.detail == "find ./logs -mtime +30 -delete")
        #expect(PhaseText.headline(for: s) == "Approval needed")
    }
}
#endif
