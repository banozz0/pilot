#!/usr/bin/env swift
// The recommended web apps' brand icons (Sven 2026-10-10: "each with its real brand icon"): fetches each site's own icon
// once and saves it as a 128 px PNG in Packaging/webapp-icons/<id>.png, which build-app.sh copies into the app's
// Resources (WebAppIdea.icon reads them). An id that already has its PNG is skipped; --force fetches them all again,
// `--only id,id` just those. The ids and sites are WebAppIdea.all's (Sources/Pilot/UI/WebAppsSettingsView.swift);
// FillPagesTests checks every idea has its PNG.
//
// Where a picture comes from, best first: the address in `own` (where the logged-out page wears another product's
// icon, as Google's sign-in does), the page's apple-touch-icon, its web app manifest's largest icon, its largest
// <link rel="icon">, then /apple-touch-icon.png and /favicon.ico at its root. The script prints each icon's address.
//
//   swift Scripts/webapp-icons.swift [--force] [--only id,id]
import AppKit
import Foundation

let root = URL(filePath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
let out = root.appending(path: "Packaging/webapp-icons")
let args = CommandLine.arguments.dropFirst()
let force = args.contains("--force")
let only = args.firstIndex(of: "--only").flatMap { i in args.index(after: i) < args.endIndex ? Set(args[args.index(after: i)].split(separator: ",").map(String.init)) : nil }
let side = 128

/// WebAppIdea.all's ids and pages, in its order.
let sites: [(id: String, page: String)] = [
    ("gmail", "https://mail.google.com"), ("google-calendar", "https://calendar.google.com"), ("google-drive", "https://drive.google.com"),
    ("whatsapp", "https://web.whatsapp.com"), ("slack", "https://app.slack.com"),
    ("discord", "https://discord.com/app"), ("x", "https://x.com"), ("youtube", "https://www.youtube.com"),
    ("spotify", "https://open.spotify.com"), ("chatgpt", "https://chatgpt.com"), ("claude", "https://claude.ai"),
    ("notion", "https://www.notion.so"), ("linear", "https://linear.app"), ("figma", "https://www.figma.com"),
    ("github", "https://github.com"),
]

/// Google's apps send a logged-out visitor to a sign-in or marketing page with Google's own icon; each app's own is on
/// Google's product branding host, the one its signed-in page links.
let own: [String: String] = [
    "gmail": "https://www.gstatic.com/images/branding/product/1x/gmail_2020q4_512dp.png",
    "google-calendar": "https://www.gstatic.com/images/branding/product/1x/calendar_2020q4_512dp.png",
    "google-drive": "https://www.gstatic.com/images/branding/product/1x/drive_2020q4_512dp.png",
]

let session: URLSession = {
    let c = URLSessionConfiguration.ephemeral
    c.timeoutIntervalForRequest = 15
    c.httpAdditionalHeaders = ["User-Agent": "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/26.0 Safari/605.1.15"]
    return URLSession(configuration: c)
}()

func get(_ url: URL) async -> (data: Data, url: URL)? {
    guard let (data, response) = try? await session.data(from: url), let http = response as? HTTPURLResponse, http.statusCode == 200 else { return nil }
    return (data, http.url ?? url)
}

/// A picture at least 64 px on its long side, its largest representation (a favicon.ico holds several).
func picture(_ data: Data) -> NSImage? {
    guard let image = NSImage(data: data), image.isValid else { return nil }
    let pixels = image.representations.map { max($0.pixelsWide, $0.pixelsHigh) }.max() ?? 0
    // An SVG has no pixels of its own: its size in points is enough.
    let big = pixels >= 64 || (pixels <= 0 && max(image.size.width, image.size.height) >= 16)
    return big ? image : nil
}

let linkTag = try! Regex("<link\\b[^>]*>").ignoresCase()
let attributes = ["rel", "href", "sizes"].reduce(into: [String: Regex<AnyRegexOutput>]()) {
    $0[$1] = try! Regex("\($1)\\s*=\\s*[\"']([^\"']*)[\"']").ignoresCase()
}

func attribute(_ tag: String, _ name: String) -> String? {
    guard let m = tag.firstMatch(of: attributes[name]!) else { return nil }
    return m.output[1].substring.map(String.init)
}

/// The page's own icons, apple-touch-icon first, then the manifest's and the <link rel="icon">s by size.
func linked(_ html: String, base: URL) async -> [URL] {
    let tags = html.matches(of: linkTag).map { String(html[$0.range]) }
    func url(_ href: String) -> URL? { URL(string: href.replacingOccurrences(of: "&amp;", with: "&"), relativeTo: base)?.absoluteURL }
    var icons: [(url: URL, score: Int)] = tags.compactMap { tag in
        guard let rel = attribute(tag, "rel")?.lowercased(), rel.contains("icon"), !rel.contains("mask"),
              let href = attribute(tag, "href"), let url = url(href) else { return nil }
        let size = attribute(tag, "sizes").flatMap { $0.split(separator: "x").first.flatMap { Int($0) } } ?? 0
        return (url, (rel.contains("apple-touch-icon") ? 1000 : 0) + size + (href.hasSuffix(".svg") ? 300 : 0))
    }
    if let tag = tags.first(where: { attribute($0, "rel")?.lowercased() == "manifest" }), let href = attribute(tag, "href"), let at = url(href),
       let (data, _) = await get(at), let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
       let list = json["icons"] as? [[String: Any]] {
        for icon in list where (icon["purpose"] as? String ?? "any").contains("any") {
            guard let src = icon["src"] as? String, let u = URL(string: src, relativeTo: at)?.absoluteURL else { continue }
            let size = (icon["sizes"] as? String)?.split(separator: " ").compactMap { $0.split(separator: "x").first.flatMap { Int($0) } }.max() ?? 0
            icons.append((u, 500 + size))
        }
    }
    return icons.sorted { $0.score > $1.score }.map(\.url)
}

/// The picture drawn into `side` px, centred and whole.
func png(_ image: NSImage) -> Data? {
    guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: side, pixelsHigh: side, bitsPerSample: 8, samplesPerPixel: 4,
                                     hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { return nil }
    rep.size = NSSize(width: side, height: side)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    NSGraphicsContext.current?.imageInterpolation = .high
    let s = image.size, scale = min(CGFloat(side) / max(s.width, 1), CGFloat(side) / max(s.height, 1))
    let w = s.width * scale, h = s.height * scale
    image.draw(in: NSRect(x: (CGFloat(side) - w) / 2, y: (CGFloat(side) - h) / 2, width: w, height: h))
    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])
}

func icon(_ id: String, _ page: URL) async -> (NSImage, URL)? {
    var tries: [URL] = own[id].flatMap(URL.init(string:)).map { [$0] } ?? []
    if tries.isEmpty, let (data, landed) = await get(page), let html = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1) {
        tries += await linked(html, base: landed)
    }
    if own[id] == nil, let host = page.host() { tries += [URL(string: "https://\(host)/apple-touch-icon.png")!, URL(string: "https://\(host)/favicon.ico")!] }
    for url in tries { if let (data, _) = await get(url), let image = picture(data) { return (image, url) } }
    return nil
}

try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
var missing: [String] = []
for (id, page) in sites where only?.contains(id) ?? true {
    let file = out.appending(path: "\(id).png")
    if !force, only == nil, FileManager.default.fileExists(atPath: file.path) { continue }
    guard let (image, from) = await icon(id, URL(string: page)!), let data = png(image) else { missing.append(id); print("none   \(id)"); continue }
    try data.write(to: file)
    print("\(id) \(data.count) B from \(from.absoluteString)")
}
let files = try FileManager.default.contentsOfDirectory(at: out, includingPropertiesForKeys: [.fileSizeKey]).filter { $0.pathExtension == "png" }
for stale in files where !sites.contains(where: { $0.id == stale.deletingPathExtension().lastPathComponent }) { print("stale  \(stale.lastPathComponent)") }
let bytes = files.reduce(0) { $0 + ((try? $1.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0) }
print("\(files.count) of \(sites.count) web apps have an icon, \(bytes) bytes in all\(missing.isEmpty ? "" : "; none for \(missing.joined(separator: ", "))")")
