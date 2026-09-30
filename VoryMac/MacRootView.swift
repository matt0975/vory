import SwiftUI
import VoryCore

/// The Mac window's root: the first-run tour until a gateway is saved, then the app. The lock
/// covers either while it is on.
struct MacRootView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        ZStack {
            if model.hasConnections {
                ConnectedView()
            } else {
                OnboardingView()
                    .frame(minWidth: 520, minHeight: 680)
            }
            if model.lock.isLocked {
                MacLockView()
            }
        }
    }
}

/// Stand-in for the split view: what the gateway says about itself, and the way to its form.
/// The chats and the sidebar replace this once the Chat folder compiles here.
private struct ConnectedView: View {
    @Environment(AppModel.self) private var model
    @State private var editing = false

    var body: some View {
        VStack(spacing: 18) {
            BotFaceView(spec: BotLookSpec.vory, size: 96, active: model.runtime != nil, mood: BotFaceView.Mood(profile: "vory-mac-root"))
            if let rt = model.runtime {
                Text(rt.connection.name).font(.title2.weight(.semibold))
                Text(rt.connection.gateway.description).font(.callout).foregroundStyle(.secondary).textSelection(.enabled)
                Text("Socket: \(String(describing: rt.socketState)) · \(rt.profiles.count) bot\(rt.profiles.count == 1 ? "" : "s")")
                    .font(.footnote).foregroundStyle(.secondary)
            } else if let error = model.activationError {
                Text(error).font(.callout).foregroundStyle(.red)
            } else {
                ProgressView().controlSize(.small)
            }
            Button("Edit gateway…") { editing = true }
                .disabled(model.store.active == nil)
        }
        .padding(40)
        .frame(minWidth: 480, minHeight: 360)
        .sheet(isPresented: $editing) {
            NavigationStack { GatewayFormView(existing: model.store.active) }
                .frame(minWidth: 520, minHeight: 640)
        }
    }
}

/// The lock, over everything, until Touch ID or the password says yes.
private struct MacLockView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: "lock.fill").font(.system(size: 34, weight: .medium)).foregroundStyle(.secondary)
            Text("Vory is locked").font(.headline)
            if let e = model.lock.lastError { Text(e).font(.footnote).foregroundStyle(.secondary) }
            Button("Unlock with \(model.lock.biometryName)") { Task { await model.lock.unlock() } }
                .buttonStyle(.glassProminent)
                .keyboardShortcut(.defaultAction)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.regularMaterial)
        .task { await model.lock.unlock() }
    }
}
