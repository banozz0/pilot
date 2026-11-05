import AppKit
import ImageIO
@testable import PilotCore
import SwiftUI
import Testing
import UniformTypeIdentifiers
@testable import Pilot

/// The GIPHY key as a value in memory, so no render reads or writes the login Keychain.
private final class MemoryKeyStore: StoredKey, @unchecked Sendable {
    private let lock = NSLock()
    private var value: String?
    init(_ value: String? = nil) { self.value = value }
    func read() -> String? { lock.withLock { value } }
    func exists() -> Bool { read() != nil }
    func write(_ value: String?) throws { lock.withLock { self.value = value } }
}

/// Web GIF search in Stickers and GIFs (story 164), drawn offscreen in Instrument and Toybox: GIPHY's rows beside
/// the folder's with their animated previews, GIPHY's logo and "Powered by GIPHY" on the bar (T39), the row that asks for a key, and the key's
/// rows under Stickers and GIFs on Launcher › Abilities. Nothing reaches the network. PILOT_RENDER_DIR keeps the PNGs.
extension SharedLook {
@MainActor
@Suite("GIPHY renders")
struct GiphyRenders {
    /// A two-frame 64-pixel GIF in `hue`, as GIPHY's previews are.
    static func gif(_ hue: CGFloat) throws -> Data {
        let data = NSMutableData()
        let dest = try #require(CGImageDestinationCreateWithData(data, UTType.gif.identifier as CFString, 2, nil))
        for bright in [0.55, 0.95] {
            let ctx = try #require(CGContext(data: nil, width: 64, height: 64, bitsPerComponent: 8, bytesPerRow: 0,
                                             space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
            ctx.setFillColor(NSColor(hue: hue, saturation: 0.7, brightness: bright, alpha: 1).cgColor)
            ctx.fill(CGRect(x: 0, y: 0, width: 64, height: 64))
            ctx.setFillColor(NSColor.white.cgColor)
            ctx.fillEllipse(in: CGRect(x: 20, y: 20, width: 24, height: 24))
            CGImageDestinationAddImage(dest, try #require(ctx.makeImage()),
                                       [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFDelayTime: 0.2]] as CFDictionary)
        }
        #expect(CGImageDestinationFinalize(dest))
        return data as Data
    }

    static let gifs = ["Happy Dance GIF by Mashable", "Dance Party GIF by Disney", "Dancing Cat GIF"].enumerated().map { i, title in
        WebGIF(id: "render-\(i)", title: title, preview: URL(string: "https://media.giphy.com/media/render-\(i)/giphy-preview.gif")!,
               full: URL(string: "https://media.giphy.com/media/render-\(i)/giphy-downsized.gif")!)
    }

    /// Stickers and GIFs with "dance" typed: one GIF of the folder, then GIPHY's (or the key row).
    static func model(web: Bool, key: Bool = true, kind: Giphy.Kind = .gifs) throws -> MenuModel {
        AppsModule.keepWebThumbnails(Dictionary(uniqueKeysWithValues: try gifs.enumerated().map { ($1.id, try gif(CGFloat($0) * 0.3)) }))
        var nav = MenuNavigator(entries: [], branch: .stickers)
        nav.provide(.file, home: .stickers, [Stickers.folderRow])
        nav.query = "dance"
        let local = MenuEntry(title: "dance floor", target: .sticker(.image("/tmp/pilot-render/dance floor.gif")), home: .stickers,
                              inSearch: false)
        let giphy = key ? (web ? Giphy.entries(gifs, query: "dance") : []) : [Giphy.keyRow(refused: false, query: "dance")]
        nav.provide(.sticker, home: .stickers, [local] + giphy)
        let model = MenuModel(nav: nav)
        model.giphyKind = kind
        return model
    }

    static func render(_ model: MenuModel) throws -> NSBitmapImageRep {
        let panel = HUD.makePanel(MenuView(model: model), surface: .menu)
        defer { panel.close() }
        let content = try #require(panel.contentView)
        RunLoop.main.run(until: Date().addingTimeInterval(0.4))
        content.layoutSubtreeIfNeeded()
        return try #require(snapshot(content, scale: 2))
    }

    @Test("The bar shows GIPHY's logo and Powered by GIPHY only while GIPHY's rows are listed, and the foot never repeats it")
    func footer() throws {
        func names(_ model: MenuModel) -> Bool { model.showsGiphyAttribution && model.footerNote == nil && GiphyAttribution.mark != nil }
        #expect(names(try Self.model(web: true)))
        #expect(!names(try Self.model(web: false)))
        #expect(!names(try Self.model(web: false, key: false)))
        #expect(AppsModule.webThumbnail("render-0").map(ArtImage.animated) == true, "a preview keeps its frames, so its row plays it")
    }

    @Test("The GIFs | Stickers bar shows in Stickers and GIFs alone, Tab names the other, and a pick is kept for the next menu")
    func kindBar() throws {
        let model = try Self.model(web: true)
        #expect(model.showsGiphyBar && model.giphyKind == .gifs)
        #expect(model.footer.contains { $0.0 == "Tab" && $0.1 == "GIPHY Stickers" })
        var asked: [String] = []
        model.onQuery = { asked.append($0) }
        model.pickGiphy(.stickers)
        #expect(model.giphyKind == .stickers && asked == ["dance"], "a pick asks GIPHY again for the same text")
        model.pickGiphy(.stickers)
        #expect(asked.count == 1, "the shown tab asks nothing")
        #expect(MenuModel(nav: MenuNavigator(entries: [], branch: .stickers)).giphyKind == .stickers, "the next menu opens on it")
        #expect(model.footer.contains { $0.0 == "Tab" && $0.1 == "GIPHY GIFs" })
        #expect(!MenuModel(nav: MenuNavigator(entries: [], branch: .trigger)).showsGiphyBar, "no other branch has the bar")
        #expect(!MenuModel(nav: MenuNavigator(entries: [])).showsGiphyBar)
        let tall = MenuPanelSize.instrument(.wide, rows: 3, headings: 0, bar: GiphyKindBar.instrumentHeight).height
        #expect(tall == MenuPanelSize.instrument(.wide, rows: 3, headings: 0).height + GiphyKindBar.instrumentHeight, "the bar takes no row's room")
        model.giphyKind = .gifs
    }

    @Test("The picker lists GIPHY's GIFs beside the folder's, animated, with the attribution; without a key, the row that asks for one")
    func picker() throws {
        testApp()
        let faces = DisplayFaces.directory
        DisplayFaces.directory = LookThemeTests.fonts
        defer { DisplayFaces.directory = faces }
        let look = Look.shared
        let saved = look.style
        defer { look.style = saved }
        for style in PilotStyle.allCases {
            look.style = style
            for (name, model, lines) in [("web", try Self.model(web: true), ["GIFs", "Stickers", "Happy Dance", "Dance Party", "Dancing Cat", "dance floor", "Powered by", "GIPHY"]),
                                         ("stickers", try Self.model(web: true, kind: .stickers), ["GIFs", "Stickers", "Happy Dance", "Powered by"]),
                                         ("no-key", try Self.model(web: false, key: false), ["GIFs", "Stickers", "Add a GIPHY key", "dance floor"])] {
                let rep = try Self.render(model)
                if let dir = ProcessInfo.processInfo.environment["PILOT_RENDER_DIR"] {
                    try rep.representation(using: .png, properties: [:])?.write(to: URL(filePath: dir).appending(path: "giphy-\(style.rawValue)-\(name).png"))
                }
                let text = try recognisedText(in: rep).map(\.text).joined(separator: "\n")
                for line in lines { #expect(text.localizedCaseInsensitiveContains(line), "\(style.rawValue) \(name): \(line) missing, read: \(text)") }
                if name == "no-key" { #expect(!text.contains("Powered by"), "\(style.rawValue): no GIPHY rows, no attribution") }
            }
        }
    }

    @Test("Launcher › Abilities, under Stickers and GIFs: a field and Get a key with no key; once saved, only that it is in the Keychain; the rating PG-13 until picked")
    func keyRows() throws {
        let look = try LookPageTests().look().0
        let store = MemoryKeyStore()
        let folders = PilotFolders(defaults: SetupGapsTests.defaults())
        for (name, lines, absent) in [("none", ["GIPHY key", "Save", "Get a key", "GIPHY rating", "PG-13"], "Saved in your Keychain"),
                                      ("saved", ["GIPHY key", "Saved in your Keychain", "Replace", "Remove", "GIPHY rating", "PG"], "Get a key")] {
            if name == "saved" { try store.write("k3y-never-shown"); folders.giphyRating = .pg }
            let view = FoldersBlock(.gifs, folders: folders, giphy: store)
                .padding(10).frame(width: 760).styled(.page(.menu)).background(Theme.background).pilotTheme(look: look)
            var text = ""
            try LookPageTests().hosted(view.frame(width: 1000, height: 400), height: 400) { host in
                let rep = try #require(snapshot(host, scale: 2))
                if let dir = ProcessInfo.processInfo.environment["PILOT_RENDER_DIR"] {
                    try rep.representation(using: .png, properties: [:])?.write(to: URL(filePath: dir).appending(path: "giphy-key-\(name).png"))
                }
                text = try recognisedText(in: rep).map(\.text).joined(separator: "\n")
            }
            for line in lines { #expect(text.localizedCaseInsensitiveContains(line), "\(name): \(line) missing, read: \(text)") }
            #expect(!text.contains(absent), "\(name): \(absent) shown, read: \(text)")
            #expect(!text.contains("k3y"), "the key is never drawn")
        }
    }
}
}
