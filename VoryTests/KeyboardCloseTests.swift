#if os(iOS)
import Foundation
import Testing
@testable import Vory

/// The keyboard closes from the chat (#350): a tap in the thread and VoiceOver's escape close the on-screen keyboard,
/// only while one is up and never from the dock or the header; Close keyboard after sending puts it away after a send in
/// the app's own chats, and the demo and the tour put it away either way.
@Suite @MainActor struct KeyboardCloseTests {
    /// A tap in the thread closes the keyboard while a field is editing with no hardware keyboard; with a hardware
    /// keyboard (nothing on screen to close) or no field editing, it leaves things as they are.
    @Test func aTapClosesOnlyAnOnScreenKeyboard() {
        let open = KeyboardCloseRule.tapCloses(y: 400, dockTop: 700, headerBottom: 100, fieldEditing: true, hardwareKeyboard: false)
        let hardware = KeyboardCloseRule.tapCloses(y: 400, dockTop: 700, headerBottom: 100, fieldEditing: true, hardwareKeyboard: true)
        let noField = KeyboardCloseRule.tapCloses(y: 400, dockTop: 700, headerBottom: 100, fieldEditing: false, hardwareKeyboard: false)
        #expect(open)
        #expect(!hardware)
        #expect(!noField)
    }

    /// A tap that lands on the dock or the header, which float over the thread, is theirs, not the thread's; until they
    /// are measured (0) they rule nothing out.
    @Test func aTapOnTheDockOrTheHeaderLeavesTheKeyboardUp() {
        let onDock = KeyboardCloseRule.tapCloses(y: 720, dockTop: 700, headerBottom: 100, fieldEditing: true, hardwareKeyboard: false)
        let onDockEdge = KeyboardCloseRule.tapCloses(y: 700, dockTop: 700, headerBottom: 100, fieldEditing: true, hardwareKeyboard: false)
        let onHeader = KeyboardCloseRule.tapCloses(y: 80, dockTop: 700, headerBottom: 100, fieldEditing: true, hardwareKeyboard: false)
        let justBelowHeader = KeyboardCloseRule.tapCloses(y: 101, dockTop: 700, headerBottom: 100, fieldEditing: true, hardwareKeyboard: false)
        let unmeasured = KeyboardCloseRule.tapCloses(y: 720, dockTop: 0, headerBottom: 0, fieldEditing: true, hardwareKeyboard: false)
        #expect(!onDock)
        #expect(!onDockEdge)
        #expect(!onHeader)
        #expect(justBelowHeader)
        #expect(unmeasured)
    }

    /// VoiceOver's escape closes the keyboard while one is up; otherwise it is left to go on (Back, in a pushed chat).
    @Test func voiceOversEscapeClosesTheKeyboardOnlyWhileOneIsUp() {
        #expect(KeyboardCloseRule.escapeCloses(fieldEditing: true, hardwareKeyboard: false))
        #expect(!KeyboardCloseRule.escapeCloses(fieldEditing: true, hardwareKeyboard: true))
        #expect(!KeyboardCloseRule.escapeCloses(fieldEditing: false, hardwareKeyboard: false))
    }

    /// After a send the app's own chats keep the keyboard unless the setting is on; the demo and the tour (whose place
    /// keeps no focus) put it away whatever the setting.
    @Test func closeKeyboardAfterSendingGovernsTheAppsOwnChats() {
        #expect(ComposerFocusRule.afterSend(placeKeepsFocus: true, closeAfterSending: false))
        #expect(!ComposerFocusRule.afterSend(placeKeepsFocus: true, closeAfterSending: true))
        #expect(!ComposerFocusRule.afterSend(placeKeepsFocus: false, closeAfterSending: false))
        #expect(!ComposerFocusRule.afterSend(placeKeepsFocus: false, closeAfterSending: true))
    }
}
#endif
