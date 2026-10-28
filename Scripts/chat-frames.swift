#!/usr/bin/env swift
// The scroll stitch's chat frames (SH9): Tests/PilotCoreTests/ScrollFrames/chat-0040, -0051 and -0057.png, which
// ScrollStitchFramesTests reads. They stand in for Sven's own frames of Ghostex's chat (build 58), which showed his
// work, and keep what made those hard: a backdrop that stays put (dark, wavy, never the same two rows), a made-up chat
// clipped to rows 5..<729 that moves 320 rows up from the first frame to the third, and a glass composer in the last 338
// rows that stays put but for a 1-pixel caret, off in the first frame and on in the other two.
//   swift Scripts/chat-frames.swift [<folder>]    from the repo root; the folder is Tests/PilotCoreTests/ScrollFrames
import CoreGraphics
import CoreText
import Foundation
import ImageIO
import UniformTypeIdentifiers

let W = 200, H = 1067, composerTop = H - 338, pageTop = 5, scroll = 320

func color(_ r: Int, _ g: Int, _ b: Int, _ a: CGFloat = 1) -> CGColor {
    CGColor(srgbRed: CGFloat(r) / 255, green: CGFloat(g) / 255, blue: CGFloat(b) / 255, alpha: a)
}

/// The blurred wallpaper behind the window: a dark navy that rises and falls slowly down the frame.
func backdrop(_ x: Int, _ y: Int) -> (Int, Int, Int) {
    let fy = Double(y), fx = Double(x)
    let v = 4 * sin(fy / 97) + 3 * sin(fy / 41 + 1.3) + 1.2 * sin(fx / 37 + fy / 150) + (y >= composerTop ? 5 : 0)
    let d = Int(v.rounded())
    return (max(0, 13 + d), max(0, 16 + d), max(0, 26 + d))
}

let font = CTFontCreateWithName("Helvetica Neue" as CFString, 14, nil)
let bold = CTFontCreateWithName("Helvetica Neue Bold" as CFString, 14, nil)
let small = CTFontCreateWithName("Helvetica Neue Bold" as CFString, 11, nil)

/// One line of text with its baseline at `y` (top-down frame rows), left edge `x`.
func text(_ c: CGContext, _ s: String, x: CGFloat, y: CGFloat, font: CTFont = font, color fill: CGColor = color(236, 238, 243)) {
    let attrs: [NSAttributedString.Key: Any] = [.init(kCTFontAttributeName as String): font, .init(kCTForegroundColorAttributeName as String): fill]
    let line = CTLineCreateWithAttributedString(NSAttributedString(string: s, attributes: attrs))
    c.saveGState()
    c.textMatrix = CGAffineTransform(scaleX: 1, y: -1)
    c.textPosition = CGPoint(x: x, y: y)
    CTLineDraw(line, c)
    c.restoreGState()
}

func pill(_ c: CGContext, _ s: String, x: CGFloat, y: CGFloat, w: CGFloat, fill: CGColor, ink: CGColor) {
    c.setFillColor(fill)
    c.addPath(CGPath(roundedRect: CGRect(x: x, y: y - 15, width: w, height: 21), cornerWidth: 10, cornerHeight: 10, transform: nil))
    c.fillPath()
    text(c, s, x: x + 9, y: y, font: small, color: ink)
}

func card(_ c: CGContext, _ s: String, y: CGFloat, height: CGFloat = 36) {
    c.setFillColor(color(24, 27, 37, 0.9))
    c.setStrokeColor(color(52, 56, 68))
    c.setLineWidth(1)
    let path = CGPath(roundedRect: CGRect(x: 12.5, y: y + 0.5, width: 230, height: height), cornerWidth: 9, cornerHeight: 9, transform: nil)
    c.addPath(path); c.fillPath()
    c.addPath(path); c.strokePath()
    text(c, "›", x: 24, y: y + 23, font: bold, color: color(170, 174, 184))
    text(c, s, x: 42, y: y + 23, font: bold)
}

/// The made-up transcript, in page rows from its top; drawn once per frame at the frame's scroll.
func page(_ c: CGContext) {
    let grey = color(150, 155, 166), blue = color(108, 180, 255)
    card(c, "Worked 41s", y: 8)
    text(c, "›  Read 3 files", x: 16, y: 74, color: grey)
    text(c, "The timer app builds again: the", x: 12, y: 108)
    text(c, "settings sheet opens and saves.", x: 12, y: 131)
    pill(c, "● DONE", x: 12, y: 168, w: 70, fill: color(24, 70, 48), ink: color(96, 214, 140))
    text(c, "Release notes", x: 90, y: 168, font: bold)
    text(c, "•  Fixed the sort order on the list", x: 22, y: 202)
    text(c, "•  Dark mode follows the system", x: 22, y: 229)
    text(c, "    toggle in General.", x: 22, y: 252)
    text(c, "•  The export writes CSV and JSON", x: 22, y: 279)
    text(c, "•  Icons redrawn at 2x for the", x: 22, y: 306)
    text(c, "    retina sidebar.", x: 22, y: 329)
    pill(c, "● WAITING", x: 12, y: 372, w: 88, fill: color(84, 30, 34), ink: color(240, 110, 110))
    text(c, "•  Sync: waiting on the API key", x: 22, y: 408)
    text(c, "•  Widgets: waiting on review", x: 22, y: 435)
    text(c, "•  Search: two failing cases", x: 22, y: 462)
    pill(c, "● ASK", x: 12, y: 505, w: 58, fill: color(90, 58, 20), ink: color(250, 170, 80))
    text(c, "•  Keep the old shortcut too?", x: 22, y: 541)
    text(c, "•  ", x: 22, y: 568)
    text(c, "Open the preview page", x: 40, y: 568, color: blue)
    text(c, "•  Which colour for the badge,", x: 22, y: 595)
    text(c, "    teal or amber?", x: 22, y: 618)
    text(c, "Next: try the build, then say", x: 12, y: 655)
    text(c, "which badge colour wins.", x: 12, y: 678)
    text(c, "Thanks, trying it now", x: 70, y: 722, color: grey)
    card(c, "Message from tester", y: 748, height: 40)
    card(c, "Worked 9s", y: 806)
    card(c, "Message to tester", y: 856, height: 40)
    text(c, "I sent the tester the new build", x: 12, y: 930)
    text(c, "and the list of changes.", x: 12, y: 953)
    pill(c, "? Q12", x: 12, y: 990, w: 54, fill: color(40, 36, 30), ink: color(240, 196, 120))
    text(c, "is the sidebar width right?", x: 74, y: 990)
    text(c, "Draft reply ready for review.", x: 12, y: 1022, color: grey)
    pill(c, "? Q13", x: 12, y: 1052, w: 54, fill: color(40, 36, 30), ink: color(240, 196, 120))
}

/// The glass composer at the foot: it stays put; only its caret blinks.
func composer(_ c: CGContext, caret: Bool) {
    let top = CGFloat(composerTop)
    c.setFillColor(color(28, 31, 42, 0.92))
    c.setStrokeColor(color(56, 60, 72))
    c.setLineWidth(1)
    let path = CGPath(roundedRect: CGRect(x: 2.5, y: top + 52.5, width: 240, height: 262), cornerWidth: 18, cornerHeight: 18, transform: nil)
    c.addPath(path); c.fillPath()
    c.addPath(path); c.strokePath()
    c.setFillColor(color(118, 122, 130))
    c.fill(CGRect(x: 12, y: top + 66, width: 56, height: 56))
    c.setFillColor(color(60, 64, 72))
    c.fillEllipse(in: CGRect(x: 30, y: top + 80, width: 20, height: 20))
    text(c, "the badge still looks too wide", x: 12, y: top + 152)
    text(c, "▢ Image #1", x: 12, y: top + 176, color: color(120, 200, 150))
    if caret {
        c.setFillColor(color(236, 238, 243))
        c.fill(CGRect(x: 12, y: top + 236, width: 1, height: 25))
    }
    text(c, "◉  Model  Low  ⌄", x: 16, y: top + 290, color: color(170, 174, 184))
    text(c, "61%  ·  main", x: 120, y: top + 330, font: small, color: color(110, 114, 124))
}

func frame(offset: Int, caret: Bool) -> CGImage {
    let c = CGContext(data: nil, width: W, height: H, bitsPerComponent: 8, bytesPerRow: W * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                      bitmapInfo: CGImageAlphaInfo.noneSkipFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)!
    let px = c.data!.bindMemory(to: UInt8.self, capacity: W * H * 4)
    // Memory rows are top first; CG draws bottom-up, so flip once and draw in top-down rows.
    for y in 0..<H { for x in 0..<W { let (r, g, b) = backdrop(x, y), i = (y * W + x) * 4; px[i] = UInt8(b); px[i + 1] = UInt8(g); px[i + 2] = UInt8(r); px[i + 3] = 255 } }
    c.translateBy(x: 0, y: CGFloat(H)); c.scaleBy(x: 1, y: -1)
    c.setShouldSmoothFonts(false)
    c.saveGState()
    c.clip(to: CGRect(x: 0, y: pageTop, width: W, height: composerTop - pageTop))
    c.translateBy(x: 0, y: CGFloat(pageTop - offset))
    page(c)
    c.restoreGState()
    composer(c, caret: caret)
    return c.makeImage()!
}

let out = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "Tests/PilotCoreTests/ScrollFrames")
for (name, offset, caret) in [("chat-0040", 0, false), ("chat-0051", 0, true), ("chat-0057", scroll, true)] {
    let url = out.appendingPathComponent(name + ".png")
    let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)!
    CGImageDestinationAddImage(dest, frame(offset: offset, caret: caret), nil)
    precondition(CGImageDestinationFinalize(dest))
    print(url.path)
}
