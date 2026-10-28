// Draws the DMG window's background (SH24, Sven's pick A: the Hyper keycap is the arrow) from layout.json beside it.
//   swift Packaging/dmg/draw-background.swift   writes background.png (72 dpi) and background@2x.png (144 dpi) here
// layout.json is the one source for the window size and both icon centres (points, from the top left); the release
// script's dmgbuild settings read the same file (SH25). Finder draws the icon labels in black, in dark mode too, so
// the ground stays light. Geist and Geist Mono come from Packaging/Fonts, never from what this Mac has installed.
import AppKit

let here = URL(filePath: #filePath).absoluteURL.deletingLastPathComponent()
let fonts = here.deletingLastPathComponent().appending(path: "Fonts")

struct Layout: Decodable {
    struct Size: Decodable { let width, height: CGFloat }
    struct Point: Decodable { let x, y: CGFloat }
    let window: Size
    let icon_size: CGFloat
    let icons: [String: Point]
}
let layout = try JSONDecoder().decode(Layout.self, from: Data(contentsOf: here.appending(path: "layout.json")))
guard let pilot = layout.icons["Pilot.app"], let apps = layout.icons["Applications"] else { fatalError("layout.json names Pilot.app and Applications") }

for name in ["Geist/Geist.ttf", "GeistMono/GeistMono.ttf"] {
    var error: Unmanaged<CFError>?
    if !CTFontManagerRegisterFontsForURL(fonts.appending(path: name) as CFURL, .process, &error) {
        fatalError("could not load \(name): \(String(describing: error?.takeRetainedValue()))")
    }
}
func font(_ family: String, _ size: CGFloat, _ weight: NSFont.Weight) -> NSFont {
    let descriptor = NSFontDescriptor(fontAttributes: [.family: family, .traits: [NSFontDescriptor.TraitKey.weight: weight]])
    guard let font = NSFont(descriptor: descriptor, size: size), font.familyName == family else { fatalError("\(family) did not load") }
    return font
}

func rgb(_ hex: UInt32, _ alpha: CGFloat = 1) -> NSColor {
    NSColor(srgbRed: CGFloat(hex >> 16 & 0xFF) / 255, green: CGFloat(hex >> 8 & 0xFF) / 255, blue: CGFloat(hex & 0xFF) / 255, alpha: alpha)
}
// The site's tokens (site/index.html): ground, lime, its edge and lip, ink, and the second ink for the quiet half of the copy.
let ground = rgb(0xF6F6F4), lime = rgb(0xC6F432), limeEdge = rgb(0xB5E024), limeLip = rgb(0xA8D21C)
let ink = rgb(0x15181C), ink2 = rgb(0x55555B)

/// Drawn in points, y down, so the numbers match Finder's icon positions.
func draw() {
    let size = CGSize(width: layout.window.width, height: layout.window.height)
    ground.setFill()
    CGRect(origin: .zero, size: size).fill()

    // The keycap: centred between the two icons, on their row; the site's HYPER key with an arrow for its glyph.
    let key = CGRect(x: (pilot.x + apps.x) / 2 - 40, y: pilot.y - 30, width: 80, height: 60)
    let radius: CGFloat = 12
    func cap(_ rect: CGRect) -> NSBezierPath { NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius) }
    limeEdge.setFill()
    NSBezierPath(roundedRect: key.insetBy(dx: -1, dy: -1), xRadius: radius + 1, yRadius: radius + 1).fill()
    NSGraphicsContext.saveGraphicsState()
    cap(key).addClip()
    limeLip.setFill()
    key.fill()
    lime.setFill()
    cap(key.offsetBy(dx: 0, dy: -5)).fill()  // the lip: 5 pt of the darker lime left along the bottom
    let shine = NSBezierPath(rect: key.insetBy(dx: -2, dy: -2))
    shine.append(cap(key.offsetBy(dx: 0, dy: 1)))
    shine.windingRule = .evenOdd
    NSColor(white: 1, alpha: 0.6).setFill()
    shine.fill()  // 1 pt of light along the top edge
    NSGraphicsContext.restoreGraphicsState()

    // The glyph: a right arrow, top left of the key, as the site's keycap carries its up arrow.
    let glyph = NSBezierPath()
    let g = CGPoint(x: key.minX + 12, y: key.minY + 10)
    glyph.move(to: CGPoint(x: g.x + 2, y: g.y + 9)); glyph.line(to: CGPoint(x: g.x + 18, y: g.y + 9))
    glyph.move(to: CGPoint(x: g.x + 12, y: g.y + 3)); glyph.line(to: CGPoint(x: g.x + 18, y: g.y + 9))
    glyph.line(to: CGPoint(x: g.x + 12, y: g.y + 15))
    glyph.lineWidth = 2.2
    glyph.lineCapStyle = .round
    glyph.lineJoinStyle = .round
    ink.setStroke()
    glyph.stroke()

    // The legend: DRAG in Geist Mono small capitals, bottom left, as HYPER sits on the site's key.
    let legendFont = font("Geist Mono", 10, .semibold)
    let legend = NSAttributedString(string: "DRAG", attributes: [.font: legendFont, .foregroundColor: ink, .kern: 1.2])
    legend.draw(at: CGPoint(x: key.minX + 12, y: key.maxY - 13.5 - legendFont.ascender))

    // The one line of copy, centred below the labels Finder draws (about 70 to 90 pt under each icon's centre).
    let copyFont = font("Geist", 14, .regular)
    let copy = NSMutableAttributedString(string: "Drag Pilot to Applications.", attributes: [
        .font: font("Geist", 14, .medium), .foregroundColor: ink,
    ])
    copy.append(NSAttributedString(string: " Then hold Hyper.", attributes: [.font: copyFont, .foregroundColor: ink2]))
    let width = copy.size().width
    copy.draw(at: CGPoint(x: (size.width - width) / 2, y: 330))
}

for scale in [1, 2] {
    let w = Int(layout.window.width) * scale, h = Int(layout.window.height) * scale
    guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: w, pixelsHigh: h, bitsPerSample: 8, samplesPerPixel: 4,
                                     hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
          let context = NSGraphicsContext(bitmapImageRep: rep) else { fatalError("no bitmap") }
    rep.size = CGSize(width: layout.window.width, height: layout.window.height)  // 72 dpi at 1x, 144 dpi at 2x
    let cg = context.cgContext
    cg.translateBy(x: 0, y: CGFloat(h))
    cg.scaleBy(x: CGFloat(scale), y: -CGFloat(scale))
    NSGraphicsContext.current = NSGraphicsContext(cgContext: cg, flipped: true)
    draw()
    NSGraphicsContext.current = nil
    let out = here.appending(path: scale == 1 ? "background.png" : "background@2x.png")
    try rep.converting(to: .sRGB, renderingIntent: .default)!.representation(using: .png, properties: [:])!.write(to: out)
    print("wrote \(out.path(percentEncoded: false)) (\(w)x\(h))")
}
