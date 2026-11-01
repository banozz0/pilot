import AppKit
import PilotCore
import SwiftUI
import WebKit

/// A Markdown file as GitHub shows it (Pilot 1.0.2), the one renderer for the file previews: Apps › Repos, Configs and
/// its Agents tab, and Show preview (FilePreviewWindow). MarkdownHTML makes the page; WebKit lays it out with JavaScript
/// off and a CSP that loads nothing, local images inline as data URIs and remote ones as their alt text, so the page
/// never reaches the network. A link opens in the browser; the page never navigates, and a force click previews none.
/// Each preview has a WebContent process of its own, never the desk pages': a file from a cloned repo is not trusted
/// (Pilot 1.0.2 review), so a crash there ends only it, and it says so. The process and the render go with the preview:
/// nothing is kept. A file past MarkdownHTML.renderCap, or one whose render spends its budget (MarkdownHTML.Budget),
/// shows its source instead, with a line saying why: decided here, so no host can skip it. The host's Rendered / Source
/// toggle is bound in, so it reads Source then, and Rendered goes back to it.
struct MarkdownPreview<Source: View>: View {
    let text: String
    /// The file, whose folder its relative images resolve from.
    let file: URL
    /// The folder no image may come from outside of: the repo's root, else the file's own folder.
    var root: URL?
    /// The host's toggle: Source picked, or forced by a file that cannot render.
    @Binding var showsSource: Bool
    /// The host's own view of the file's source.
    @ViewBuilder var source: () -> Source
    /// The text whose render ran out of budget.
    @State private var spent: String?

    var body: some View {
        let forced = spent == text || !MarkdownHTML.renders(text)
        if showsSource || forced {
            VStack(alignment: .leading, spacing: 0) {
                if forced { FinePrint(text: "Too big or too complex to render: showing its source.").padding(.horizontal, 12).padding(.vertical, 6) }
                source()
            }
            .onAppear { if forced { showsSource = true } }
            .onChange(of: showsSource) { if forced, !showsSource { showsSource = true } }
        } else {
            MarkdownWebView(text: text, file: file, root: root) { [text] in spent = text; showsSource = true }
        }
    }
}

/// MarkdownPreview's page: the WKWebView, its render and its navigation rules.
struct MarkdownWebView: NSViewRepresentable {
    let text: String
    let file: URL
    var root: URL?
    /// Told when the render spent its budget: the preview shows the source.
    let spent: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.defaultWebpagePreferences.allowsContentJavaScript = false
        config.preferences.isFraudulentWebsiteWarningEnabled = false
        config.websiteDataStore = .nonPersistent()
        let view = WKWebView(frame: .zero, configuration: config)
        view.allowsLinkPreview = false
        context.coordinator.seeThrough = WidgetWebView.clearBackground(view)
        view.navigationDelegate = context.coordinator
        view.setAccessibilityLabel("Markdown preview of \(file.lastPathComponent)")
        return view
    }

    func updateNSView(_ view: WKWebView, context: Context) {
        let coordinator = context.coordinator
        let style = context.environment.style
        if coordinator.css?.style != style { coordinator.css = (style, Self.css(Ink(style: style), solid: !coordinator.seeThrough)) }
        let css = coordinator.css!.page
        let shown = Shown(text: text, file: file, css: css)
        guard shown != coordinator.shown else { return }
        coordinator.shown = shown
        let (text, folder, root) = (text, file.deletingLastPathComponent(), root ?? file.deletingLastPathComponent())
        coordinator.cancel()
        // The render runs detached, its handle kept, so a closed preview or a new file stops it (the parse's budget sees
        // the cancel within 8,192 steps); the load waits on it.
        let render = Task.detached(priority: .userInitiated) {
            MarkdownHTML.page(text, css: css, images: MarkdownHTML.localImages(folder: folder, root: root))
        }
        coordinator.render = render
        let spent = spent
        coordinator.task = Task { [weak view] in
            let html = await render.value
            guard !Task.isCancelled, !render.isCancelled, let view else { return }
            guard let html else { spent(); return }
            view.loadHTMLString(html, baseURL: nil)
        }
    }

    static func dismantleNSView(_ view: WKWebView, coordinator: Coordinator) {
        coordinator.cancel()
        view.stopLoading()
        view.navigationDelegate = nil
    }

    struct Shown: Equatable { let text: String, file: URL, css: String }

    @MainActor
    final class Coordinator: NSObject, WKNavigationDelegate {
        var shown: Shown?
        /// The page's CSS and the style it was made for: made again only when the style changes.
        var css: (style: StyleTokens, page: String)?
        var render: Task<String?, Never>?
        var task: Task<Void, Never>?
        var seeThrough = false
        /// What a clicked web or mail link does: opens in its app; the E2E probe watches it instead.
        static var openLink: (URL) -> Void = { NSWorkspace.shared.open($0) }

        func cancel() {
            render?.cancel()
            task?.cancel()
        }

        /// The page's process died (a hostile picture, say): only this preview went with it; it says so on a page of its
        /// own rather than loading the file again.
        func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
            let css = css?.page ?? ""
            webView.loadHTMLString("<!doctype html><html><head><meta charset=\"utf-8\"><title>Could not show this file</title><style>\(css)</style></head><body><article class=\"markdown\">"
                                   + "<p>Pilot could not show this file. Pick Source to read it.</p></article></body></html>", baseURL: nil)
        }

        /// The page's own load and a jump to one of its anchors stay; a clicked web or mail link opens in its app; nothing
        /// else goes anywhere.
        func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction) async -> WKNavigationActionPolicy {
            guard let url = action.request.url else { return .cancel }
            if url.scheme == "about" { return action.navigationType == .other || url.fragment != nil ? .allow : .cancel }
            if action.navigationType == .linkActivated, ["http", "https", "mailto"].contains(url.scheme?.lowercased() ?? "") {
                Self.openLink(url)
            }
            return .cancel
        }
    }

    /// The page's look in the style's colours: GitHub's README layout at Pilot's reading size, its own background only
    /// where WebKit cannot draw none.
    static func css(_ ink: Ink, solid: Bool) -> String {
        let size = 13 * ink.style.scale
        let face = PilotFonts.shared.family(.ui).map { "\"\($0)\", " } ?? ""
        let mono = PilotFonts.shared.family(.mono).map { "\"\($0)\", " } ?? ""
        return """
        html, body { margin: 0; background: \(solid ? cssColor(ink.background) : "transparent"); }
        body { color: \(cssColor(ink.text)); font: \(size)px/1.6 \(face)-apple-system, system-ui, sans-serif; -webkit-font-smoothing: antialiased; word-wrap: break-word; }
        .markdown { padding: 16px 20px 28px; }
        .markdown > :first-child { margin-top: 0; }
        h1, h2, h3, h4, h5, h6 { font-weight: 600; line-height: 1.25; margin: 22px 0 12px; }
        h1 { font-size: 1.9em; padding-bottom: .3em; border-bottom: 1px solid \(cssColor(ink.line)); }
        h2 { font-size: 1.45em; padding-bottom: .3em; border-bottom: 1px solid \(cssColor(ink.line)); }
        h3 { font-size: 1.2em; } h4 { font-size: 1em; } h5 { font-size: .9em; } h6 { font-size: .85em; color: \(cssColor(ink.muted)); }
        p, ul, ol, dl, table, pre, blockquote, details, .alert { margin: 0 0 14px; }
        ul, ol { padding-left: 2em; } li + li { margin-top: .25em; } li > ul, li > ol { margin: .25em 0 0; }
        li.task { list-style: none; } li.task input { margin: 0 .4em 0 -1.4em; vertical-align: middle; }
        a { color: \(cssColor(ink.link)); text-decoration: none; } a:hover { text-decoration: underline; }
        code, kbd, pre, samp, tt { font-family: \(mono)ui-monospace, "SF Mono", Menlo, monospace; }
        code { font-size: .88em; padding: .15em .4em; border-radius: 5px; background: \(cssColor(ink.well)); }
        pre { padding: 12px 14px; border-radius: 8px; overflow: auto; background: \(cssColor(ink.well)); line-height: 1.45; }
        pre code { padding: 0; background: none; font-size: .9em; }
        kbd { font-size: .85em; padding: .1em .4em; border: 1px solid \(cssColor(ink.line)); border-radius: 5px; background: \(cssColor(ink.well)); }
        table { border-collapse: collapse; display: block; width: max-content; max-width: 100%; overflow: auto; }
        th, td { padding: 6px 13px; border: 1px solid \(cssColor(ink.line)); }
        th { font-weight: 600; } tbody tr:nth-child(2n) { background: \(cssColor(ink.well)); }
        blockquote { padding: 0 1em; color: \(cssColor(ink.muted)); border-left: 3px solid \(cssColor(ink.line)); margin-left: 0; margin-right: 0; }
        hr { height: 0; border: 0; border-top: 1px solid \(cssColor(ink.line)); margin: 22px 0; }
        img { max-width: 100%; height: auto; border-radius: 4px; }
        sub, sup { font-size: .75em; } sub { color: \(cssColor(ink.muted)); }
        details > summary { cursor: default; font-weight: 600; } details[open] > summary { margin-bottom: 10px; }
        .alt { display: inline-block; font-size: .8em; line-height: 1.5; padding: 0 .5em; margin: 1px 0; color: \(cssColor(ink.muted)); border: 1px solid \(cssColor(ink.line)); border-radius: 5px; }
        .alert { padding: 4px 1em; border-left: 3px solid \(cssColor(ink.accent)); }
        .alert-title { font-weight: 600; margin: 6px 0; color: \(cssColor(ink.accentText)); }
        .alert-tip { border-color: \(cssColor(ink.green)); } .alert-tip .alert-title { color: \(cssColor(ink.green)); }
        .alert-warning { border-color: \(cssColor(ink.yellow)); } .alert-warning .alert-title { color: \(cssColor(ink.yellow)); }
        .alert-caution { border-color: \(cssColor(ink.red)); } .alert-caution .alert-title { color: \(cssColor(ink.red)); }
        ::selection { background: \(cssColor(ink.selection)); }
        """
    }

    /// A colour as CSS's rgba(), in sRGB, its alpha kept (Color.rgb drops it).
    static func cssColor(_ color: Color) -> String {
        guard let c = NSColor(color).usingColorSpace(.sRGB) else { return "currentColor" }
        let byte = { (v: CGFloat) in Int((max(0, min(1, v)) * 255).rounded()) }
        return "rgba(\(byte(c.redComponent)), \(byte(c.greenComponent)), \(byte(c.blueComponent)), \(String(format: "%.3f", c.alphaComponent)))"
    }
}

/// Rendered or Source over a Markdown preview: the file as GitHub shows it, or its raw text one click away.
struct MarkdownModeToggle: View {
    @Binding var source: Bool

    var body: some View {
        ToolSegments(options: [(false, "Rendered"), (true, "Source")], label: "Show the file as", selection: $source)
    }
}
