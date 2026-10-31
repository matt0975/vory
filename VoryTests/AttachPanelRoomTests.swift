import CoreGraphics
import Testing
@testable import Vory

/// The + panel's room above the card stops under the chat's measured header where that reaches lower than the 60 pt under
/// the safe area the panel always allowed (Duo stage 2: the laptop pose's row, a wide window's title pill), and is
/// unchanged on a phone and an iPad. Expected values are typed CGFloat (`#expect` makes an untyped sum an Int).
@Suite struct AttachPanelRoomTests {
    @Test func thePlusPanelStopsUnderTheChatsMeasuredHeader() {
        // The laptop pose: the row reaches y 150, lower than 60 pt under the safe area (82 + 60): the panel stops 10 pt
        // under it.
        #expect(AttachPanel.room(cardTop: 355, safeTop: 82, headerBottom: 150) == CGFloat(355 - 150 - 10))
        // A wide window's header (the title pill to y 92) under a safe area of 0.
        #expect(AttachPanel.room(cardTop: 420, safeTop: 0, headerBottom: 92) == CGFloat(420 - 92 - 10))
    }

    @Test func onAPhoneThePanelStopsUnderBackToo() {
        // The iPhone 17 Pro (iOS 27.2): the chat's row ends at 129.7, under the old line (62 + 60 = 122), so with the
        // keyboard up the panel stops under Back and the title instead of 7.7 pt over them.
        #expect(AttachPanel.room(cardTop: 400, safeTop: 62, headerBottom: 129.67) == CGFloat(400 - 129.67 - 10))
        // A header that ends above the old line, and one not measured yet: the old room stands.
        #expect(AttachPanel.room(cardTop: 700, safeTop: 62, headerBottom: 112) == CGFloat(700 - 62 - 60 - 10))
        #expect(AttachPanel.room(cardTop: 700, safeTop: 62, headerBottom: 0) == CGFloat(700 - 62 - 60 - 10))
    }
}
