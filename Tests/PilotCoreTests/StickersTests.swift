import AppKit
import Foundation
import Testing
import UniformTypeIdentifiers
@testable import PilotCore

/// Stickers and GIFs (card agent-bo-95423130): the GIFs of Sven's folder, put on the pasteboard for one paste and the
/// pasteboard given back after; emoji left the branch with P39. Private pasteboards and a temp folder only.
@Suite("Stickers")
@MainActor
struct StickersTests {
    private func board() -> NSPasteboard { NSPasteboard(name: .init("pilot.test.stickers.\(UUID().uuidString)")) }

    /// A PNG of `width` × `height` pixels at `url`: red, with the middle `height` square green.
    private func png(width: Int, height: Int, to url: URL) throws {
        let context = try #require(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                             space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(red: 1, green: 0, blue: 0, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.setFillColor(red: 0, green: 1, blue: 0, alpha: 1)
        context.fill(CGRect(x: (width - height) / 2, y: 0, width: height, height: height))
        let out = try #require(CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(out, try #require(context.makeImage()), nil)
        #expect(CGImageDestinationFinalize(out))
    }

    private func folder() throws -> URL {
        let folder = FileManager.default.temporaryDirectory.appending(path: "pilot-stickers-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder.appending(path: "Reactions"), withIntermediateDirectories: true)
        for name in ["party parrot.gif", "Reactions/thumbs_up.gif", "Reactions/facepalm.png", "notes.txt", ".hidden.gif", "photo.heic", "logo.svg"] {
            try Data("GIF89a \(name)".utf8).write(to: folder.appending(path: name))
        }
        return folder
    }

    @Test("The folder lists its gif, png, jpg, jpeg and webp pictures, subfolders included, never hidden files or other kinds")
    func files() throws {
        let folder = try folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let files = Stickers.files(in: folder)
        #expect(files.map(\.name) == ["party parrot", "facepalm", "thumbs_up"])
        #expect(files.map(\.folder) == [nil, "Reactions", "Reactions"])
        #expect(Stickers.files(in: folder.appending(path: "missing")).isEmpty)
    }

    @Test("An empty search lists every picture; typed words must each start a word of the name or its folder; no emoji (P39)")
    func search() throws {
        let folder = try folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let files = Stickers.files(in: folder)
        #expect(Stickers.entries(for: "", files: files).map(\.title) == ["party parrot", "facepalm", "thumbs_up"])
        #expect(Stickers.entries(for: "par", files: files).map(\.title) == ["party parrot"])
        #expect(Stickers.entries(for: "thumbs up", files: files).map(\.title) == ["thumbs_up"])
        #expect(Stickers.entries(for: "react", files: files).map(\.title) == ["facepalm", "thumbs_up"])
        #expect(Stickers.entries(for: "rrot", files: files).isEmpty)
        let gif = try #require(Stickers.entries(for: "party", files: files).first)
        #expect(gif.target == .sticker(.image(folder.appending(path: "party parrot.gif").path)))
        #expect(gif.home == .stickers && gif.kind == .sticker && gif.kindWord == "GIF" && gif.returnLabel == "Paste")
        #expect(gif.frecencyKey == "sticker:" + folder.appending(path: "party parrot.gif").path)
        let png = try #require(Stickers.entries(for: "face", files: files).first)
        #expect(png.kindWord == "Image")
        #expect(Stickers.entries(for: "par", files: files).allSatisfy { !$0.inSearch }, "only the branch lists them")
    }

    @Test("A picture's row thumbnail is its first frame, at most 56 pixels a side; a file that is no picture has none")
    func thumbnail() throws {
        let folder = try folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let real = folder.appending(path: "parrot.png")
        try png(width: 320, height: 320, to: real)
        let thumb = try #require(Stickers.thumbnail(of: real.path))
        #expect(thumb.width == 56 && thumb.height == 56)
        #expect(Stickers.thumbnail(of: folder.appending(path: "party parrot.gif").path) == nil)
    }

    @Test("A wide picture's thumbnail is its middle cropped square, never the whole picture squashed into one")
    func wideThumbnail() throws {
        let folder = try folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        // 200 × 100: green in the middle 100, red on the 50 either side.
        let wide = folder.appending(path: "wide.png")
        try png(width: 200, height: 100, to: wide)
        let thumb = NSBitmapImageRep(cgImage: try #require(Stickers.thumbnail(of: wide.path)))
        #expect(thumb.pixelsWide == 56 && thumb.pixelsHigh == 56)
        let corner = try #require(thumb.colorAt(x: 1, y: 1)?.usingColorSpace(.sRGB))
        #expect(corner.greenComponent > 0.9 && corner.redComponent < 0.1)
    }

    @Test("Return puts the sticker on the pasteboard marked transient: a GIF's own bytes and its file")
    func put() throws {
        let folder = try folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let board = board()
        defer { board.releaseGlobally() }
        let gif = folder.appending(path: "party parrot.gif")
        let count = try Stickers.put(.image(gif.path), on: board)
        #expect(count == board.changeCount)
        let types = try #require(board.types)
        #expect(types.contains(.init("org.nspasteboard.TransientType")))
        #expect(board.data(forType: .init("com.compuserve.gif")) == (try Data(contentsOf: gif)))
        #expect(board.string(forType: .fileURL) == gif.absoluteString)
        #expect(throws: (any Error).self) { try Stickers.put(.image(folder.appending(path: "gone.gif").path), on: board) }
    }

    @Test("The pasteboard gets back exactly what it held, marked transient, unless something was copied meanwhile")
    func restore() throws {
        let folder = try folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let gif = Sticker.image(folder.appending(path: "party parrot.gif").path)
        let board = board()
        defer { board.releaseGlobally() }
        board.clearContents()
        let first = NSPasteboardItem(), second = NSPasteboardItem()
        first.setString("copied text", forType: .string)
        first.setData(Data("<b>copied</b>".utf8), forType: .html)
        second.setString("https://example.com", forType: .URL)
        // An app's own undeclared type comes back as a dyn. type; it is the copy's data, so it is kept.
        second.setData(Data("private".utf8), forType: .init("dyn.ah62d4rv4gu8yc6durvwwa3xmrvw1gkdusm1044pxqyuha2pxsvw0e55bsmwca7d3sbwu"))
        board.writeObjects([first, second])
        let saved = PasteboardSnapshot(board)
        let count = try Stickers.put(gif, on: board)
        #expect(saved.restore(to: board, ifUnchangedSince: count))
        let items = try #require(board.pasteboardItems)
        #expect(items.count == 2)
        #expect(items[0].string(forType: .string) == "copied text")
        #expect(items[0].data(forType: .html) == Data("<b>copied</b>".utf8))
        #expect(items[1].string(forType: .URL) == "https://example.com")
        #expect(items[1].data(forType: .init("dyn.ah62d4rv4gu8yc6durvwwa3xmrvw1gkdusm1044pxqyuha2pxsvw0e55bsmwca7d3sbwu")) == Data("private".utf8))
        #expect(board.types?.contains(.init("org.nspasteboard.TransientType")) == true)
        #expect(board.data(forType: .init("com.compuserve.gif")) == nil)

        let again = try Stickers.put(gif, on: board)
        board.clearContents()
        board.setString("copied meanwhile", forType: .string)
        #expect(!saved.restore(to: board, ifUnchangedSince: again))
        #expect(board.string(forType: .string) == "copied meanwhile")
    }

    @Test("Trigger lists Stickers and GIFs, whose rows show inside it and never at the root's search")
    func branch() throws {
        #expect(MenuLayout.rows[.trigger]?.contains(.branch(.stickers)) == true)
        #expect(MenuBranch.stickers.title == "Stickers and GIFs" && MenuBranch.stickers.parent == .trigger)
        let rows = Stickers.entries(for: "parrot", files: [StickerFile(path: "/tmp/parrot.gif", name: "parrot", folder: nil, words: ["parrot"])])
        var nav = MenuNavigator(entries: [], branch: .stickers)
        nav.provide(.sticker, home: .stickers, rows)
        #expect(nav.rows.map(\.title) == ["parrot"])
        nav.handle(.escape)
        nav.query = "parrot"
        #expect(!nav.rows.contains { $0.home == .stickers })
    }
}
