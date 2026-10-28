import AppKit

/// Finds a site's icon and turns it into the stamped app's AppIcon.icns: the manifest's maskable icon first,
/// then apple-touch-icon, then the manifest's other icons, then the favicon (SPEC.md, the Web apps line).
public enum SiteIcon {
    struct Link { let rel: Set<String>; let href: String; let sizes: String? }

    public static func manifestURL(inHTML html: String, page: URL) -> URL? {
        links(in: html).first { $0.rel.contains("manifest") }.flatMap { URL(string: $0.href, relativeTo: page)?.absoluteURL }
    }

    /// Every icon worth trying, best first; the fetch takes the first one that decodes.
    public static func candidates(html: String, page: URL, manifest: Data?, manifestURL: URL?) -> [URL] {
        var maskable: [(URL, Int)] = [], other: [(URL, Int)] = []
        if let manifest, let manifestURL,
           let icons = (try? JSONSerialization.jsonObject(with: manifest) as? [String: Any])?["icons"] as? [[String: Any]] {
            for icon in icons {
                guard let src = icon["src"] as? String, let url = URL(string: src, relativeTo: manifestURL)?.absoluteURL else { continue }
                let purpose = Set(((icon["purpose"] as? String) ?? "any").split(separator: " ").map(String.init))
                let entry = (url, size(icon["sizes"] as? String))
                if purpose.contains("maskable") { maskable.append(entry) } else if purpose.contains("any") { other.append(entry) }
            }
        }
        let links = links(in: html)
        func linked(_ wanted: (Set<String>) -> Bool) -> [(URL, Int)] {
            links.filter { wanted($0.rel) }.compactMap { link in
                URL(string: link.href, relativeTo: page).map { ($0.absoluteURL, size(link.sizes)) }
            }
        }
        let touch = linked { !$0.isDisjoint(with: ["apple-touch-icon", "apple-touch-icon-precomposed"]) }
        let favicons = linked { $0.contains("icon") }
        let fallback = URL(string: "/favicon.ico", relativeTo: page)!.absoluteURL
        var seen = Set<URL>()
        return ([maskable, touch, other, favicons].flatMap(biggestFirst) + [fallback]).filter { seen.insert($0).inserted }
    }

    /// Fetches the page, its manifest and the best icon that decodes; nil when the site has none.
    public static func fetchICNS(for page: URL) async -> Data? {
        guard let html = await get(page).map({ String(decoding: $0, as: UTF8.self) }) else { return nil }
        let manifestURL = manifestURL(inHTML: html, page: page)
        let manifest = await manifestURL.asyncMap(get) ?? nil
        for url in candidates(html: html, page: page, manifest: manifest, manifestURL: manifestURL) {
            if let data = await get(url), let image = NSImage(data: data), image.isValid {
                return try? icns(from: image)
            }
        }
        return nil
    }

    /// A square site icon drawn into macOS's rounded-square shape (824 pt on a 1024 canvas), then every
    /// iconset size, packed by iconutil.
    static func icns(from image: NSImage) throws -> Data {
        let fm = FileManager.default
        let work = fm.temporaryDirectory.appending(path: "pilot-icon-\(UUID().uuidString)")
        let iconset = work.appending(path: "AppIcon.iconset")
        try fm.createDirectory(at: iconset, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: work) }
        var rendered: [Int: Data] = [:]  // 16@2x is 32, 128@2x is 256, 256@2x is 512: drawn once each
        for points in [16, 32, 128, 256, 512] {
            for scale in [1, 2] {
                let pixels = points * scale
                if rendered[pixels] == nil { rendered[pixels] = try png(of: image, pixels: pixels) }
                try rendered[pixels]!.write(to: iconset.appending(path: "icon_\(points)x\(points)\(scale == 2 ? "@2x" : "").png"))
            }
        }
        let out = work.appending(path: "AppIcon.icns")
        let packed = try run("/usr/bin/iconutil", ["-c", "icns", iconset.path, "-o", out.path])
        guard packed.status == 0 else { throw WebAppError.stampFailed("iconutil: \(packed.output)") }
        return try Data(contentsOf: out)
    }

    static func png(of image: NSImage, pixels: Int) throws -> Data {
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels, bitsPerSample: 8,
                                         samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                                         bytesPerRow: 0, bitsPerPixel: 0) else { throw WebAppError.stampFailed("bitmap") }
        let unit = CGFloat(pixels) / 1024
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        NSGraphicsContext.current?.imageInterpolation = .high
        let square = NSRect(x: 100 * unit, y: 100 * unit, width: 824 * unit, height: 824 * unit)
        NSBezierPath(roundedRect: square, xRadius: 185 * unit, yRadius: 185 * unit).addClip()
        image.draw(in: square)
        NSGraphicsContext.restoreGraphicsState()
        guard let data = rep.representation(using: .png, properties: [:]) else { throw WebAppError.stampFailed("png") }
        return data
    }

    static func get(_ url: URL) async -> Data? {
        guard let (data, response) = try? await URLSession.shared.data(from: url),
              (response as? HTTPURLResponse)?.statusCode == 200 else { return nil }
        return data
    }

    static func links(in html: String) -> [Link] {
        html.matches(of: /(?i)<link\b[^>]*>/).map { tag in
            let attributes = attributes(String(tag.output))
            let rel = Set((attributes["rel"] ?? "").lowercased().split(separator: " ").map(String.init))
            return Link(rel: rel, href: attributes["href"] ?? "", sizes: attributes["sizes"])
        }.filter { !$0.href.isEmpty }
    }

    /// One tag's attributes, names lowercased: <link rel="icon" href=/f.png> gives rel and href.
    static func attributes(_ tag: String) -> [String: String] {
        var out: [String: String] = [:]
        for m in tag.matches(of: /([\w:-]+)\s*=\s*(?:"([^"]*)"|'([^']*)'|([^\s>]+))/) {
            out[m.1.lowercased()] = String(m.2 ?? m.3 ?? m.4 ?? "")
        }
        return out
    }

    /// The largest edge in a sizes attribute ("180x180", "16x16 32x32"); "any" (an SVG) beats every bitmap.
    static func size(_ sizes: String?) -> Int {
        guard let sizes = sizes?.lowercased() else { return 0 }
        if sizes.contains("any") { return .max }
        return sizes.split(separator: " ").compactMap { $0.split(separator: "x").first.flatMap { Int($0) } }.max() ?? 0
    }

    static func biggestFirst(_ icons: [(URL, Int)]) -> [URL] {
        icons.enumerated().sorted { ($0.element.1, -$0.offset) > ($1.element.1, -$1.offset) }.map(\.element.0)
    }
}

private extension Optional {
    func asyncMap<T>(_ transform: (Wrapped) async -> T) async -> T? {
        guard let self else { return nil }
        return await transform(self)
    }
}
