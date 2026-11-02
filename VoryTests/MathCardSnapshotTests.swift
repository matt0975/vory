import Testing
import Foundation
import WebKit
import SwiftUI
@testable import VoryCore
@testable import Vory

@Suite struct MathCardSnapshotTests {

    @Test @MainActor func mathWebViewDismantleReleasesResources() {
        var height: CGFloat = 40
        var width: CGFloat = 100
        var loaded = false
        var snapshotCalled = false

        let view = MathWebView(
            equation: "\\int_0^1 x dx",
            document: "<html><body><div id='wrapper'>test</div></body></html>",
            dark: false,
            height: Binding(get: { height }, set: { height = $0 }),
            contentWidth: Binding(get: { width }, set: { width = $0 }),
            loaded: Binding(get: { loaded }, set: { loaded = $0 }),
            onSnapshot: { _ in
                snapshotCalled = true
            }
        )

        let coordinator = view.makeCoordinator()
        let web = view.makeWebView(coordinator)
        #expect(web.navigationDelegate === coordinator)

        #if os(iOS)
        MathWebView.dismantleUIView(web, coordinator: coordinator)
        #else
        MathWebView.dismantleNSView(web, coordinator: coordinator)
        #endif

        #expect(web.navigationDelegate == nil)
        #expect(coordinator.measuring?.isCancelled != false)
    }

    @Test @MainActor func snapshotCaptureStoresToCacheAndInvokesCallback() async throws {
        let equation = "E = mc^2"
        let markup = "<div class=\"katex-display\"><span class=\"katex\">E = mc^2</span></div>"
        let doc = MathCard.document(mathMarkup: markup, dark: true)

        var height: CGFloat = 0
        var width: CGFloat = 0
        var loaded = false
        var receivedSnapshot: PlatformImage?

        let view = MathWebView(
            equation: equation,
            document: doc,
            dark: true,
            height: Binding(get: { height }, set: { height = $0 }),
            contentWidth: Binding(get: { width }, set: { width = $0 }),
            loaded: Binding(get: { loaded }, set: { loaded = $0 }),
            onSnapshot: { img in
                receivedSnapshot = img
            }
        )

        let coordinator = view.makeCoordinator()
        let web = view.makeWebView(coordinator)

        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 300, height: 200))
        let vc = UIViewController()
        window.rootViewController = vc
        vc.view.addSubview(web)
        web.frame = CGRect(x: 0, y: 0, width: 300, height: 100)
        window.makeKeyAndVisible()

        // Wait for WKWebView navigation and measurement to complete
        for _ in 0..<40 {
            try await Task.sleep(for: .milliseconds(100))
            if receivedSnapshot != nil { break }
        }

        let cached = KaTeXCache.snapshot(for: equation, dark: true)
        print("DEBUG: loaded=\(loaded), width=\(width), height=\(height), received=\(String(describing: receivedSnapshot)), cached=\(String(describing: cached))")
        #expect(receivedSnapshot != nil || cached != nil)
        if let received = receivedSnapshot {
            #expect(cached === received)
            #expect(abs(received.size.height - height) <= 1)
            #expect(received.size.height < 100)
        }

        MathWebView.dismantleUIView(web, coordinator: coordinator)
        window.isHidden = true
    }
}
