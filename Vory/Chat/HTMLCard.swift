import os
import SwiftUI
import WebKit
import VoryCore

// A card the bot drew in HTML: a fenced ```html block in its reply renders as a web view
// instead of as code, so a bot can answer with a table, a chart or a small dashboard. Any
// bot can do it today; no gateway change is needed.
//
// The content comes from a model that may have read hostile pages, so the web view is walled
// off from the app: a non-persistent data store (no cookies or storage shared with anything),
// no script message handlers or other bridge, JavaScript on (chart libraries need it), only
// https subresources (a content rule list blocks the rest), no iframes, no media autoplay,
// and no navigation inside the card: a tapped link goes to the browser. Nothing of the
// gateway (its token least of all) is ever handed to the page, and the card can neither
// answer an approval nor send a message.

/// The pure parts of the card, kept apart from the views so they can be tested.
enum HTMLCard {
    /// Every navigation decision, so a card that moved can be explained from the log.
    static let log = Logger(subsystem: "dev.vory", category: "card")
    /// Whether a fenced block is a card: its language says html.
    static func isCard(language: String?) -> Bool {
        guard let l = language?.trimmingCharacters(in: .whitespaces).lowercased() else { return false }
        return l == "html" || l == "htm"
    }

    /// The page as loaded: the bot's HTML with Vory's look folded in (the system font and label
    /// colour, both colour schemes, images and tables that never exceed the width). A fragment
    /// is wrapped in a document; a whole document gets the same head additions.
    static func document(_ html: String, dark: Bool) -> String {
        let head = """
        <meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1">
        <meta name="color-scheme" content="\(dark ? "dark" : "light")">
        <style id="vory-card">
        :root { color-scheme: \(dark ? "dark" : "light"); }
        html, body { margin: 0; background: transparent; color: -apple-system-label; }
        body { padding: 12px; font: -apple-system-body; font-family: -apple-system, system-ui, sans-serif; line-height: 1.35; overflow-wrap: anywhere; }
        img, canvas, svg, video, table, pre { max-width: 100%; }
        table { border-collapse: collapse; } th, td { padding: 4px 8px; text-align: left; }
        a { color: -apple-system-blue; }
        </style>
        """
        let lower = html.lowercased()
        if let r = lower.range(of: "<head>") ?? lower.range(of: "<head ") {
            // A whole document: the additions go first in its head, so its own styles win.
            let afterTag = lower[r.lowerBound...].firstIndex(of: ">").map { lower.index(after: $0) } ?? r.upperBound
            var s = html
            s.insert(contentsOf: head, at: s.index(s.startIndex, offsetBy: lower.distance(from: lower.startIndex, to: afterTag)))
            return s
        }
        if lower.contains("<html") {
            if let r = lower.range(of: "<body") {
                var s = html
                s.insert(contentsOf: "<head>\(head)</head>", at: s.index(s.startIndex, offsetBy: lower.distance(from: lower.startIndex, to: r.lowerBound)))
                return s
            }
            return "<!doctype html><html><head>\(head)</head><body>\(html)</body></html>"
        }
        return "<!doctype html><html><head>\(head)</head><body>\(html)</body></html>"
    }

    /// Where a navigation may go. Only the card's own document stays inside it (loaded from a
    /// string, so its URL is about:blank: the first time, and again when the appearance
    /// changes and the document is made anew); a link or any other top-level navigation
    /// leaves for the browser (https, http or mail), and frames are never loaded.
    enum Navigation: Equatable { case allow, openOutside, block }
    /// `userLink`: the navigation came from a link the person activated. Anything the page does
    /// on its own (a script setting location, a meta refresh, a form, a redirect) goes nowhere:
    /// a card must never load another page inside the chat.
    static func navigation(to url: URL?, isMainFrame: Bool, userLink: Bool = true) -> Navigation {
        guard isMainFrame else { return .block }
        if url == nil || url?.absoluteString == "about:blank" { return .allow }
        guard userLink, let url, let scheme = url.scheme?.lowercased() else { return .block }
        return ["https", "http", "mailto"].contains(scheme) ? .openOutside : .block
    }

    /// What the card's own menu offers. On the Mac the web view owns the right-click, so a
    /// SwiftUI context menu over it never opens; the view's menu is replaced with these.
    struct Actions {
        var full: () -> Void
        /// Turns the card back into its code block; nil where the thread does not offer it.
        var showSource: (() -> Void)?
        var copy: () -> Void
    }

    /// Subresource loads the page may make: https only. Plain http, file, ws and the rest are
    /// blocked before any request leaves the device.
    static let ruleListJSON = """
    [
      {"trigger": {"url-filter": "^http://"}, "action": {"type": "block"}},
      {"trigger": {"url-filter": "^ws://"}, "action": {"type": "block"}},
      {"trigger": {"url-filter": "^wss://"}, "action": {"type": "block"}},
      {"trigger": {"url-filter": "^file://"}, "action": {"type": "block"}},
      {"trigger": {"url-filter": "^ftp://"}, "action": {"type": "block"}}
    ]
    """

    /// The compiled rule list, made once per process.
    @MainActor private static var ruleListTask: Task<WKContentRuleList?, Never>?
    @MainActor static func ruleList() async -> WKContentRuleList? {
        if let t = ruleListTask { return await t.value }
        let t = Task<WKContentRuleList?, Never> { @MainActor in
            await withCheckedContinuation { c in
                WKContentRuleListStore.default().compileContentRuleList(forIdentifier: "vory-card-https-only", encodedContentRuleList: ruleListJSON) { list, _ in
                    c.resume(returning: list)
                }
            }
        }
        ruleListTask = t
        return await t.value
    }

    /// The most a card may take of the screen in the thread; the rest is in Full Screen.
    @MainActor static var heightCap: CGFloat {
        #if os(iOS)
        return max(240, UIScreen.main.bounds.height * 0.6)
        #else
        return 480
        #endif
    }

    /// Opens a link the page asked for, outside the card.
    @MainActor static func openOutside(_ url: URL) {
        #if os(iOS)
        UIApplication.shared.open(url)
        #else
        NSWorkspace.shared.open(url)
        #endif
    }

    /// The configuration every card's web view gets.
    /// One non-persistent store for every card: nothing is kept past the process, and a thread
    /// with many cards does not hold a store each.
    @MainActor private static let store = WKWebsiteDataStore.nonPersistent()

    @MainActor static func configuration() -> WKWebViewConfiguration {
        let c = WKWebViewConfiguration()
        c.websiteDataStore = store
        c.defaultWebpagePreferences.allowsContentJavaScript = true
        c.mediaTypesRequiringUserActionForPlayback = .all
        c.suppressesIncrementalRendering = false
        #if os(iOS)
        c.allowsInlineMediaPlayback = true
        c.allowsPictureInPictureMediaPlayback = false
        #endif
        return c
    }
}

/// The card in the thread: sized to its content up to the cap, a loading state until the page
/// is in, a button to open it full screen, and Show source / Copy HTML in its menu.
struct HTMLCardView: View {
    var html: String
    /// The thread's Show Source, for the card's own menu.
    var onShowSource: (() -> Void)? = nil
    @Environment(\.colorScheme) private var scheme
    @State private var height: CGFloat = 96
    @State private var loaded = false
    @State private var full = false

    var body: some View {
        let cap = HTMLCard.heightCap
        let actions = HTMLCard.Actions(full: { full = true }, showSource: onShowSource, copy: { UIPasteboard.general.string = html })
        ZStack(alignment: .topLeading) {
            HTMLWebView(document: HTMLCard.document(html, dark: scheme == .dark), scrolls: false, height: $height, loaded: $loaded, actions: actions)
                .frame(height: min(max(height, 48), cap))
                .opacity(loaded ? 1 : 0.01)
            if !loaded {
                HStack(spacing: 8) { ProgressView().controlSize(.small); Text("Drawing the card…").font(.caption).foregroundStyle(.secondary) }
                    .padding(12)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(.secondarySystemBackground), in: .rect(cornerRadius: 12))
        .clipShape(.rect(cornerRadius: 12))
        .overlay(alignment: .topTrailing) {
            Button { full = true } label: {
                Image(systemName: "arrow.up.left.and.arrow.down.right").font(.caption.weight(.semibold))
                    .padding(6).background(.thinMaterial, in: .circle)
            }
            .buttonStyle(.plain).padding(6)
            .accessibilityLabel("Open the card full screen")
            .opacity(loaded ? 1 : 0)
        }
        .overlay(alignment: .bottom) {
            // The card runs past the cap: a hint that Full Screen has the rest.
            if loaded, height > cap {
                LinearGradient(colors: [.clear, Color(.secondarySystemBackground)], startPoint: .top, endPoint: .bottom).frame(height: 28).allowsHitTesting(false)
            }
        }
        .animation(.snappy, value: loaded)
        .sheet(isPresented: $full) { HTMLCardSheet(html: html).sheetFrame(.wide) }
    }
}

/// The card on its own, scrolling, with its source a toggle away.
struct HTMLCardSheet: View {
    var html: String
    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var scheme
    @State private var height: CGFloat = 0
    @State private var loaded = false
    @State private var source = false

    var body: some View {
        NavigationStack {
            Group {
                if source {
                    ScrollView {
                        Text(html).font(.system(.footnote, design: .monospaced)).textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading).padding()
                    }
                } else {
                    HTMLWebView(document: HTMLCard.document(html, dark: scheme == .dark), scrolls: true, height: $height, loaded: $loaded)
                        .ignoresSafeArea(edges: .bottom)
                }
            }
            .navigationTitle("Card")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Done") { dismiss() } }
                ToolbarItem(placement: .primaryAction) {
                    Menu {
                        Button { source.toggle() } label: { Label(source ? "Show Card" : "Show Source", systemImage: source ? "rectangle.on.rectangle" : "chevron.left.forwardslash.chevron.right") }
                        Button { UIPasteboard.general.string = html } label: { Label("Copy HTML", systemImage: "doc.on.doc") }
                    } label: { Label("Card options", systemImage: "ellipsis.circle") }
                }
            }
        }
    }
}

/// The web view itself, one per card, with the policies above in its coordinator. The height
/// is read back from the page after it loads (and again as scripts finish drawing), not pushed
/// by the page: a message handler would be a bridge into the app.
struct HTMLWebView {
    var document: String
    var scrolls: Bool
    @Binding var height: CGFloat
    @Binding var loaded: Bool
    /// The card's menu (the Mac's right-click and ⌘-click); nil in the sheet, which has its own.
    var actions: HTMLCard.Actions? = nil

    @MainActor final class Coordinator: NSObject, WKNavigationDelegate, WKUIDelegate {
        var parent: HTMLWebView
        var loadedDocument = ""
        var measuring: Task<Void, Never>?
        init(_ parent: HTMLWebView) { self.parent = parent }

        func load(into web: WKWebView) {
            guard loadedDocument != parent.document else { return }
            loadedDocument = parent.document
            let doc = parent.document
            Task { @MainActor in
                if let list = await HTMLCard.ruleList() { web.configuration.userContentController.add(list) }
                web.loadHTMLString(doc, baseURL: nil)
            }
        }

        // The async form of the requirement: the closure form, written without the closure's
        // main-actor mark, only "nearly matched" it, so WebKit never saw the method and let every
        // navigation through (a tapped link loaded its page inside the card).
        func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction) async -> WKNavigationActionPolicy {
            let url = navigationAction.request.url
            let decision = HTMLCard.navigation(to: url, isMainFrame: navigationAction.targetFrame?.isMainFrame ?? true,
                                               userLink: navigationAction.navigationType == .linkActivated)
            HTMLCard.log.notice("card navigation \(url?.absoluteString ?? "nil", privacy: .public) type \(navigationAction.navigationType.rawValue): \(String(describing: decision), privacy: .public)")
            switch decision {
            case .allow: return .allow
            case .openOutside: if let url { HTMLCard.openOutside(url) }; return .cancel
            case .block: return .cancel
            }
        }

        func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration, for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
            // window.open and target=_blank: outside when the person clicked, never a second web view.
            if let u = navigationAction.request.url,
               HTMLCard.navigation(to: u, isMainFrame: true, userLink: navigationAction.navigationType == .linkActivated) == .openOutside { HTMLCard.openOutside(u) }
            return nil
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            measure(webView)
        }

        /// The page's height now, and again as its scripts finish drawing (a chart library
        /// lays out after load): read, never pushed.
        func measure(_ web: WKWebView) {
            measuring?.cancel()
            measuring = Task { @MainActor [weak self, weak web] in
                for delay in [0, 250, 800, 2000, 4000] {
                    if delay > 0 { try? await Task.sleep(for: .milliseconds(delay)) }
                    guard !Task.isCancelled, let self, let web else { return }
                    let h = try? await web.evaluateJavaScript("Math.ceil(Math.max(document.documentElement.scrollHeight, document.body ? document.body.scrollHeight : 0))")
                    if let n = (h as? NSNumber)?.doubleValue ?? (h as? Double), n > 0 {
                        let rounded = CGFloat(min(max(n, 24), 6000))
                        if abs(rounded - parent.height) > 1 { parent.height = rounded }
                    }
                    if !parent.loaded { parent.loaded = true }
                }
            }
        }
    }

    @MainActor func makeCoordinator() -> Coordinator { Coordinator(self) }

    @MainActor func makeWebView(_ coordinator: Coordinator) -> WKWebView {
        #if os(iOS)
        let web = WKWebView(frame: .zero, configuration: HTMLCard.configuration())
        web.isOpaque = false
        web.backgroundColor = .clear
        web.scrollView.backgroundColor = .clear
        web.scrollView.isScrollEnabled = scrolls
        web.scrollView.bounces = scrolls
        #else
        let web = CardWebView(frame: .zero, configuration: HTMLCard.configuration())
        web.scrolls = scrolls
        web.actions = actions
        web.setValue(false, forKey: "drawsBackground")
        #endif
        web.navigationDelegate = coordinator
        web.uiDelegate = coordinator
        web.allowsLinkPreview = false
        web.allowsBackForwardNavigationGestures = false
        coordinator.load(into: web)
        return web
    }

    @MainActor func update(_ web: WKWebView, _ coordinator: Coordinator) {
        coordinator.parent = self
        coordinator.load(into: web)
        #if os(iOS)
        web.scrollView.isScrollEnabled = scrolls
        #else
        if let card = web as? CardWebView { card.scrolls = scrolls; card.actions = actions }
        #endif
    }
}

#if os(macOS)
/// The Mac's web view for a card. In the thread the wheel scrolls the thread, not the card
/// (the card is sized to its content, and what runs past the cap is in Full Screen); in the
/// sheet the card scrolls itself. The right-click menu is the card's own, not WebKit's, and
/// ⌘-click opens the card full screen.
final class CardWebView: WKWebView {
    var scrolls = false
    var actions: HTMLCard.Actions?

    override func scrollWheel(with event: NSEvent) {
        if scrolls { super.scrollWheel(with: event) } else { nextResponder?.scrollWheel(with: event) }
    }

    override func mouseDown(with event: NSEvent) {
        if event.modifierFlags.contains(.command), let actions { actions.full(); return }
        super.mouseDown(with: event)
    }

    override func willOpenMenu(_ menu: NSMenu, with event: NSEvent) {
        guard let actions else { super.willOpenMenu(menu, with: event); return }
        menu.removeAllItems()
        menu.addItem(withTitle: "Open Full Screen", action: #selector(openFull), keyEquivalent: "").target = self
        if actions.showSource != nil { menu.addItem(withTitle: "Show Source", action: #selector(showSource), keyEquivalent: "").target = self }
        menu.addItem(withTitle: "Copy HTML", action: #selector(copyHTML), keyEquivalent: "").target = self
    }

    @objc private func openFull() { actions?.full() }
    @objc private func showSource() { actions?.showSource?() }
    @objc private func copyHTML() { actions?.copy() }
}
#endif

#if os(iOS)
extension HTMLWebView: UIViewRepresentable {
    func makeUIView(context: Context) -> WKWebView { makeWebView(context.coordinator) }
    func updateUIView(_ web: WKWebView, context: Context) { update(web, context.coordinator) }
    static func dismantleUIView(_ web: WKWebView, coordinator: Coordinator) { coordinator.measuring?.cancel(); web.stopLoading() }
}
#else
extension HTMLWebView: NSViewRepresentable {
    func makeNSView(context: Context) -> WKWebView { makeWebView(context.coordinator) }
    func updateNSView(_ web: WKWebView, context: Context) { update(web, context.coordinator) }
    static func dismantleNSView(_ web: WKWebView, coordinator: Coordinator) { coordinator.measuring?.cancel(); web.stopLoading() }
}
#endif
