#!/usr/bin/env swift
// Install's catalogue pictures (C5, Sven 2026-10-09: "every catalogue app shows a real icon"): fetches each entry's
// icon once and saves it as a 64 px PNG in Packaging/catalogue-icons/<id>.png, which build-app.sh copies into the app's
// Resources (CatalogueIcons reads them). An entry that already has its PNG is skipped; --force fetches them all again,
// `--only id,id` just those.
//
// Where a picture comes from, best first: the app itself when it is on this Mac (by bundle id or path; its own icon),
// the logo named for it in `elsewhere` (where its vendor's page wears none or another's), the App Store's artwork for
// its bundle id, a GitHub vendor's organisation avatar (a person's face is not a logo, so a
// personal account's repo goes to its homepage instead), the vendor page's apple-touch-icon or largest
// <link rel="icon">, then /apple-touch-icon.png and /favicon.ico at its root. Fonts keep their glyph (each is one more
// typeface, not an app), and a registry's page (PyPI, npm, crates.io) is the registry's logo, not the tool's, so is
// skipped. Nothing found leaves the entry on its glyph or letter tile, and the script says which.
//
//   swift Scripts/catalogue-icons.swift [--force] [--only id,id]
import AppKit
import Foundation

let root = URL(filePath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
let out = root.appending(path: "Packaging/catalogue-icons")
let args = CommandLine.arguments.dropFirst()
let force = args.contains("--force")
let only = args.firstIndex(of: "--only").flatMap { i in args.index(after: i) < args.endIndex ? Set(args[args.index(after: i)].split(separator: ",").map(String.init)) : nil }
let side = 64

struct Row: Decodable { let id: String, name: String, category: String, vendor: String; let bundle: String?, path: String?, paths: [String]? }
struct File: Decodable { let entries: [Row] }

let session: URLSession = {
    let c = URLSessionConfiguration.ephemeral
    c.timeoutIntervalForRequest = 15
    c.httpAdditionalHeaders = ["User-Agent": "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/26.0 Safari/605.1.15"]
    return URLSession(configuration: c)
}()

func get(_ url: URL) async -> Data? {
    guard let (data, response) = try? await session.data(from: url), (response as? HTTPURLResponse)?.statusCode == 200 else { return nil }
    return data
}

/// A picture at least 32 px on its long side, its largest representation (a favicon.ico holds several).
func picture(_ data: Data) -> NSImage? {
    guard let image = NSImage(data: data), image.isValid else { return nil }
    let pixels = image.representations.map { max($0.pixelsWide, $0.pixelsHigh) }.max() ?? 0
    // An SVG has no pixels of its own: its size in points is enough.
    let big = pixels >= 32 || (pixels <= 0 && max(image.size.width, image.size.height) >= 16)
    return big ? image : nil
}

func local(_ row: Row) -> NSImage? {
    if let bundle = row.bundle, let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundle) {
        return NSWorkspace.shared.icon(forFile: url.path)
    }
    let apps = ([row.path].compactMap(\.self) + (row.paths ?? [])).map { NSString(string: $0).expandingTildeInPath }.filter { $0.hasSuffix(".app") }
    return apps.first(where: FileManager.default.fileExists(atPath:)).map(NSWorkspace.shared.icon(forFile:))
}

func appStore(_ row: Row) async -> NSImage? {
    guard let bundle = storeBundle[row.id] ?? row.bundle,
          let data = await get(URL(string: "https://itunes.apple.com/lookup?bundleId=\(bundle)&entity=macSoftware")!),
          let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
          let first = (json["results"] as? [[String: Any]])?.first, let art = first["artworkUrl512"] as? String,
          let url = URL(string: art), let image = await get(url) else { return nil }
    return picture(image)
}

/// The page's own icons, apple-touch-icon first, then the largest by `sizes`.
let linkTag = try! Regex("<link\\b[^>]*>").ignoresCase()
let attributes = ["rel", "href", "sizes"].reduce(into: [String: Regex<AnyRegexOutput>]()) {
    $0[$1] = try! Regex("\($1)\\s*=\\s*[\"']([^\"']*)[\"']").ignoresCase()
}

func linked(_ html: String, base: URL) -> [URL] {
    let tags = html.matches(of: linkTag).map { String(html[$0.range]) }
    func attribute(_ tag: String, _ name: String) -> String? {
        guard let m = tag.firstMatch(of: attributes[name]!) else { return nil }
        return m.output[1].substring.map(String.init)
    }
    let icons = tags.compactMap { tag -> (url: URL, score: Int)? in
        guard let rel = attribute(tag, "rel")?.lowercased(), rel.contains("icon"), !rel.contains("mask"),
              let href = attribute(tag, "href"), let url = URL(string: href.replacingOccurrences(of: "&amp;", with: "&"), relativeTo: base)?.absoluteURL
        else { return nil }
        let size = attribute(tag, "sizes").flatMap { $0.split(separator: "x").first.flatMap { Int($0) } } ?? 0
        return (url, (rel.contains("apple-touch-icon") ? 1000 : 0) + size + (href.hasSuffix(".svg") ? 300 : 0))
    }
    return icons.sorted { $0.score > $1.score }.map(\.url)
}

/// Entries whose vendor page carries no usable icon, or one that is not theirs (Microsoft's four squares for Edge and
/// .NET, mdBook's default for rustup), and where their own logo is instead.
let elsewhere: [String: String] = ["emacs": "https://www.gnu.org/software/emacs/images/emacs.png",
                                   "retroarch": "https://github.com/libretro.png?size=128",
                                   "microsoft-edge": "https://github.com/MicrosoftEdge.png?size=128",
                                   "dotnet-sdk": "https://github.com/dotnet.png?size=128",
                                   "rustup": "https://github.com/rust-lang.png?size=128",
                                   "appcleaner": "https://static.macupdate.com/products/25276/m/phpjbmgvl-logo.png",
                                   "btop": "https://raw.githubusercontent.com/aristocratos/btop/main/Img/icon.png"]
/// Entries whose App Store artwork is found by another bundle id than their check's: Office by Word, its installed-check.
let storeBundle: [String: String] = ["microsoft-office": "com.microsoft.Word"]

/// Registries whose page icon is their own logo.
let registries: Set<String> = ["pypi.org", "www.npmjs.com", "npmjs.com", "crates.io"]

func json(_ url: URL) async -> [String: Any]? { await get(url).flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] } }

func web(_ row: Row) async -> NSImage? {
    guard var vendor = URL(string: row.vendor), let host = vendor.host(), !registries.contains(host) else { return nil }
    if host == "github.com", vendor.pathComponents.count >= 3 {
        let owner = vendor.pathComponents[1], repo = vendor.pathComponents[2]
        if await json(URL(string: "https://api.github.com/users/\(owner)")!)?["type"] as? String == "Organization",
           let data = await get(URL(string: "https://github.com/\(owner).png?size=128")!), let image = picture(data) { return image }
        guard let home = await json(URL(string: "https://api.github.com/repos/\(owner)/\(repo)")!)?["homepage"] as? String,
              let page = URL(string: home), page.scheme == "https", page.host() != "github.com" else { return nil }
        vendor = page
    }
    guard let host = vendor.host() else { return nil }
    var tries: [URL] = []
    if let page = await get(vendor), let html = String(data: page, encoding: .utf8) ?? String(data: page, encoding: .isoLatin1) {
        tries += linked(html, base: vendor)
    }
    tries += [URL(string: "https://\(host)/apple-touch-icon.png")!, URL(string: "https://\(host)/favicon.ico")!]
    for url in tries { if let data = await get(url), let image = picture(data) { return image } }
    return nil
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

/// A font keeps its glyph: each is one more typeface, not an app.
func skipped(_ row: Row) -> Bool { row.category == "Fonts" }

let rows = try JSONDecoder().decode(File.self, from: Data(contentsOf: root.appending(path: "Packaging/install-catalogue.json"))).entries
try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
var missing: [String] = []
for row in rows where only?.contains(row.id) ?? true {
    let file = out.appending(path: "\(row.id).png")
    if skipped(row) { try? FileManager.default.removeItem(at: file); continue }
    if !force, only == nil, FileManager.default.fileExists(atPath: file.path) { continue }
    var source = "this Mac"
    var image = local(row)
    if image == nil, let address = elsewhere[row.id], let data = await get(URL(string: address)!) { image = picture(data); source = "the web" }
    if image == nil { image = await appStore(row); source = "App Store" }
    if image == nil { image = await web(row); source = "the web" }
    guard let image, let data = png(image) else { missing.append(row.id); print("none   \(row.id)"); continue }
    try data.write(to: file)
    print("\(source.padding(toLength: 9, withPad: " ", startingAt: 0)) \(row.id) \(data.count) B")
}
let ids = Set(rows.map(\.id))
let files = try FileManager.default.contentsOfDirectory(at: out, includingPropertiesForKeys: [.fileSizeKey]).filter { $0.pathExtension == "png" }
let skippedCount = rows.filter(skipped).count
for stale in files where !ids.contains(stale.deletingPathExtension().lastPathComponent) { print("stale  \(stale.lastPathComponent) (no catalogue entry)") }
let bytes = files.reduce(0) { $0 + ((try? $1.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0) }
print("\(files.count) of \(rows.count - skippedCount) entries (fonts aside) have a picture, \(bytes) bytes in all\(missing.isEmpty ? "" : "; none for \(missing.joined(separator: ", "))")")
