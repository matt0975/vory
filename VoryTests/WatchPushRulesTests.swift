import Testing
@testable import VoryCore

/// #499: the Watch keeps its push registration with notifications off (its complications' refresh pushes carry no chat
/// data), and leaving a gateway removes that gateway's device file, and the relay record only with the last gateway.
@Suite struct WatchPushRulesTests {
    @Test func notificationsOffKeepTheRegistration() {
        #expect(WatchPushRules.keepsRegistration(notificationsOn: false))
        #expect(WatchPushRules.keepsRegistration(notificationsOn: true))
    }

    @Test func leavingOneOfSeveralGatewaysKeepsTheRelayRecord() {
        let r = WatchPushRules.onGatewayRemoved(gatewaysLeft: 1)
        #expect(r.removeDeviceFile)
        #expect(!r.unregisterFromRelay)
    }

    @Test func leavingTheLastGatewayUnregistersFromTheRelay() {
        let r = WatchPushRules.onGatewayRemoved(gatewaysLeft: 0)
        #expect(r.removeDeviceFile)
        #expect(r.unregisterFromRelay)
    }
}
