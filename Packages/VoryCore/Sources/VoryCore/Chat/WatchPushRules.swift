import Foundation

/// The Watch's push registration (#499). The Watch registers its own device token with the push relay (one record per
/// install, serving every gateway it has) and writes a device file on each gateway, so the gateway's Companion can reach
/// it. Notifications being off on the Watch or the iPhone changes neither: the complications' refresh pushes carry no
/// chat data and keep them instant (Matt, 2026-10-21; the privacy page says so).
public enum WatchPushRules {
    /// What leaving a gateway (removed on the iPhone, or the iPhone reset) does to the registration: that gateway's
    /// device file always goes, so it no longer pushes to this Watch; the relay record only with the last gateway, as the
    /// others' pushes still need it. The iPhone's own rule is the same (`PushRegistrar.relayForgets`, #509).
    public static func onGatewayRemoved(gatewaysLeft: Int) -> (removeDeviceFile: Bool, unregisterFromRelay: Bool) {
        (true, gatewaysLeft == 0)
    }

    /// Whether the Watch keeps (and refreshes) its relay registration with notifications off: yes.
    public static func keepsRegistration(notificationsOn: Bool) -> Bool { true }
}
