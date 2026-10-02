import SwiftUI
import VoryCore

/// Asked once, right after the first gateway connects. Two shapes: a gateway with no Companion
/// yet gets "install now or later"; one that already runs it (set up from another device) only
/// needs notifications allowed here, and the device registers itself from there.
struct CompanionPromptSheet: View {
    /// The Companion's version on the gateway, when one is already installed.
    var found: String?
    var install: () -> Void
    var allow: () -> Void
    var later: () -> Void

    #if os(macOS)
    private static let device = "this Mac"
    private static let pitch = "The Companion is a small plugin on your gateway. With it, replies arrive as notifications and approval cards reach you the moment a bot needs a yes."
    #else
    private static let device = DeviceWords.this
    private static let pitch = "The Companion is a small plugin on your gateway. With it, replies arrive as notifications, a Live Activity follows every turn, and approval cards reach \(DeviceWords.your) the moment a bot needs a yes."
    #endif

    var body: some View {
        FittedSheet { card }
    }

    private var card: some View {
        VStack(spacing: 18) {
            BotFaceView(spec: BotLookSpec.vory, size: 96, active: true)
            if let found {
                Text("The Companion is already here").font(.title2.weight(.bold)).multilineTextAlignment(.center)
                Text("This gateway runs Companion \(found), set up from another device. Allow notifications on \(Self.device) and it will start sending here too; nothing to install.")
                    .font(.body).foregroundStyle(.secondary).multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                VStack(spacing: 10) {
                    Button(action: allow) { Text("Allow notifications").font(.headline).frame(maxWidth: .infinity).padding(.vertical, 6) }
                        .buttonStyle(.glassProminent)
                    Button(action: later) { Text("Not now").font(.subheadline) }
                        .foregroundStyle(.secondary)
                }
                .padding(.top, 6)
                Text("Settings › Notifications can turn it on later.").font(.caption).foregroundStyle(.tertiary)
            } else {
                Text("Unlock Vory's full potential").font(.title2.weight(.bold)).multilineTextAlignment(.center)
                Text(Self.pitch)
                    .font(.body).foregroundStyle(.secondary).multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                VStack(spacing: 10) {
                    Button(action: install) { Text("Install now").font(.headline).frame(maxWidth: .infinity).padding(.vertical, 6) }
                        .buttonStyle(.glassProminent)
                    Button(action: later) { Text("Later").font(.subheadline) }
                        .foregroundStyle(.secondary)
                }
                .padding(.top, 6)
                Text("Later is fine — Settings will remind you.").font(.caption).foregroundStyle(.tertiary)
            }
        }
        .padding(.horizontal, 28).padding(.bottom, 24)
        #if os(macOS)
        .frame(width: 420)
        #else
        .frame(maxWidth: 440)
        #endif
    }

    /// The Companion's version on the gateway, or nil when it is not installed there. A quick
    /// read of its manifest; the same check Settings › Status makes.
    @MainActor static func installedVersion(on runtime: GatewayRuntime) async -> String? {
        let probe = PushSetupModel()
        await probe.checkCompanion(runtime: runtime)
        return probe.installedVersion
    }
}
