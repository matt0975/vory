import SwiftUI
import VoryCore

/// Add / edit a gateway. Nothing is pre-filled; Save requires a passing Test Connection.
struct GatewayFormView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    var existing: GatewayConnection?
    var onSaved: ((GatewayConnection) -> Void)?

    /// How the phone reaches the gateway. Only changes the help and the fields shown; the URL,
    /// the auth method and the optional Access headers are what actually connect.
    enum ConnectionKind: String, CaseIterable, Identifiable {
        case local, tailscale, cloudflare, other
        var id: String { rawValue }
        var title: String {
            switch self {
            case .local: return "Local network"
            case .tailscale: return "Tailscale"
            case .cloudflare: return "Cloudflare Access"
            case .other: return "Other"
            }
        }
        var symbol: String {
            switch self {
            case .local: return "wifi"
            case .tailscale: return "point.3.connected.trianglepath.dotted"
            case .cloudflare: return "cloud"
            case .other: return "globe"
            }
        }
        var placeholder: String {
            switch self {
            case .local: return "http://192.168.1.20:9119"
            case .tailscale: return "http://my-mac.tail1234.ts.net:9119"
            case .cloudflare: return "https://hermes.example.com"
            case .other: return "https://hermes.example.com"
            }
        }
        var help: String {
            switch self {
            case .local: return "Same Wi‑Fi as the gateway machine. Use its LAN address and the port hermes serve prints (9119 by default). Plain http is fine here; it only works at home."
            case .tailscale: return "Reach the gateway from anywhere over your tailnet. Install Tailscale on this iPhone and the gateway machine, then use the machine's MagicDNS name or its 100.x address. No port forwarding, no public exposure; plain http is safe inside the tailnet."
            case .cloudflare: return "A public hostname behind Cloudflare Access (a Cloudflare Tunnel on the gateway machine). Enter the service token below — the app cannot use a browser login for Access. Always https."
            case .other: return "Any https address that reaches the dashboard: a reverse proxy, a VPS, your own VPN. Add Access headers only if Cloudflare sits in front."
            }
        }
    }
    @State private var kind: ConnectionKind = .local
    @State private var name = ""
    @State private var urlText = ""
    @State private var pathPrefix = ""
    @State private var authMode: AuthMode = .sessionToken
    @State private var sessionToken = ""
    @State private var username = ""
    @State private var password = ""
    @State private var providerName = ""
    @State private var providers: [AuthProvider] = []
    @State private var cfClientId = ""
    @State private var cfClientSecret = ""
    @State private var bearerSecrets: GatewaySecrets?
    @State private var steps: [ConnectionTestStep] = []
    @State private var testing = false
    @State private var testPassed = false
    @State private var testedVersion: String?
    @State private var errorMessage: String?
    @State private var signingIn = false
    @State private var authClient = NativeAuthClient()

    /// A bare address on a home network or tailnet means plain http (no certificate there);
    /// anywhere else, https. Typing the scheme always wins.
    private var defaultScheme: String { kind == .local || kind == .tailscale ? "http" : "https" }
    private var normalizedURL: GatewayURL? { try? GatewayURL.normalize(urlText, pathPrefix: pathPrefix, defaultScheme: defaultScheme) }
    private var urlError: String? {
        guard !urlText.isEmpty else { return nil }
        do { _ = try GatewayURL.normalize(urlText, pathPrefix: pathPrefix, defaultScheme: defaultScheme); return nil } catch { return error.localizedDescription }
    }
    private var access: CloudflareAccess { CloudflareAccess(clientId: cfClientId.trimmingCharacters(in: .whitespaces), clientSecret: cfClientSecret.trimmingCharacters(in: .whitespaces)) }

    var body: some View {
        Form {
            Section {
                Picker("Connection", selection: $kind) {
                    ForEach(ConnectionKind.allCases) { Label($0.title, systemImage: $0.symbol).tag($0) }
                }
                .pickerStyle(.menu)
            } footer: {
                Text(kind.help)
            }
            Section {
                TextField("Name", text: $name, prompt: Text("Home"))
                    .accessibilityIdentifier("gateway.name")
                TextField("Gateway URL", text: $urlText, prompt: Text(kind.placeholder))
                    .keyboardType(.URL).textContentType(.URL).autocorrectionDisabled().textInputAutocapitalization(.never)
                    .accessibilityIdentifier("gateway.url")
                TextField("Path prefix (optional)", text: $pathPrefix, prompt: Text("/hermes"))
                    .autocorrectionDisabled().textInputAutocapitalization(.never)
            } header: {
                Text("Gateway")
            } footer: {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Enter the URL of your Hermes dashboard (`hermes serve`), not a chat-webui or SSH app. Reverse-proxy path prefixes are supported.")
                    if let urlError { Text(urlError).foregroundStyle(.red) }
                    else if let u = normalizedURL {
                        Text("Will connect to \(u.description)").foregroundStyle(.secondary)
                        if !urlText.contains("://") { Text(u.isTLS ? "No scheme typed, so https. Type http:// for a plain connection." : "No scheme typed, so plain http. Type https:// if the gateway has a certificate.").foregroundStyle(.secondary) }
                        if !u.isTLS && !u.isPrivateHost && !u.isTailscaleHost { Text("This is plain HTTP to a public host; credentials will travel unencrypted.").foregroundStyle(.orange) }
                        if kind == .tailscale && !u.isTailscaleHost { Text("This does not look like a Tailscale address (a *.ts.net name or 100.x.x.x).").foregroundStyle(.orange) }
                        if kind == .local && !u.isPrivateHost && !u.isTailscaleHost { Text("This is not a local address; pick another connection type if the gateway is elsewhere.").foregroundStyle(.orange) }
                        if kind == .cloudflare && !u.isTLS { Text("Cloudflare Access needs https.").foregroundStyle(.orange) }
                        if u.isTailscaleHost { Text("Tailscale must be connected on this iPhone for the test to pass.").foregroundStyle(.secondary) }
                    }
                }
            }

            Section {
                NavigationLink { TroubleshootingView() } label: { Label("Troubleshooting", systemImage: "wrench.and.screwdriver") }
            } footer: {
                Text("What to check when the test stops, sign-in fails, or the Companion will not install.")
            }

            Section("Authentication") {
                Picker("Method", selection: $authMode) {
                    ForEach(AuthMode.allCases) { Text($0.title).tag($0) }
                }
                .accessibilityIdentifier("gateway.authMethod")
                switch authMode {
                case .sessionToken:
                    SecureField("Session token", text: $sessionToken)
                        .textContentType(.password).autocorrectionDisabled()
                        .accessibilityIdentifier("gateway.sessionToken")
                    Text("The dashboard's HERMES_DASHBOARD_SESSION_TOKEN. Used when the gateway has no auth gate (loopback / trusted network).")
                        .font(.footnote).foregroundStyle(.secondary)
                case .password:
                    providerPicker
                    TextField("Username", text: $username).textContentType(.username).autocorrectionDisabled().textInputAutocapitalization(.never)
                        .accessibilityIdentifier("gateway.username")
                    SecureField("Password", text: $password).textContentType(.password)
                        .accessibilityIdentifier("gateway.password")
                    Text("The password is exchanged for a session and never stored.").font(.footnote).foregroundStyle(.secondary)
                case .oauth:
                    providerPicker
                    Button {
                        Task { await signInWithBrowser() }
                    } label: {
                        HStack {
                            Label(bearerSecrets == nil ? "Sign in with browser" : "Signed in", systemImage: bearerSecrets == nil ? "safari" : "checkmark.circle.fill")
                            if signingIn { Spacer(); ProgressView() }
                        }
                    }
                    .disabled(normalizedURL == nil || signingIn)
                    Text("Opens the system browser against this gateway's /auth/native/authorize (PKCE). Tokens are stored in the Keychain.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
            }

            if kind == .cloudflare || kind == .other || access.isPartiallyConfigured || !cfClientId.isEmpty {
                Section {
                    TextField("CF-Access-Client-Id", text: $cfClientId).autocorrectionDisabled().textInputAutocapitalization(.never)
                    SecureField("CF-Access-Client-Secret", text: $cfClientSecret)
                } header: {
                    Text(kind == .cloudflare ? "Cloudflare Access service token" : "Cloudflare Access (optional)")
                } footer: {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(kind == .cloudflare
                             ? "From Zero Trust › Access › Service Auth: create a service token and allow it in the application's policy. Both values are sent on every request and on the WebSocket handshake."
                             : "Leave blank unless Cloudflare Access is in front of your gateway. Safari cookies do not carry over to the app.")
                        if access.isPartiallyConfigured { Text("Enter both the Client ID and the Client Secret, or leave both blank.").foregroundStyle(.red) }
                    }
                }
            }

            Section {
                Button {
                    Task { await runTest() }
                } label: {
                    HStack {
                        Label("Test Connection", systemImage: "antenna.radiowaves.left.and.right")
                        Spacer()
                        if testing { ProgressView() }
                        else if testPassed { Image(systemName: "checkmark.circle.fill").foregroundStyle(.green) }
                    }
                }
                .disabled(!canTest || testing)
                .accessibilityIdentifier("gateway.test")
                ForEach(steps) { step in
                    HStack(alignment: .top, spacing: 10) {
                        stepIcon(step.status)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(step.title).font(.subheadline)
                            switch step.status {
                            case .passed(let s): Text(s).font(.footnote).foregroundStyle(.secondary)
                            case .failed(let s): Text(s).font(.footnote).foregroundStyle(.red).textSelection(.enabled)
                            default: EmptyView()
                            }
                        }
                    }
                }
                if let errorMessage { Text(errorMessage).foregroundStyle(.red).font(.footnote) }
            } footer: {
                Text("Checks that /api/status returns JSON (not an HTML login page), that your credentials are accepted, and that the WebSocket at /api/ws opens.")
            }
        }
        .navigationTitle(existing == nil ? "Add Gateway" : "Edit Gateway")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            ToolbarItem(placement: .confirmationAction) { Button("Save") { save() }.disabled(!testPassed || name.trimmingCharacters(in: .whitespaces).isEmpty).accessibilityIdentifier("gateway.save") }
        }
        .onChange(of: urlText) { _, _ in invalidate() }
        .onChange(of: kind) { _, _ in invalidate() }
        .onChange(of: pathPrefix) { _, _ in invalidate() }
        .onChange(of: authMode) { _, _ in invalidate(); Task { await loadProviders() } }
        .onChange(of: sessionToken) { _, _ in invalidate() }
        .onChange(of: cfClientId) { _, _ in invalidate() }
        .onChange(of: cfClientSecret) { _, _ in invalidate() }
        .task { loadExisting(); await loadProviders() }
    }

    private var providerPicker: some View {
        Group {
            if providers.isEmpty {
                TextField("Provider name", text: $providerName, prompt: Text(authMode == .password ? "basic" : "nous"))
                    .autocorrectionDisabled().textInputAutocapitalization(.never)
            } else {
                Picker("Provider", selection: $providerName) {
                    ForEach(providers.filter { authMode == .password ? ($0.supportsPassword ?? false) : true }) { p in
                        Text(p.displayName ?? p.name).tag(p.name)
                    }
                }
            }
        }
    }

    @ViewBuilder private func stepIcon(_ s: ConnectionTestStep.Status) -> some View {
        switch s {
        case .pending: Image(systemName: "circle").foregroundStyle(.tertiary)
        case .running: ProgressView().controlSize(.small)
        case .passed: Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
        case .failed: Image(systemName: "xmark.circle.fill").foregroundStyle(.red)
        }
    }

    private var canTest: Bool {
        guard normalizedURL != nil, !access.isPartiallyConfigured else { return false }
        switch authMode {
        case .sessionToken: return !sessionToken.isEmpty
        case .password: return !username.isEmpty && !password.isEmpty
        case .oauth: return bearerSecrets != nil
        }
    }

    private func invalidate() { testPassed = false; steps = [] }

    private func loadExisting() {
        guard let c = existing else { return }
        name = c.name
        urlText = c.gateway.description
        kind = ConnectionKind(rawValue: c.connectionKind ?? "") ?? (c.hasAccessHeaders ? .cloudflare : c.gateway.isTailscaleHost ? .tailscale : c.gateway.isPrivateHost ? .local : .other)
        authMode = c.authMode
        providerName = c.authProvider ?? ""
        let s = model.store.secrets(for: c.id)
        sessionToken = s.sessionToken ?? ""
        cfClientId = s.access.clientId
        cfClientSecret = s.access.clientSecret
        if s.bearer != nil { bearerSecrets = s }
    }

    private func loadProviders() async {
        guard authMode != .sessionToken, let u = normalizedURL else { return }
        if let p = try? await NativeAuthClient.providers(gateway: u, access: access), !p.isEmpty {
            providers = p
            if providerName.isEmpty || !p.contains(where: { $0.name == providerName }) {
                // Username/password only fits a provider that takes one; falling back to the
                // first provider (a browser sign-in) sent people into "does not support password
                // login" from the gateway. Say so here instead, before they type anything.
                if authMode == .password, let pw = p.first(where: { $0.supportsPassword ?? false }) { providerName = pw.name }
                else if authMode == .password { providerName = ""; errorMessage = Self.noPasswordProviderMessage(p) }
                else { providerName = p[0].name }
            }
        }
    }

    /// The gateway offers sign-in, but none of it takes a username and password.
    static func noPasswordProviderMessage(_ providers: [AuthProvider]) -> String {
        let names = providers.map(\.name).joined(separator: ", ")
        return "This gateway has no username/password sign-in (it offers: \(names)). Choose Sign in with browser above, or enable a password provider on the gateway (HERMES_DASHBOARD_BASIC_AUTH_USER and HERMES_DASHBOARD_BASIC_AUTH_PASSWORD) and try again."
    }

    private func signInWithBrowser() async {
        guard let u = normalizedURL else { return }
        signingIn = true; defer { signingIn = false }
        errorMessage = nil
        do {
            bearerSecrets = try await authClient.signInWithBrowser(gateway: u, provider: providerName.isEmpty ? nil : providerName, access: access)
            invalidate()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func buildSecrets() async throws -> GatewaySecrets {
        var s = GatewaySecrets()
        s.access = access
        switch authMode {
        case .sessionToken:
            s.sessionToken = sessionToken.trimmingCharacters(in: .whitespacesAndNewlines)
        case .password:
            if let b = bearerSecrets, b.bearer != nil, username.isEmpty { s = b; s.access = access; break }
            guard let u = normalizedURL else { throw GatewayURLError.invalid }
            if !providers.isEmpty, !providers.contains(where: { $0.supportsPassword ?? false }) {
                throw NativeAuthError.invalidResponse(Self.noPasswordProviderMessage(providers))
            }
            let provider = providerName.isEmpty ? "basic" : providerName
            do {
                s = try await NativeAuthClient.signInWithPassword(gateway: u, provider: provider, username: username, password: password, access: access)
            } catch let e as HermesAPIError {
                // The gateway's own wording for a browser-only provider, turned into what to do.
                if e.localizedDescription.localizedCaseInsensitiveContains("does not support password") {
                    throw NativeAuthError.invalidResponse(providers.isEmpty
                        ? "The provider “\(provider)” on this gateway does not take a username and password. Choose Sign in with browser above, or enable a password provider on the gateway (HERMES_DASHBOARD_BASIC_AUTH_USER and HERMES_DASHBOARD_BASIC_AUTH_PASSWORD)."
                        : Self.noPasswordProviderMessage(providers))
                }
                throw e
            }
            bearerSecrets = s
        case .oauth:
            guard var b = bearerSecrets else { throw NativeAuthError.noCallback }
            b.access = access
            s = b
        }
        return s
    }

    private func runTest() async {
        guard let u = normalizedURL else { return }
        testing = true; testPassed = false; errorMessage = nil
        defer { testing = false }
        do {
            let secrets = try await buildSecrets()
            let conn = GatewayConnection(id: existing?.id ?? UUID(), name: name, gateway: u, authMode: authMode, authProvider: providerName.isEmpty ? nil : providerName)
            let outcome = await ConnectionTester.run(connection: conn, secrets: secrets) { s in Task { @MainActor in steps = s } }
            steps = outcome.steps
            testPassed = outcome.succeeded
            testedVersion = outcome.version
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func save() {
        guard let u = normalizedURL else { return }
        Task {
            do {
                let secrets = try await buildSecrets()
                var conn = existing ?? GatewayConnection(name: name, gateway: u, authMode: authMode)
                conn.name = name.trimmingCharacters(in: .whitespaces)
                conn.gateway = u
                conn.authMode = authMode
                conn.authProvider = providerName.isEmpty ? nil : providerName
                conn.lastVersion = testedVersion
                conn.connectionKind = kind.rawValue
                try model.store.upsert(conn, secrets: secrets)
                if model.runtime?.connection.id == conn.id { await model.deactivate() }
                onSaved?(conn)
                dismiss()
                await model.activate(conn)
            } catch let e as KeychainError {
                errorMessage = "Could not save to the Keychain (\(e.localizedDescription)). On a simulator this usually means the build is unsigned."
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }
}
