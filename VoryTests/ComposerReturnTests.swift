import Foundation
import Testing
@testable import Vory

/// What Return does in the composer on the phone and the iPad (the Mac keeps its own field).
@Suite struct ComposerReturnTests {
    typealias R = ComposerReturnRule

    @Test func theOnScreenReturnAddsALineUnlessTheSettingMakesItSend() {
        #expect(R.action(hardware: false, shift: false, command: false, pickerOpen: false, returnSends: false) == .newline)
        #expect(R.action(hardware: false, shift: false, command: false, pickerOpen: false, returnSends: true) == .send)
    }

    @Test func aHardwareReturnSendsShiftReturnAddsALineAndCommandReturnSendsEitherWay() {
        for sends in [false, true] {
            #expect(R.action(hardware: true, shift: false, command: false, pickerOpen: false, returnSends: sends) == .send)
            #expect(R.action(hardware: true, shift: true, command: false, pickerOpen: false, returnSends: sends) == .newline)
            #expect(R.action(hardware: true, shift: false, command: true, pickerOpen: false, returnSends: sends) == .send)
            // Shift-Return on the on-screen keyboard (an external one reporting as such): a line too.
            #expect(R.action(hardware: false, shift: true, command: false, pickerOpen: false, returnSends: sends) == .newline)
        }
    }

    @Test func aBareReturnWithAPickerOpenTakesTheItem() {
        for hardware in [false, true] {
            for sends in [false, true] {
                #expect(R.action(hardware: hardware, shift: false, command: false, pickerOpen: true, returnSends: sends) == .pick)
            }
            // Modified Returns keep their meaning over the picker.
            #expect(R.action(hardware: hardware, shift: true, command: false, pickerOpen: true, returnSends: false) == .newline)
            #expect(R.action(hardware: hardware, shift: false, command: true, pickerOpen: true, returnSends: false) == .send)
        }
    }
}
