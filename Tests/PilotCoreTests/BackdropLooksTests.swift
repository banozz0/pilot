import CoreGraphics
import Foundation
import PilotCore
import Testing

/// Capture looks and output (T27; editors round 2, C1, C2, C8, C9, C11): the exports and saved settings they make.
@Suite("Backdrop looks and output")
struct BackdropLooksTests {
    /// A `w` × `h` picture of `ground` with a `core` square in its middle.
    static func picture(_ w: Int, _ h: Int, ground: UInt32, core: UInt32? = nil) -> CGImage {
        let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)!
        ctx.setFillColor(Self.colour(ground))
        ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        if let core {
            ctx.setFillColor(Self.colour(core))
            ctx.fill(CGRect(x: w / 4, y: h / 4, width: w / 2, height: h / 2))
        }
        return ctx.makeImage()!
    }

    static func colour(_ rgb: UInt32) -> CGColor {
        CGColor(srgbRed: CGFloat(rgb >> 16 & 0xFF) / 255, green: CGFloat(rgb >> 8 & 0xFF) / 255, blue: CGFloat(rgb & 0xFF) / 255, alpha: 1)
    }

    /// The pixel at `x`, `y` from the top left, as 0xRRGGBB.
    static func pixel(_ image: CGImage, _ x: Int, _ y: Int) -> UInt32 { PixelGrid(image)?.rgb(x: x, y: y) ?? 0 }

    static func near(_ a: UInt32, _ b: UInt32, by d: Int = 6) -> Bool {
        [16, 8, 0].allSatisfy { abs(Int(a >> UInt32($0) & 0xFF) - Int(b >> UInt32($0) & 0xFF)) <= d }
    }

    @Test("A preset saved before balance and places reads back whole, and a new one round-trips")
    func oldPresetDecodes() throws {
        let old = #"[{"id":"6F1C2D3E-0000-4000-8000-000000000001","name":"Preset 1","backdrop":{"fill":{"gradient":{"_0":[16711680,255]}},"blur":"off","pad":48,"radius":12,"shadow":0.5,"ratio":"16:9","portrait":false}}]"#
        let presets = try JSONDecoder().decode([BackdropPreset].self, from: Data(old.utf8))
        #expect(presets.count == 1)
        #expect(presets[0].backdrop.ratio == .wide)
        #expect(presets[0].backdrop.balance == false)
        #expect(presets[0].backdrop.place == nil)
        let new = Backdrop(fill: .colour(0x123456), pad: 32, ratio: .square, balance: true, place: .linkedin)
        #expect(try JSONDecoder().decode(Backdrop.self, from: JSONEncoder().encode(new)) == new)
    }

    @Test("Auto balance takes the capture's edge colour for the padding")
    func balance() throws {
        let capture = Self.picture(400, 300, ground: 0xF2E8D5, core: 0x101010)
        let edge = MarkupRenderer.edgeColour(capture)
        #expect(Self.near(edge, 0xF2E8D5), "edge \(String(edge, radix: 16))")
        let look = try #require(BackdropPreset.looks.first { $0.backdrop.balance })
        let framed = try #require(MarkupRenderer.framed(capture, look.backdrop, scale: 2))
        #expect(Self.near(Self.pixel(framed, 2, 2), 0xF2E8D5), "corner \(String(Self.pixel(framed, 2, 2), radix: 16))")
        #expect(look.backdrop.resolved(for: capture).sameLook(look.backdrop))
    }

    @Test("Sized for a place: the export has the place's pixels and the capture keeps its shape")
    func places() throws {
        let capture = Self.picture(1200, 400, ground: 0x2266DD)
        for place in Backdrop.Place.allCases {
            let b = Backdrop(fill: .colour(0xFFFFFF), pad: 40, radius: 0, shadow: 0, place: place)
            let out = try #require(MarkupRenderer.framed(capture, b, scale: 2))
            #expect(CGSize(width: out.width, height: out.height) == place.pixels, "\(place) \(out.width)×\(out.height)")
            // The capture's middle is the capture's colour; the canvas's shape is the place's, the spot the capture's.
            #expect(Self.near(Self.pixel(out, out.width / 2, out.height / 2), 0x2266DD))
            let area = CGSize(width: 600, height: 200), spot = b.spot(for: area)
            #expect(abs(spot.width / spot.height - 3) < 0.001)
            let canvas = b.canvas(for: area)
            #expect(abs(canvas.width / canvas.height - place.pixels.width / place.pixels.height) < 0.01)
        }
        #expect(Backdrop(fill: .clear, place: .x).pixels(for: CGSize(width: 10, height: 10), scale: 2) == CGSize(width: 1600, height: 900))
    }

    @Test("Each of Pilot's looks frames a capture")
    func looksRender() throws {
        let capture = Self.picture(320, 200, ground: 0xFFFFFF, core: 0x3355AA)
        #expect(Set(BackdropPreset.looks.map(\.id)).count == BackdropPreset.looks.count)
        for look in BackdropPreset.looks {
            let out = try #require(MarkupRenderer.framed(capture, look.backdrop, scale: 2), "\(look.name)")
            #expect(out.width > capture.width && out.height > capture.height, "\(look.name)")
        }
    }

    @Test("A look is found by its id or its name, any case")
    func find() {
        let saved = BackdropPreset(name: "Preset 1", backdrop: Backdrop(fill: .clear))
        #expect(BackdropPreset.find("sunset", in: [])?.name == "Sunset")
        #expect(BackdropPreset.find(saved.id.uuidString, in: [saved]) == saved)
        #expect(BackdropPreset.find("preset 1", in: [saved]) == saved)
        #expect(BackdropPreset.find("Nope", in: [saved]) == nil)
        #expect(BackdropPreset.nextName([]) == "Preset 1")
    }

    @Test("Add a capture: two pictures side by side or stacked in one")
    func combine() throws {
        let a = Self.picture(200, 100, ground: 0xFF0000), b = Self.picture(100, 100, ground: 0x0000FF)
        let side = try #require(CombineLayout.draw([a, b], direction: .sideBySide, gap: 0))
        #expect((side.width, side.height) == (300, 100))
        #expect(Self.near(Self.pixel(side, 10, 50), 0xFF0000))
        #expect(Self.near(Self.pixel(side, 290, 50), 0x0000FF))
        let stacked = try #require(CombineLayout.draw([a, b], direction: .stacked, gap: 0))
        #expect((stacked.width, stacked.height) == (200, 300))
        #expect(Self.near(Self.pixel(stacked, 100, 290), 0x0000FF))
    }

    @Test("Every capture's look is kept with the capture settings; settings saved before it read none")
    func everyCaptureSetting() throws {
        let old = try JSONDecoder().decode(CaptureSettings.self, from: Data(#"{"afterCapture":"editor"}"#.utf8))
        #expect(old.everyCaptureLook == nil)
        #expect(old.afterCapture == .editor)
        var s = CaptureSettings.default
        s.everyCaptureLook = BackdropPreset.looks[0].id.uuidString
        let back = try JSONDecoder().decode(CaptureSettings.self, from: JSONEncoder().encode(s))
        #expect(back.everyCaptureLook == BackdropPreset.looks[0].id.uuidString)
    }
}
