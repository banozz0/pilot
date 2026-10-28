import CoreGraphics
import CoreText
import Foundation
import ImageIO
import Testing
@testable import PilotCore

/// The scrolling capture's stitcher (spec `capture.html` CP11): frames of a made-up page, scrolled by known amounts,
/// stitch back into exactly the page; a fixed header and footer appear once; a jump with no overlap is skipped; the
/// overlay scroll bar's edge never breaks a match; the result stops at its limit.
@Suite("Scroll stitch")
struct ScrollStitchTests {
    static let width = 16

    /// One row of the page: its index spelled into the pixels, with every eleventh row blank like a gap between lines.
    static func row(_ i: Int, mark: UInt8 = 0) -> [UInt8] {
        if i % 11 == 0 { return [UInt8](repeating: 255, count: width * 4) }
        return (0..<(width * 4)).map { UInt8(truncatingIfNeeded: i &* 31 &+ $0 &* 7 &+ (i >> 8)) } .enumerated().map { $0.offset >= (width - 2) * 4 ? mark : $0.element }
    }

    static func page(_ rows: Range<Int>) -> [UInt8] { rows.flatMap { row($0) } }

    static func header(_ n: Int) -> [UInt8] { (0..<n).flatMap { r in [UInt8](repeating: UInt8(10 + r), count: width * 4) } }

    @Test("Frames scrolled by 30, 40 and 50 rows stitch back into exactly the page")
    func plain() {
        var stitch = ScrollStitch(width: Self.width, height: 100)
        #expect(stitch.add(Self.page(0..<100)) == .first)
        #expect(stitch.add(Self.page(30..<130)) == .appended(30))
        #expect(stitch.add(Self.page(30..<130)) == .unchanged)
        #expect(stitch.add(Self.page(70..<170)) == .appended(40))
        #expect(stitch.add(Self.page(120..<220)) == .appended(50))
        #expect(stitch.height == 220)
        #expect(stitch.pixels() == Self.page(0..<220))
    }

    @Test("A sticky header and footer are kept once, at the top and the foot")
    func headerAndFooter() {
        var stitch = ScrollStitch(width: Self.width, height: 100)
        let top = Self.header(12), foot = Self.header(6)
        func frame(_ at: Int) -> [UInt8] { top + Self.page(at..<(at + 82)) + foot }
        #expect(stitch.add(frame(0)) == .first)
        #expect(stitch.add(frame(25)) == .appended(25))
        #expect(stitch.add(frame(60)) == .appended(35))
        #expect(stitch.pixels() == top + Self.page(0..<142) + foot)
    }

    @Test("A jump too far to overlap is skipped, and the next frame that overlaps carries on")
    func noMatch() {
        var stitch = ScrollStitch(width: Self.width, height: 100)
        _ = stitch.add(Self.page(0..<100))
        #expect(stitch.add(Self.page(95..<195)) == .noMatch)
        #expect(stitch.add(Self.page(60..<160)) == .appended(60))
        #expect(stitch.pixels() == Self.page(0..<160))
    }

    @Test("Scrolling up from mid-page stitches the rows above, the right way round")
    func up() {
        var stitch = ScrollStitch(width: Self.width, height: 100)
        _ = stitch.add(Self.page(150..<250))
        #expect(stitch.add(Self.page(120..<220)) == .appended(30))
        #expect(stitch.add(Self.page(70..<170)) == .appended(50))
        #expect(stitch.direction == .up)
        #expect(stitch.pixels() == Self.page(70..<250))
    }

    @Test("Up with a sticky header and footer keeps them once, the new rows between the header and the body")
    func upWithHeader() {
        var stitch = ScrollStitch(width: Self.width, height: 100)
        let top = Self.header(12), foot = Self.header(6)
        func frame(_ at: Int) -> [UInt8] { top + Self.page(at..<(at + 82)) + foot }
        _ = stitch.add(frame(200))
        #expect(stitch.add(frame(170)) == .appended(30))
        #expect(stitch.pixels() == top + Self.page(170..<282) + foot)
    }

    @Test("Once the page moved one way, a move the other way is skipped")
    func directionLock() {
        var stitch = ScrollStitch(width: Self.width, height: 100)
        _ = stitch.add(Self.page(100..<200))
        #expect(stitch.add(Self.page(130..<230)) == .appended(30))
        #expect(stitch.add(Self.page(110..<210)) == .noMatch)
        #expect(stitch.add(Self.page(160..<260)) == .appended(30))
        #expect(stitch.pixels() == Self.page(100..<260))
    }

    @Test("A few rows that change as the page scrolls (a hover under the pointer, a caret) do not break the match")
    func hover() {
        var stitch = ScrollStitch(width: Self.width, height: 100)
        _ = stitch.add(Self.page(0..<100))
        var moved = Self.page(40..<140)
        // Rows 30 to 37 of the new frame lit up as the pointer passed over them.
        for i in (30 * Self.width * 4)..<(38 * Self.width * 4) { moved[i] = 200 }
        #expect(stitch.add(moved) == .appended(40))
        #expect(stitch.height == 140)
    }

    @Test("Only a small band changed (a status line animating) and the rest is in place: the page did not move (build 55)")
    func animatedBand() {
        var stitch = ScrollStitch(width: Self.width, height: 100)
        _ = stitch.add(Self.page(0..<100))
        var band = Self.page(0..<100)
        for i in (70 * Self.width * 4)..<(78 * Self.width * 4) { band[i] = 200 }
        #expect(stitch.add(band) == .unchanged)
        // A band at the top and one at the foot, the rest in place: still unchanged; then a real move still stitches.
        var edges = Self.page(0..<100)
        for i in 0..<(10 * Self.width * 4) { edges[i] = 90 }
        for i in (88 * Self.width * 4)..<(100 * Self.width * 4) { edges[i] = 90 }
        #expect(stitch.add(edges) == .unchanged)
        #expect(stitch.add(Self.page(30..<130)) == .appended(30))
        #expect(stitch.pixels() == Self.page(0..<130))
    }

    @Test("The scroll bar showing at the right edge does not break a match")
    func scrollBar() {
        var stitch = ScrollStitch(width: Self.width, height: 100, ignoredRight: 2)
        _ = stitch.add(Self.page(0..<100))
        let barred = (40..<140).flatMap { Self.row($0, mark: 128) }
        #expect(stitch.add(barred) == .appended(40))
        #expect(stitch.height == 140)
    }

    @Test("The result stops at its limit and says so")
    func limit() {
        var stitch = ScrollStitch(width: Self.width, height: 100, limit: 250)
        _ = stitch.add(Self.page(0..<100))
        #expect(stitch.add(Self.page(60..<160)) == .appended(60))
        #expect(stitch.add(Self.page(120..<220)) == .appended(60))
        #expect(stitch.add(Self.page(180..<280)) == .full)
        #expect(stitch.height == 250)
        #expect(stitch.add(Self.page(200..<300)) == .full)
        #expect(stitch.pixels() == Self.page(0..<250))
    }
}

/// A page that scrolls over a backdrop that stays put (Sven, build 54: Ghostex's chat list over its blurred wallpaper,
/// 95 frames, 0 added, 94 unmatched): no row is ever the same twice, so the stitch matches by the rows' edges.
@Suite("Scroll stitch over a backdrop")
struct ScrollStitchBackdropTests {
    static let width = 300, height = 200

    /// Text lines and see-through cards, on nothing, `count` lines a page; `seed` changes the words.
    static func page(seed: Int = 0, rows: Int = 1000) -> CGImage {
        let ctx = CGContext(data: nil, width: width, height: rows, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)!
        let words = ["Message", "from", "Capture", "tool", "build", "Worked", "6s", "batch", "mouse", "binds", "lands", "after", "Q191", "the", "editor"]
        let font = CTFontCreateWithName("Helvetica" as CFString, 13, nil)
        for line in 0..<(rows / 22) {
            let y = CGFloat(rows - 18 - line * 22)
            if line % 6 == 0 {
                ctx.setFillColor(CGColor(gray: 1, alpha: 0.07))
                ctx.addPath(CGPath(roundedRect: CGRect(x: 8, y: y - 8, width: CGFloat(width - 16), height: 30), cornerWidth: 8, cornerHeight: 8, transform: nil))
                ctx.fillPath()
            }
            let text = (0..<6).map { words[($0 * 7 + line * 3 + seed * 5 + $0 * line) % words.count] }.joined(separator: " ")
            let string = NSAttributedString(string: text, attributes: [.font: font, .foregroundColor: CGColor(gray: 0.95, alpha: 1)])
            ctx.textPosition = CGPoint(x: CGFloat(14 + (line * 13 + seed * 9) % 40), y: y)
            CTLineDraw(CTLineCreateWithAttributedString(string), ctx)
        }
        return ctx.makeImage()!
    }

    /// A frame's pixels, BGRA rows top first, as `draw` paints them.
    static func render(_ draw: (CGContext) -> Void) -> [UInt8] {
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        pixels.withUnsafeMutableBytes { raw in
            let ctx = CGContext(data: raw.baseAddress, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                                space: CGColorSpaceCreateDeviceRGB(),
                                bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)!
            draw(ctx)
        }
        return pixels
    }

    /// A frame: the blurred-looking backdrop, the same every frame, and the page over it from row `at`.
    static func frame(_ page: CGImage, at: Int) -> [UInt8] {
        render { ctx in
            let space = CGColorSpaceCreateDeviceRGB()
            let wash = CGGradient(colorsSpace: space, colors: [CGColor(red: 0.05, green: 0.08, blue: 0.16, alpha: 1),
                                                               CGColor(red: 0.42, green: 0.36, blue: 0.48, alpha: 1)] as CFArray, locations: nil)!
            ctx.drawLinearGradient(wash, start: .zero, end: CGPoint(x: width, y: height), options: [])
            let blob = CGGradient(colorsSpace: space, colors: [CGColor(red: 0.7, green: 0.6, blue: 0.5, alpha: 0.6),
                                                               CGColor(red: 0.7, green: 0.6, blue: 0.5, alpha: 0)] as CFArray, locations: nil)!
            ctx.drawRadialGradient(blob, startCenter: CGPoint(x: 220, y: 60), startRadius: 0, endCenter: CGPoint(x: 220, y: 60), endRadius: 160, options: [])
            ctx.draw(page, in: CGRect(x: 0, y: at + height - page.height, width: page.width, height: page.height))
        }
    }

    @Test("A page scrolled over a fixed backdrop by 37, 44 and 59 rows stitches every move")
    func down() {
        let page = Self.page()
        var stitch = ScrollStitch(width: Self.width, height: Self.height)
        #expect(stitch.add(Self.frame(page, at: 0)) == .first)
        #expect(stitch.add(Self.frame(page, at: 37)) == .appended(37))
        #expect(stitch.add(Self.frame(page, at: 37)) == .unchanged)
        #expect(stitch.add(Self.frame(page, at: 81)) == .appended(44))
        #expect(stitch.add(Self.frame(page, at: 140)) == .appended(59))
        #expect(stitch.height == 340)
    }

    @Test("Upward over a fixed backdrop too")
    func up() {
        let page = Self.page()
        var stitch = ScrollStitch(width: Self.width, height: Self.height)
        _ = stitch.add(Self.frame(page, at: 500))
        #expect(stitch.add(Self.frame(page, at: 452)) == .appended(48))
        #expect(stitch.add(Self.frame(page, at: 420)) == .appended(32))
        #expect(stitch.direction == .up)
        #expect(stitch.height == 280)
    }

    /// A chat's frame: the page over the backdrop down to row 160, then the window's own foot over the backdrop: a
    /// composer `composer` rows tall, its top 4 rows green, standing on a 6-row status line. It can grow over the page.
    static func chat(_ page: CGImage, at: Int, composer: Int) -> [UInt8] {
        var pixels = frame(page, at: at)
        let backdrop = frame(Self.page(rows: 21), at: 0), rowBytes = width * 4
        pixels.replaceSubrange((160 * rowBytes)..., with: backdrop[(160 * rowBytes)...])
        for row in (height - 6 - composer)..<height {
            let colour: [UInt8] = row >= height - 6 ? [200, 200, 200, 255] : row < height - 6 - composer + 4 ? [0, 255, 0, 255] : [60, 60, 60, 255]
            for x in 0..<width { pixels.replaceSubrange((row * rowBytes + x * 4)..<(row * rowBytes + x * 4 + 4), with: colour) }
        }
        return pixels
    }

    /// The biggest step in blue, green and red together between two rows down column `x`: a seam in the backdrop shows.
    static func steepest(_ pixels: [UInt8], x: Int) -> Int {
        let rows = pixels.count / (width * 4)
        func tint(_ row: Int) -> Int { let i = (row * width + x) * 4; return Int(pixels[i]) + Int(pixels[i + 1]) + Int(pixels[i + 2]) }
        return (1..<rows).map { abs(tint($0) - tint($0 - 1)) }.max() ?? 0
    }

    @Test("A composer that grows at the chat's foot while the page moves, then while it stands, is kept once at the foot (build 59)")
    func growingFooter() {
        let page = Self.page()
        var stitch = ScrollStitch(width: Self.width, height: Self.height)
        #expect(stitch.add(Self.chat(page, at: 0, composer: 20)) == .first)
        #expect(stitch.add(Self.chat(page, at: 40, composer: 20)) == .appended(40))
        // The page moves and the composer grows within the window's foot, then over the page while the page stands.
        #expect(stitch.add(Self.chat(page, at: 80, composer: 30)) == .appended(40))
        #expect(stitch.add(Self.chat(page, at: 80, composer: 70)) == .unchanged)
        #expect(stitch.add(Self.chat(page, at: 80, composer: 90)) == .unchanged)
        #expect(stitch.height == Self.height + 80)
        // The composer's green top, 4 rows, appears once, in the foot.
        let result = stitch.pixels(), rowBytes = Self.width * 4
        let green = (0..<stitch.height).filter { row in Array(result[(row * rowBytes + 600)..<(row * rowBytes + 603)]) == [0, 255, 0] }
        #expect(green.count == 4)
        #expect(green.allSatisfy { $0 >= stitch.height - 40 })
    }

    @Test("Seams over a gradient backdrop are eased, down and up: no step in its tint beyond a row's own")
    func easedSeams() {
        let page = Self.page()
        let still = Self.steepest(Self.frame(page, at: 0), x: 3)
        var down = ScrollStitch(width: Self.width, height: Self.height)
        for at in [0, 37, 81, 140] { _ = down.add(Self.frame(page, at: at)) }
        #expect(down.height == 340)
        #expect(Self.steepest(down.pixels(), x: 3) <= still + 3)
        var up = ScrollStitch(width: Self.width, height: Self.height)
        for at in [500, 452, 420] { _ = up.add(Self.frame(page, at: at)) }
        #expect(up.height == 280)
        #expect(Self.steepest(up.pixels(), x: 3) <= still + 3)
    }

    /// A frame over a streaked wallpaper (Sven, build 83: Pilot's Settings over a blurred wallpaper with sharp diagonal
    /// streaks): the backdrop changes faster across than the swap's 16 bins follow, the page with its see-through cards
    /// moves under a 14-row header that stays put from row `at`.
    static func streaked(_ page: CGImage, at: Int) -> [UInt8] {
        render { ctx in
            let wash = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: [CGColor(red: 0.12, green: 0.1, blue: 0.2, alpha: 1),
                                                                                    CGColor(red: 0.6, green: 0.3, blue: 0.25, alpha: 1)] as CFArray, locations: nil)!
            ctx.drawLinearGradient(wash, start: .zero, end: CGPoint(x: width, y: height), options: [])
            ctx.setLineWidth(9)
            for i in 0..<16 {
                ctx.setStrokeColor(i % 2 == 0 ? CGColor(red: 0.85, green: 0.45, blue: 0.3, alpha: 0.5) : CGColor(red: 0.1, green: 0.2, blue: 0.45, alpha: 0.5))
                ctx.strokeLineSegments(between: [CGPoint(x: i * 31 - 200, y: 0), CGPoint(x: i * 31, y: height)])
            }
            ctx.draw(page, in: CGRect(x: 0, y: at + height - page.height, width: page.width, height: page.height))
            ctx.setFillColor(CGColor(red: 0.15, green: 0.15, blue: 0.18, alpha: 1))
            ctx.fill(CGRect(x: 0, y: height - 14, width: width, height: 14))
            ctx.setFillColor(CGColor(gray: 0.9, alpha: 1))
            for x in Swift.stride(from: 10, to: width - 20, by: 50) { ctx.fill(CGRect(x: x, y: height - 10, width: 24, height: 6)) }
        }
    }

    /// Per row from the second, the middle step in blue, green and red together from the row above, across the columns:
    /// a seam in the backdrop steps across most of them, a line of text or a card's edge across few.
    static func steps(_ pixels: [UInt8], width: Int) -> [Int] {
        let rows = pixels.count / (width * 4)
        return (1..<rows).map { row in
            var d = (0..<width).map { x in
                let i = (row * width + x) * 4, j = i - width * 4
                return abs(Int(pixels[i]) - Int(pixels[j])) + abs(Int(pixels[i + 1]) - Int(pixels[j + 1])) + abs(Int(pixels[i + 2]) - Int(pixels[j + 2]))
            }
            d.sort()
            return d[d.count / 2]
        }
    }

    @Test("Over a streaked wallpaper under a sticky header, every seam is as smooth as a frame's own rows, and the header is kept once (build 83)")
    func streakedSeams() {
        let page = Self.page()
        var stitch = ScrollStitch(width: Self.width, height: Self.height)
        #expect(stitch.add(Self.streaked(page, at: 0)) == .first)
        #expect(stitch.add(Self.streaked(page, at: 37)) == .appended(37))
        #expect(stitch.add(Self.streaked(page, at: 81)) == .appended(44))
        #expect(stitch.add(Self.streaked(page, at: 140)) == .appended(59))
        #expect(stitch.height == Self.height + 140)
        let result = stitch.pixels(), rowBytes = Self.width * 4, header = Self.streaked(page, at: 0)[..<(14 * rowBytes)]
        #expect(result[..<(14 * rowBytes)] == header)
        // The rows the frames met at (the first frame's foot, then each band's) step no more than the same rows of the page
        // do inside the last frame, 140 rows up, where nothing met; a card's edge may step there too.
        let steps = Self.steps(result, width: Self.width), within = Self.steps(Self.streaked(page, at: 140), width: Self.width)
        for seam in [Self.height, Self.height + 37, Self.height + 81] {
            #expect(steps[seam - 1] <= within[seam - 1 - 140] + 6, "seam at row \(seam)")
        }
    }

    @Test("Another page over the same backdrop is no match")
    func otherPage() {
        var stitch = ScrollStitch(width: Self.width, height: Self.height)
        _ = stitch.add(Self.frame(Self.page(), at: 100))
        #expect(stitch.add(Self.frame(Self.page(seed: 1), at: 100)) == .noMatch)
        #expect(stitch.add(Self.frame(Self.page(seed: 2), at: 130)) == .noMatch)
        #expect(stitch.height == Self.height)
    }
}

/// Frames of a made-up chat drawn to match Sven's own frames of Ghostex's chat (build 58, `captureScrollFrames`): a strip
/// 200 pixels wide over a backdrop that stays put, the page moving under a 5-row top and a 338-row glass composer whose
/// caret blinks. And three of Sven's own frames of Pilot's Settings (build 83), the left 240 pixels: see-through cards
/// over a wallpaper with sharp streaks.
@Suite("Scroll stitch on chat frames")
struct ScrollStitchFramesTests {
    /// A frame as the stream gives it: BGRA rows, top first.
    static func frame(_ name: String) throws -> (width: Int, height: Int, pixels: [UInt8]) {
        let url = try #require(Bundle.module.url(forResource: name, withExtension: "png", subdirectory: "ScrollFrames"))
        let source = try #require(CGImageSourceCreateWithURL(url as CFURL, nil))
        let image = try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
        var pixels = [UInt8](repeating: 0, count: image.width * image.height * 4)
        let info = CGImageAlphaInfo.noneSkipFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
        let context = try #require(CGContext(data: &pixels, width: image.width, height: image.height, bitsPerComponent: 8,
                                             bytesPerRow: image.width * 4, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: info))
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        return (image.width, image.height, pixels)
    }

    @Test("A blinking caret is no move, a 320-row scroll with the caret blinking stitches, and the composer is kept once at the foot")
    func ghostexChat() throws {
        let start = try Self.frame("chat-0040"), blink = try Self.frame("chat-0051"), moved = try Self.frame("chat-0057")
        var stitch = ScrollStitch(width: start.width, height: start.height)
        #expect(stitch.add(start.pixels) == .first)
        #expect(stitch.add(blink.pixels) == .unchanged)
        #expect(stitch.add(moved.pixels) == .appended(320))
        // The page above the composer, the 320 rows that scrolled in, then the newest composer: 338 rows, once, as it was.
        // The page's rows trade their stretch of the backdrop for the window's (build 63); its text keeps its colour.
        let rowBytes = start.width * 4, page = start.height - 338, result = stitch.pixels()
        #expect(stitch.height == start.height + 320)
        #expect(Array(result[((page + 320) * rowBytes)...]) == Array(moved.pixels[(page * rowBytes)...]))
        let text = Swift.stride(from: 0, to: page * rowBytes, by: 4).filter { i in
            Int(start.pixels[i]) + Int(start.pixels[i + 1]) + Int(start.pixels[i + 2]) >= 600
        }
        #expect(!text.isEmpty)
        #expect(text.allSatisfy { i in result[i..<(i + 3)].elementsEqual(start.pixels[i..<(i + 3)]) })
    }

    @Test("Sven's Settings frames over a streaked wallpaper stitch 130 and 42 rows with no step at either seam (build 83)")
    func settings() throws {
        let frames = try ["settings-0001", "settings-0003", "settings-0009"].map(Self.frame)
        var stitch = ScrollStitch(width: frames[0].width, height: frames[0].height)
        #expect(stitch.add(frames[0].pixels) == .first)
        #expect(stitch.add(frames[1].pixels) == .appended(130))
        #expect(stitch.add(frames[2].pixels) == .appended(42))
        // Before the fade these two seams stepped 10 and 9 across the strip.
        let steps = ScrollStitchBackdropTests.steps(stitch.pixels(), width: stitch.width)
        for seam in [frames[0].height, frames[0].height + 130] { #expect(steps[seam - 1] <= 5, "seam at row \(seam)") }
    }
}
