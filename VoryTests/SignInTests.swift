import AuthenticationServices
import Foundation
import Testing
@testable import Vory
@testable import VoryCore

@Suite struct SignInTests {
    private func gateway(_ mode: AuthMode) throws -> GatewayConnection {
        GatewayConnection(name: "Home", gateway: try GatewayURL.normalize("https://gateway.example.com"), authMode: mode)
    }

    @Test func aGatewayWithoutItsSignInIsToldApart() throws {
        // A browser or password sign-in stays on the device it was made on.
        #expect(try gateway(.oauth).lacksCredentials(GatewaySecrets()))
        #expect(try gateway(.password).lacksCredentials(GatewaySecrets()))
        #expect(!(try gateway(.oauth).lacksCredentials(GatewaySecrets(accessToken: "a", refreshToken: "r"))))
        // A session token travels with the gateway, so it is only missing when it never was there.
        #expect(try gateway(.sessionToken).lacksCredentials(GatewaySecrets()))
        #expect(try gateway(.sessionToken).lacksCredentials(GatewaySecrets(sessionToken: "  ")))
        #expect(!(try gateway(.sessionToken).lacksCredentials(GatewaySecrets(sessionToken: "t"))))
        // Cloudflare Access values alone are not a sign-in.
        var access = GatewaySecrets(); access.access = CloudflareAccess(clientId: "id", clientSecret: "secret")
        #expect(try gateway(.oauth).lacksCredentials(access))
    }

    @MainActor @Test func onlyTheGatewaysThatNeedItAreAskedFor() throws {
        let token = try gateway(.sessionToken), browser = try gateway(.oauth), password = try gateway(.password)
        let pending = GatewaySignIn.pending([token, browser, password]) { c in
            c.id == token.id ? GatewaySecrets(sessionToken: "t") : GatewaySecrets()
        }
        #expect(pending.map(\.id) == [browser.id, password.id])
        #expect(GatewaySignIn.usesBrowser(browser))
        #expect(!GatewaySignIn.usesBrowser(password))
    }

    /// The browser session reports its end on a thread of the system's own. The handler used
    /// to belong to the main actor, and the Mac app aborted there as the browser handed back.
    @MainActor @Test func theBrowserSessionMayEndOnAnyThread() async {
        let result: Result<(code: String, state: String), Error> = await withCheckedContinuation { cont in
            let handler = NativeAuthClient.sessionEnded { cont.resume(returning: $0) }
            DispatchQueue.global().async {
                handler(nil, ASWebAuthenticationSessionError(.canceledLogin))
            }
        }
        guard case .failure(let error) = result, case NativeAuthError.cancelled = error else {
            Issue.record("closing the browser should read as cancelled, got \(result)")
            return
        }
    }
}
