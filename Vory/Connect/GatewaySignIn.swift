import SwiftUI
import VoryCore

extension GatewayConnection {
    /// Whether this device holds what the gateway's sign-in method needs. A gateway that came
    /// back from iCloud brings its address, and its session token when it uses one; a browser
    /// or password sign-in stays on the device it was made on, so it is missing here.
    func lacksCredentials(_ secrets: GatewaySecrets) -> Bool {
        switch authMode {
        case .sessionToken: return (secrets.sessionToken ?? "").trimmingCharacters(in: .whitespaces).isEmpty
        case .oauth, .password: return secrets.bearer == nil
        }
    }
}

/// Signing a saved gateway in again on this device: after a restore, or when its session ran out.
@MainActor
enum GatewaySignIn {
    /// A browser sign-in can be run from anywhere. The other methods need something typed, so
    /// they go through the gateway's form.
    static func usesBrowser(_ c: GatewayConnection) -> Bool { c.authMode == .oauth }

    /// The gateways among `connections` this device cannot use yet.
    static func pending(_ connections: [GatewayConnection], secrets: (GatewayConnection) -> GatewaySecrets) -> [GatewayConnection] {
        connections.filter { $0.lacksCredentials(secrets($0)) }
    }

    /// Runs the browser sign-in for a saved gateway, saves the session and connects with it,
    /// the same way saving the gateway's form does.
    static func browser(_ c: GatewayConnection, model: AppModel, client: NativeAuthClient) async throws {
        let access = model.store.secrets(for: c.id).access
        var secrets = try await client.signInWithBrowser(gateway: c.gateway, provider: c.authProvider, access: access)
        secrets.access = access
        try model.store.upsert(c, secrets: secrets)
        if model.runtime?.connection.id == c.id { await model.deactivate() }
        await model.activate(c)
        NotificationCenter.default.post(name: .hermesSessionsChanged, object: nil)
    }
}

/// Asked right after a restore, before the app is used, and from the Sign In banner: one
/// gateway at a time, the browser for a browser sign-in and the gateway's form for the rest.
struct GatewaySignInSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    /// The gateways to sign in to, in order.
    let connections: [GatewayConnection]
    @State private var index = 0
    @State private var busy = false
    @State private var error: String?
    @State private var showForm = false
    @State private var client = NativeAuthClient()

    private var current: GatewayConnection? { connections.indices.contains(index) ? connections[index] : nil }

    var body: some View {
        FittedSheet {
            VStack(spacing: 16) {
                BotFaceView(spec: BotLookSpec.vory, size: 84, active: busy, mood: BotFaceView.Mood(profile: "vory-signin", state: busy ? .thinking : .guide))
                if let c = current {
                    Text("Sign in to \(c.name)").font(.title3.weight(.semibold)).multilineTextAlignment(.center)
                    if connections.count > 1 {
                        Text("Gateway \(index + 1) of \(connections.count)").font(.caption).foregroundStyle(.secondary)
                    }
                    Text(GatewaySignIn.usesBrowser(c)
                         ? "A sign-in stays on the device it was made on, so \(DeviceWords.this) signs in once. Your browser opens the gateway's sign-in page and brings you back here."
                         : "A sign-in stays on the device it was made on, so \(DeviceWords.this) needs this gateway's \(c.authMode == .password ? "username and password" : "session token") once.")
                        .font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                    Text(c.gateway.description).font(.footnote.monospaced()).foregroundStyle(.tertiary).lineLimit(1).truncationMode(.middle)
                    if let error {
                        Text(error).font(.footnote).foregroundStyle(.red).multilineTextAlignment(.center)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    VStack(spacing: 10) {
                        if GatewaySignIn.usesBrowser(c) {
                            Button { signIn(c) } label: {
                                HStack(spacing: 8) {
                                    if busy { ProgressView().controlSize(.small) }
                                    Text(busy ? "Waiting for the browser…" : "Sign In with Browser").font(.headline)
                                }
                                .frame(maxWidth: .infinity).padding(.vertical, 6)
                            }
                            .buttonStyle(.glassProminent)
                            .disabled(busy)
                            .accessibilityIdentifier("signin.browser")
                        } else {
                            Button { showForm = true } label: {
                                Text("Enter Sign-In…").font(.headline).frame(maxWidth: .infinity).padding(.vertical, 6)
                            }
                            .buttonStyle(.glassProminent)
                            .accessibilityIdentifier("signin.form")
                        }
                        Button(connections.count > 1 && index < connections.count - 1 ? "Skip this one" : "Later") { next() }
                            .font(.subheadline).foregroundStyle(.secondary)
                            #if os(macOS)
                            .buttonStyle(.borderless)
                            #endif
                            .disabled(busy)
                            .accessibilityIdentifier("signin.later")
                    }
                    Text("Until then this gateway's chats cannot be shown. You can sign in later from Chats or Settings › Gateways.")
                        .font(.footnote).foregroundStyle(.secondary).multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(.horizontal, 28).padding(.bottom, 24)
            .frame(maxWidth: 440)
        }
        .interactiveDismissDisabled(busy)
        // The gateway's form, for a sign-in that is typed. Saving it signs in and connects.
        .sheet(isPresented: $showForm, onDismiss: { if let c = current, !c.lacksCredentials(model.store.secrets(for: c.id)) { next() } }) {
            if let c = current {
                NavigationStack { GatewayFormView(existing: model.store.connections.first { $0.id == c.id } ?? c) }.sheetFrame()
            }
        }
    }

    private func signIn(_ c: GatewayConnection) {
        busy = true; error = nil
        Task {
            defer { busy = false }
            do {
                try await GatewaySignIn.browser(c, model: model, client: client)
                next()
            } catch NativeAuthError.cancelled {
                // The browser was closed: nothing to say, the button is there again.
            } catch {
                self.error = error.localizedDescription
            }
        }
    }

    /// On to the next gateway, or done.
    private func next() {
        error = nil
        if index + 1 < connections.count { withAnimation(.snappy) { index += 1 } } else { dismiss() }
    }
}

/// Over a page that has nothing to show because the gateway has no sign-in on this device:
/// what is wrong, and the button that fixes it.
struct GatewaySignInBanner: View {
    @Environment(AppModel.self) private var model
    var connection: GatewayConnection

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "person.badge.key.fill").font(.title3).foregroundStyle(.orange)
            VStack(alignment: .leading, spacing: 2) {
                Text("Sign in to \(connection.name)").font(.subheadline.weight(.semibold))
                Text("\(DeviceWords.This) is not signed in to this gateway.").font(.caption).foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            Button("Sign In") { model.signInPrompt = [connection] }
                .buttonStyle(.borderedProminent).controlSize(.small)
                .accessibilityIdentifier("signin.banner")
        }
        .padding(12)
        .background(Color.orange.opacity(0.12), in: .rect(cornerRadius: 14))
        .accessibilityElement(children: .contain)
    }
}
