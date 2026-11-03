import Testing
import SwiftUI
@testable import Vory

@Suite("HTMLCard Height Persistence Tests")
struct HTMLCardHeightCacheTests {
    @Test("Measured HTMLCard heights are preserved across view instantiations")
    @MainActor
    func htmlCardHeightPersistence() async {
        let sampleHTML = "<div style=\"height: 380px;\">Interactive Widget</div>"
        let hash = sampleHTML.hashValue

        // Initially no cached height
        HTMLCardView.measuredHeights.removeValue(forKey: hash)

        // Simulated measurement update from JavaScript DOM inspection
        HTMLCardView.measuredHeights[hash] = 380

        // Create new card view instance
        let _ = HTMLCardView(html: sampleHTML)

        #expect(HTMLCardView.measuredHeights[hash] == 380)

        // Clear test entry
        HTMLCardView.measuredHeights.removeValue(forKey: hash)
    }

    @Test("Unmeasured HTMLCard defaults to initial height placeholder")
    @MainActor
    func unmeasuredCardDefaultsToStandardHeight() async {
        let uniqueHTML = "<p>Unique document \(UUID().uuidString)</p>"
        let hash = uniqueHTML.hashValue

        HTMLCardView.measuredHeights.removeValue(forKey: hash)
        let _ = HTMLCardView(html: uniqueHTML)

        #expect(HTMLCardView.measuredHeights[hash] == nil)
    }
}
