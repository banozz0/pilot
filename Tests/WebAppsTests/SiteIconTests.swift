import AppKit
import Testing
@testable import WebApps

@Suite("Site icon")
struct SiteIconTests {
    let page = URL(string: "https://x.com/home")!
    let html = """
    <html><head>
    <link rel="icon" href="/favicon-32.png" sizes="32x32">
    <link rel='shortcut icon' href="//abs.twimg.com/favicon.ico">
    <link href="/touch-120.png" rel="apple-touch-icon" sizes="120x120">
    <LINK REL="apple-touch-icon" HREF="/touch-180.png" SIZES="180x180">
    <link rel="manifest" href="/manifest.json">
    </head></html>
    """
    let manifest = Data("""
    {"icons": [
      {"src": "/icon-192.png", "sizes": "192x192", "purpose": "any"},
      {"src": "icons/maskable-192.png", "sizes": "192x192", "purpose": "maskable"},
      {"src": "icons/maskable-512.png", "sizes": "512x512", "purpose": "any maskable"}
    ]}
    """.utf8)

    @Test("The manifest link is found and resolved against the page")
    func manifestLink() {
        #expect(SiteIcon.manifestURL(inHTML: html, page: page) == URL(string: "https://x.com/manifest.json"))
        #expect(SiteIcon.manifestURL(inHTML: "<html></html>", page: page) == nil)
    }

    @Test("Candidates run maskable, then apple-touch-icon, then the manifest's other icons, then favicon, biggest first")
    func order() {
        let candidates = SiteIcon.candidates(html: html, page: page, manifest: manifest,
                                             manifestURL: URL(string: "https://x.com/manifest.json")!)
        #expect(candidates.map(\.absoluteString) == [
            "https://x.com/icons/maskable-512.png",
            "https://x.com/icons/maskable-192.png",
            "https://x.com/touch-180.png",
            "https://x.com/touch-120.png",
            "https://x.com/icon-192.png",
            "https://x.com/favicon-32.png",
            "https://abs.twimg.com/favicon.ico",
            "https://x.com/favicon.ico",
        ])
    }

    @Test("A page with no icons still offers /favicon.ico")
    func bareFallback() {
        #expect(SiteIcon.candidates(html: "<html></html>", page: page, manifest: nil, manifestURL: nil)
            == [URL(string: "https://x.com/favicon.ico")!])
    }

    @Test("A site icon packs into an .icns that macOS reads back at 1024 pixels")
    func icns() throws {
        let red = NSImage(size: NSSize(width: 180, height: 180), flipped: false) { rect in
            NSColor.red.setFill(); rect.fill(); return true
        }
        let data = try SiteIcon.icns(from: red)
        let reps = try #require(NSImage(data: data)).representations
        #expect(reps.contains { $0.pixelsWide == 1024 })
        #expect(reps.contains { $0.pixelsWide == 16 })
    }
}
