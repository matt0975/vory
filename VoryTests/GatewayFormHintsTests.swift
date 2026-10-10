import Foundation
import Testing
@testable import Vory
@testable import VoryCore

/// Add Gateway with an address that does not fit the chosen connection type (#307): the form
/// offers the type that fits in one tap, and says why Save is off instead of greying it.
@Suite struct GatewayFormHintsTests {
    private func url(_ s: String) throws -> GatewayURL { try GatewayURL.normalize(s) }
    typealias Kind = GatewayFormView.ConnectionKind

    @Test func thePublicAddressUnderLocalNetworkOffersOther() throws {
        #expect(Kind.suggested(for: try url("https://hermes.example.com"), chosen: .local) == .other)
        #expect(Kind.suggested(for: try url("https://hermes.example.com"), chosen: .tailscale) == .other)
        // The chosen type fits: nothing to offer.
        #expect(Kind.suggested(for: try url("http://192.168.1.20:9119"), chosen: .local) == nil)
        #expect(Kind.suggested(for: try url("http://my-mac.tail1234.ts.net:9119"), chosen: .tailscale) == nil)
        #expect(Kind.suggested(for: try url("https://hermes.example.com"), chosen: .other) == nil)
        #expect(Kind.suggested(for: try url("https://hermes.example.com"), chosen: .cloudflare) == nil)
        // A private or Tailscale address under Other: the matching type.
        #expect(Kind.suggested(for: try url("http://192.168.1.20:9119"), chosen: .other) == .local)
        #expect(Kind.suggested(for: try url("http://my-mac.tail1234.ts.net:9119"), chosen: .other) == .tailscale)
        #expect(Kind.suggested(for: try url("http://my-mac.tail1234.ts.net:9119"), chosen: .local) == nil)
    }

    @Test func saveSaysWhatIsMissing() {
        #expect(GatewayFormView.saveBlocker(named: true, urlOK: true, canTest: true, testPassed: true) == nil)
        #expect(GatewayFormView.saveBlocker(named: false, urlOK: true, canTest: true, testPassed: true) == "To save: give the gateway a name.")
        #expect(GatewayFormView.saveBlocker(named: true, urlOK: true, canTest: true, testPassed: false) == "To save: run Test Connection and let it pass.")
        #expect(GatewayFormView.saveBlocker(named: true, urlOK: true, canTest: false, testPassed: false) == "To save: fill in the sign-in.")
        #expect(GatewayFormView.saveBlocker(named: false, urlOK: false, canTest: false, testPassed: false) == "To save: enter the gateway's address, and give the gateway a name.")
    }
}
