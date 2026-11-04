import Foundation
import Testing

/// Demo mode's ways in and out (#392), where App Review looks: Try a demo on the first screen (the tour's first beat on
/// iPhone and iPad, the welcome screen on the Mac) and again past it (the tour's last beat, the Mac's last page), and
/// Leave demo outside Settings (the Chats chip's menu, the Mac's app menu). They are views' buttons, so the check reads
/// the sources, as PresentationModelTests does: each one is there, and each starts or ends the demo the one way.
@Suite struct DemoEntryPointsTests {
    private static let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
    private static func lines(_ path: String) throws -> [String] {
        try String(contentsOf: root.appending(path: path), encoding: .utf8).components(separatedBy: "\n")
    }

    /// Every "Try a demo": the four of them, each a button that starts the demo (the tour's through `onDemo`, which
    /// OnboardingView makes `model.startDemo()`), each with its own identifier; and the first beat is handed the tour's
    /// `onDemo`, so a replay (nil) offers none.
    @Test func everyTryADemoStartsTheDemo() throws {
        let tour = try Self.lines("Vory/Connect/Tour.swift"), onboarding = try Self.lines("Vory/Connect/OnboardingView.swift")
        func near(_ ls: [String], _ i: Int, _ text: String) -> Bool { ls[max(0, i - 2)...min(ls.count - 1, i + 6)].contains { $0.contains(text) } }
        let inTour = tour.indices.filter { tour[$0].contains("\"Try a demo\"") }
        let inOnboarding = onboarding.indices.filter { onboarding[$0].contains("\"Try a demo\"") }
        #expect(inTour.count == 2, "Try a demo in Tour.swift: \(inTour.count), not 2 (the first beat and the last)")
        #expect(inOnboarding.count == 2, "Try a demo in OnboardingView.swift: \(inOnboarding.count), not 2 (the welcome and the Mac's last page)")
        for i in inTour { #expect(near(tour, i, "Button(action: onDemo)"), "Tour.swift:\(i + 1): a Try a demo that isn't onDemo's button") }
        for i in inOnboarding { #expect(near(onboarding, i, "model.startDemo()"), "OnboardingView.swift:\(i + 1): a Try a demo that doesn't start the demo") }
        let ids = ["onboarding.tryDemo.first", "onboarding.tryDemo\""].map { id in tour.filter { $0.contains(id) }.count }
        #expect(ids == [1, 1], "Tour.swift's identifiers: \(ids)")
        let onboardingIDs = ["onboarding.tryDemo\"", "onboarding.tryDemo.last"].map { id in onboarding.filter { $0.contains(id) }.count }
        #expect(onboardingIDs == [1, 1], "OnboardingView.swift's identifiers: \(onboardingIDs)")
        #expect(tour.contains { $0.contains("TourHelloBeat(onStart:") && $0.contains("onDemo: onDemo") }, "the first beat isn't handed the tour's onDemo")
        #expect(onboarding.contains { $0.contains("onDemo: model.demoAvailable ? { Task { await model.startDemo() } } : nil") },
                "the tour's onDemo isn't the demo's start while it can start")
    }

    /// Every "Leave demo": in Settings, the Chats chip's menu and the Mac's app menu, each only in the demo and each
    /// `model.endDemo()`, Leave demo's one clean-up (#632).
    @Test func everyLeaveDemoEndsIt() throws {
        let places = ["Vory/Settings/SettingsView.swift", "Vory/Chat/ChatListView.swift", "VoryMac/VoryMacApp.swift"]
        var found: [String] = []
        for path in places {
            let ls = try Self.lines(path)
            for (i, l) in ls.enumerated() where l.contains("\"Leave demo\"") || l.contains("\"Leave Demo\"") {
                found.append("\(path):\(i + 1)")
                #expect(l.contains("model.endDemo()"), "\(path):\(i + 1): a Leave demo that isn't endDemo")
                let above = ls[max(0, i - 8)...i].joined(separator: "\n")
                #expect(above.contains("isInDemo"), "\(path):\(i + 1): a Leave demo shown outside the demo")
            }
        }
        #expect(found.count == 3, "Leave demo at \(found), not one in each of \(places)")
    }
}
