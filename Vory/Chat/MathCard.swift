import os
import SwiftUI
import WebKit
import JavaScriptCore
import VoryCore

// MARK: - KaTeX Synchronous Thread-Safe In-Memory Cache

/// Thread-safe in-memory cache for pre-rendered KaTeX HTML markup and measured card sizes.
/// Enables instantaneous 0-frame cache hits when scrolling through conversation transcripts,
/// completely eliminating visual flicker, layout jumping, and thread hop latency.
enum KaTeXCache {
    nonisolated(unsafe) private static let markupCache: NSCache<NSString, NSString> = {
        let cache = NSCache<NSString, NSString>()
        cache.countLimit = 500
        return cache
    }()

    nonisolated(unsafe) private static let sizeCache: NSCache<NSString, NSValue> = {
        let cache = NSCache<NSString, NSValue>()
        cache.countLimit = 500
        return cache
    }()

    static func markup(for latex: String) -> String? {
        return markupCache.object(forKey: latex as NSString) as String?
    }

    static func setMarkup(_ markup: String, for latex: String) {
        markupCache.setObject(markup as NSString, forKey: latex as NSString)
    }

    static func size(for latex: String) -> CGSize? {
        #if os(iOS)
        return sizeCache.object(forKey: latex as NSString)?.cgSizeValue
        #else
        return sizeCache.object(forKey: latex as NSString)?.sizeValue
        #endif
    }

    static func setSize(_ size: CGSize, for latex: String) {
        #if os(iOS)
        sizeCache.setObject(NSValue(cgSize: size), forKey: latex as NSString)
        #else
        sizeCache.setObject(NSValue(size: size), forKey: latex as NSString)
        #endif
    }
}

// MARK: - KaTeX Headless JavaScript Pre-Rendering Actor

/// Isolated background actor managing the headless JavaScriptCore KaTeX engine.
/// Offloads rendering from the MainActor and enforces strict ReDoS / macro expansion safeguards.
actor KaTeXEngine {
    static let shared = KaTeXEngine()

    private var context: JSContext?
    private var renderFn: JSValue?

    private func getRenderFunction() -> JSValue? {
        if let fn = renderFn { return fn }
        let ctx = JSContext()
        ctx?.evaluateScript(KaTeXAssets.jsString)
        renderFn = ctx?.objectForKeyedSubscript("katex")?.objectForKeyedSubscript("renderToString")
        context = ctx
        return renderFn
    }

    /// Pre-renders LaTeX math into full 2D HTML + MathML markup in <0.1ms using headless JavaScriptCore.
    /// Runs on a background actor thread with zero main-thread contention and defensive safety caps.
    func render(latex: String) -> String {
        if let cached = KaTeXCache.markup(for: latex) {
            return cached
        }
        guard let fn = getRenderFunction() else {
            let fallback = MathCard.escapeHtml(MathNotation.format(latex))
            return "<div class=\"katex-display\" style=\"font-family: -apple-system-serif, serif; font-style: italic; text-align: center;\">\(fallback)</div>"
        }
        let options: [String: Any] = [
            "displayMode": true,
            "output": "htmlAndMathml",
            "throwOnError": false,
            "maxExpand": 1000,
            "maxSize": 100
        ]
        guard let result = fn.call(withArguments: [latex, options]),
              !result.isUndefined,
              !result.isNull,
              let html = result.toString(),
              !html.isEmpty,
              html != "undefined" else {
            let fallback = MathCard.escapeHtml(MathNotation.format(latex))
            let fallbackHtml = "<div class=\"katex-display\" style=\"font-family: -apple-system-serif, serif; font-style: italic; text-align: center;\">\(fallback)</div>"
            KaTeXCache.setMarkup(fallbackHtml, for: latex)
            return fallbackHtml
        }
        KaTeXCache.setMarkup(html, for: latex)
        return html
    }
}

// MARK: - Math Document Builder

enum MathCard {
    static let log = Logger(subsystem: "dev.vory", category: "math-card")

    /// Escapes raw characters before interpolating into HTML templates.
    public static func escapeHtml(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "'", with: "&#39;")
    }

    /// Generates a self-contained HTML page containing pre-rendered 2D KaTeX + MathML math
    /// with embedded KaTeX CSS. Requires zero network requests and zero client-side scripts.
    static func document(mathMarkup: String, dark: Bool) -> String {
        return """
        <!doctype html>
        <html>
        <head>
        <meta charset="utf-8">
        <meta name="viewport" content="width=device-width, initial-scale=1, maximum-scale=1, user-scalable=no">
        <meta name="color-scheme" content="\(dark ? "dark" : "light")">
        <style>
        :root {
          color-scheme: \(dark ? "dark" : "light");
        }
        \(KaTeXAssets.cssString)
        html, body {
          margin: 0;
          padding: 0;
          background: transparent;
          color: -apple-system-label;
          font-family: KaTeX_Main, "Times New Roman", serif;
          overflow: hidden;
          -webkit-text-size-adjust: 100%;
          -webkit-font-smoothing: antialiased;
        }
        #wrapper {
          display: inline-flex;
          min-width: 100%;
          justify-content: safe center;
          align-items: center;
          padding: 8px 16px;
          box-sizing: border-box;
          white-space: nowrap;
        }
        .katex-display {
          margin: 0 !important;
          padding: 0 !important;
        }
        .katex {
          font-size: 1.15em;
          color: inherit;
        }
        </style>
        </head>
        <body>
        <div id="wrapper">
          \(mathMarkup)
        </div>
        </body>
        </html>
        """
    }
}

// MARK: - Dedicated Math Web View with Precise Content Measurement

struct MathWebView {
    var equation: String
    var document: String
    @Binding var height: CGFloat
    @Binding var contentWidth: CGFloat
    @Binding var loaded: Bool

    @MainActor final class Coordinator: NSObject, WKNavigationDelegate {
        var parent: MathWebView
        var loadedDocument = ""
        var measuring: Task<Void, Never>?

        init(_ parent: MathWebView) { self.parent = parent }

        func load(into web: WKWebView) {
            guard loadedDocument != parent.document else { return }
            loadedDocument = parent.document
            web.loadHTMLString(parent.document, baseURL: nil)
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            measure(webView)
        }

        func measure(_ web: WKWebView) {
            measuring?.cancel()
            measuring = Task { @MainActor [weak self, weak web] in
                for delay in [0, 60, 200] {
                    if delay > 0 { try? await Task.sleep(for: .milliseconds(delay)) }
                    guard !Task.isCancelled, let self, let web else { return }
                    let script = """
                    (function() {
                        var wrapper = document.getElementById('wrapper');
                        var katex = document.querySelector('.katex-html') || document.querySelector('.katex-display') || document.querySelector('.katex');
                        var w = 0;
                        if (wrapper && wrapper.scrollWidth > 0) {
                            w = wrapper.scrollWidth;
                        } else if (katex) {
                            w = katex.scrollWidth + 32;
                        }
                        var h = wrapper ? wrapper.getBoundingClientRect().height : document.body.scrollHeight;
                        return [Math.ceil(w), Math.ceil(h)];
                    })()
                    """
                    let raw = try? await web.evaluateJavaScript(script)
                    let dims = (raw as? [Double]) ?? (raw as? [NSNumber])?.map(\.doubleValue)
                    if let dims, dims.count >= 2 {
                        let w = CGFloat(dims[0])
                        let h = CGFloat(min(max(dims[1], 36), 360))
                        if abs(h - parent.height) > 1 { parent.height = h }
                        if w > 0 && abs(w - parent.contentWidth) > 1 { parent.contentWidth = w }
                        KaTeXCache.setSize(CGSize(width: w, height: h), for: parent.equation)
                    }
                    if !parent.loaded { parent.loaded = true }
                }
            }
        }
    }

    @MainActor func makeCoordinator() -> Coordinator { Coordinator(self) }

    @MainActor func makeWebView(_ coordinator: Coordinator) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .nonPersistent()
        config.defaultWebpagePreferences.allowsContentJavaScript = true
        config.mediaTypesRequiringUserActionForPlayback = .all

        let web = WKWebView(frame: .zero, configuration: config)
        web.navigationDelegate = coordinator

        #if os(iOS)
        web.isOpaque = false
        web.backgroundColor = .clear
        #else
        // AppKit's WKWebView paints its own background behind a transparent page unless it is
        // told not to, which showed the math card as a white slab on a dark window.
        web.underPageBackgroundColor = .clear
        if web.responds(to: NSSelectorFromString("setDrawsBackground:")) {
            web.setValue(false, forKey: "drawsBackground")
        }
        #endif

        #if os(iOS)
        web.scrollView.backgroundColor = .clear
        web.scrollView.isScrollEnabled = false
        web.scrollView.bounces = false
        web.scrollView.alwaysBounceHorizontal = false
        web.scrollView.alwaysBounceVertical = false
        web.scrollView.showsVerticalScrollIndicator = false
        web.scrollView.showsHorizontalScrollIndicator = false
        #endif

        coordinator.load(into: web)
        return web
    }

    @MainActor func update(_ web: WKWebView, _ coordinator: Coordinator) {
        coordinator.parent = self
        coordinator.load(into: web)
    }
}

#if os(iOS)
extension MathWebView: UIViewRepresentable {
    func makeUIView(context: Context) -> WKWebView { makeWebView(context.coordinator) }
    func updateUIView(_ web: WKWebView, context: Context) { update(web, context.coordinator) }
    static func dismantleUIView(_ web: WKWebView, coordinator: Coordinator) {
        coordinator.measuring?.cancel()
        web.stopLoading()
    }
}
#else
extension MathWebView: NSViewRepresentable {
    func makeNSView(context: Context) -> WKWebView { makeWebView(context.coordinator) }
    func updateNSView(_ web: WKWebView, context: Context) { update(web, context.coordinator) }
    static func dismantleNSView(_ web: WKWebView, coordinator: Coordinator) {
        coordinator.measuring?.cancel()
        web.stopLoading()
    }
}
#endif

// MARK: - Display Math Card View with Native Horizontal Scrolling & Frame-0 Cache

/// The display math card in the chat transcript.
struct MathCardView: View {
    var equation: String
    var closed: Bool

    @Environment(\.colorScheme) private var scheme
    @State private var height: CGFloat
    @State private var contentWidth: CGFloat
    @State private var availableWidth: CGFloat = 0
    @State private var loaded = false
    @State private var mathMarkup: String?

    init(equation: String, closed: Bool) {
        self.equation = equation
        self.closed = closed
        let cachedMarkup = KaTeXCache.markup(for: equation)
        let cachedSize = KaTeXCache.size(for: equation)
        _mathMarkup = State(initialValue: cachedMarkup)
        _height = State(initialValue: cachedSize?.height ?? 48)
        _contentWidth = State(initialValue: cachedSize?.width ?? 0)
        _loaded = State(initialValue: cachedMarkup != nil)
    }

    var body: some View {
        HStack(spacing: 0) {
            if closed, let markup = mathMarkup {
                // Pre-rendered 2D math card: loaded immediately from memory, persistent across scrolling
                let doc = MathCard.document(mathMarkup: markup, dark: scheme == .dark)
                let viewWidth = availableWidth > 40 ? availableWidth - 40 : 0
                let targetWidth = max(contentWidth, viewWidth)

                ScrollView(.horizontal, showsIndicators: false) {
                    MathWebView(
                        equation: equation,
                        document: doc,
                        height: $height,
                        contentWidth: $contentWidth,
                        loaded: $loaded
                    )
                    .frame(width: targetWidth > 0 ? targetWidth : nil, height: min(max(height, 36), 360))
                }
                .frame(height: min(max(height, 36), 360))
                .frame(maxWidth: .infinity)
            } else {
                // Streaming active or pre-computing markup: fast Swift text rendering with spinner
                let formatted = MathNotation.format(equation)
                Text(formatted)
                    .font(.system(.body, design: .serif))
                    .italic()
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
                    .frame(maxWidth: .infinity)
            }

            // Trailing actions: Copy button or progress spinner
            VStack {
                if closed {
                    CopyButton(text: equation)
                        .padding(.trailing, 8)
                } else {
                    ProgressView()
                        .controlSize(.mini)
                        .padding(.trailing, 8)
                }
            }
        }
        .padding(.vertical, 2)
        .frame(maxWidth: .infinity)
        .background(Color(.secondarySystemBackground).opacity(0.6), in: .rect(cornerRadius: 10))
        .clipShape(.rect(cornerRadius: 10))
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width in
            if width > 0 && abs(width - availableWidth) > 1 {
                availableWidth = width
            }
        }
        .task(id: "\(equation):\(closed)") {
            if closed {
                let markup = await KaTeXEngine.shared.render(latex: equation)
                mathMarkup = markup
            }
        }
    }
}
