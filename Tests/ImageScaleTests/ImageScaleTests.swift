import CoreGraphics
import Foundation
import Testing
@testable import ImageScale

@Suite("Upscale tiles")
struct UpscaleTilingTests {
    /// A 4x "model" that only repeats each pixel: through the tiles it must give exactly what one pass over the whole
    /// image gives, so any misplaced core, off-by-one context or seam shows as a wrong pixel.
    static func nearest(size: Int) -> Upscale.Model {
        { input, output in
            let o = size * 4
            for c in 0..<3 { for y in 0..<o { for x in 0..<o { output[(c * o + y) * o + x] = input[(c * size + y / 4) * size + x / 4] } } }
        }
    }

    static func noise(_ w: Int, _ h: Int, alpha: Bool = false) -> PixelBuffer {
        let b = PixelBuffer(width: w, height: h, space: CGColorSpace(name: CGColorSpace.sRGB)!, hasAlpha: alpha)
        var seed: UInt32 = 7
        for i in 0..<b.bytes.count where alpha || i % 4 != 3 {
            seed = seed &* 1_664_525 &+ 1_013_904_223
            b.bytes[i] = UInt8(truncatingIfNeeded: seed >> 24)
        }
        return b
    }

    @Test("The plan's cores cover every pixel once, each tile's context reaching pad past its core", arguments: [(300, 170), (64, 64), (49, 300), (1, 1)])
    func plan(_ w: Int, _ h: Int) {
        let plan = TilePlan(width: w, height: h, size: 64, pad: 8)
        var hits = [Int](repeating: 0, count: w * h)
        for t in plan.tiles {
            #expect(t.originX == t.core.x - 8 && t.originY == t.core.y - 8)
            #expect(t.core.width <= 48 && t.core.height <= 48)
            for y in t.core.y..<(t.core.y + t.core.height) { for x in t.core.x..<(t.core.x + t.core.width) { hits[y * w + x] += 1 } }
        }
        #expect(hits.allSatisfy { $0 == 1 })
    }

    @Test("4x through tiles equals 4x of the whole image, pixel for pixel: no seams", arguments: [(300, 170), (37, 90), (5, 3)])
    func seams4x(_ w: Int, _ h: Int) throws {
        let source = Self.noise(w, h)
        var calls = 0
        let out = try Upscale.run(source, tile: 64, pad: 8, scale: 4, model: Self.nearest(size: 64)) { done, total in
            calls += 1
            #expect(done == calls && total == TilePlan(width: w, height: h, size: 64, pad: 8).tiles.count)
        }
        #expect(out.width == w * 4 && out.height == h * 4)
        var wrong = 0
        for y in 0..<out.height {
            for x in 0..<out.width {
                for c in 0..<4 where out.bytes[(y * out.width + x) * 4 + c] != source.bytes[((y / 4) * w + x / 4) * 4 + c] { wrong += 1 }
            }
        }
        #expect(wrong == 0)
    }

    @Test("2x averages the model's 4x in 2 × 2 blocks, so repeated pixels come back as 2x nearest, seamless")
    func seams2x() throws {
        let source = Self.noise(130, 77)
        let out = try Upscale.run(source, tile: 64, pad: 8, scale: 2, model: Self.nearest(size: 64))
        #expect(out.width == 260 && out.height == 154)
        var wrong = 0
        for y in 0..<out.height {
            for x in 0..<out.width where (0..<3).contains(where: { out.bytes[(y * 260 + x) * 4 + $0] != source.bytes[((y / 2) * 130 + x / 2) * 4 + $0] }) { wrong += 1 }
        }
        #expect(wrong == 0)
    }

    @Test("Alpha never goes through the model: it is resampled, and an opaque image stays opaque")
    func alpha() throws {
        let clear = Self.noise(40, 30, alpha: true)
        for i in 0..<(40 * 30) { clear.bytes[i * 4 + 3] = 0 }
        let out = try Upscale.run(clear, tile: 32, pad: 4, scale: 4, model: Self.nearest(size: 32))
        #expect((0..<(out.width * out.height)).allSatisfy { out.bytes[$0 * 4 + 3] == 0 })
        let opaque = try Upscale.run(Self.noise(40, 30), tile: 32, pad: 4, scale: 4, model: Self.nearest(size: 32))
        #expect(!opaque.hasAlpha)
        #expect((0..<(opaque.width * opaque.height)).allSatisfy { opaque.bytes[$0 * 4 + 3] == 255 })
    }

    @Test("A buffer round-trips through its CGImage and back unchanged")
    func roundTrip() throws {
        let b = Self.noise(17, 9)
        let image = try #require(b.image())
        let again = try #require(PixelBuffer(image))
        #expect(Array(again.bytes) == Array(b.bytes))
    }
}

@Suite("Resize maths")
struct ResizeTargetTests {
    @Test("Locked, one side follows the other, rounded; unlocked, each side is its own")
    func lock() {
        var t = ResizeTarget(width: 3440, height: 1440)
        t.setWidth(1920)
        #expect(t.width == 1920 && t.height == 804)
        t.setHeight(1080)
        #expect(t.width == 2580 && t.height == 1080)
        t.locked = false
        t.setWidth(100)
        #expect(t.width == 100 && t.height == 1080)
    }

    @Test("Presets keep the aspect even unlocked, and are read back as a percent")
    func presets() {
        var t = ResizeTarget(width: 1001, height: 333)
        t.locked = false
        t.setPercent(50)
        #expect(t.width == 501 && t.height == 167)
        #expect(t.percent == 50)
        t.setWidth(400)
        #expect(t.percent == nil)
        t.setPercent(200)
        #expect(t.width == 2002 && t.height == 666 && t.percent == 200)
        t.setPercent(100)
        #expect(!t.changed)
    }

    @Test("Sides stay between 1 and the limit; another image takes the same factor")
    func limits() {
        var t = ResizeTarget(width: 3440, height: 1440)
        t.setWidth(0)
        #expect(t.width == 1 && t.height == 1)
        t.setWidth(1_000_000)
        #expect(t.width == ResizeTarget.limit)
        t.setPercent(50)
        #expect(t.applied(width: 1000, height: 600) == (500, 300))
    }
}

@Suite("Upscale size")
struct UpscaleTargetTests {
    @Test("2x, 3x and 4x of the image, read back as the preset; a typed width or height keeps the aspect")
    func presets() {
        var t = UpscaleTarget(width: 1280, height: 720)
        #expect(t.width == 5120 && t.height == 2880 && t.times == 4)
        t.setFactor(3)
        #expect(t.width == 3840 && t.height == 2160 && t.times == 3)
        t.setWidth(2560)
        #expect(t.width == 2560 && t.height == 1440 && t.times == 2)
        t.setWidth(3000)
        #expect(t.width == 3000 && t.height == 1688 && t.times == nil)
        t.setHeight(1000)
        #expect(t.width == 1778 && t.height == 1000)
    }

    @Test("Never under the image's own size nor past 4x or the limit a side")
    func limits() {
        var t = UpscaleTarget(width: 1000, height: 500)
        t.setWidth(200)
        #expect(t.width == 1000 && t.height == 500 && !t.grows)
        t.setWidth(9000)
        #expect(t.width == 4000 && t.height == 2000)
        let wide = UpscaleTarget(width: 5120, height: 2880)
        #expect(wide.width == ResizeTarget.limit && wide.height == 9216, "a 5K capture stops at the limit, aspect kept")
    }

    @Test("The model runs 2x up to 2x, else 4x; the name says 3x or the typed size")
    func pass() {
        #expect(UpscaleTarget.pass(1.5) == 2 && UpscaleTarget.pass(2) == 2)
        #expect(UpscaleTarget.pass(2.01) == 4 && UpscaleTarget.pass(3) == 4 && UpscaleTarget.pass(4) == 4)
        #expect(UpscaleTarget.suffix(from: 1280, 720, to: 3840, 2160) == " 3x")
        #expect(UpscaleTarget.suffix(from: 1280, 720, to: 3000, 1688) == " 3000x1688")
    }

    @Test("Several files: a preset is the same preset on each, a typed size the same factor")
    func applied() {
        var t = UpscaleTarget(width: 1000, height: 500, times: 3)
        #expect(t.applied(width: 333, height: 111) == (999, 333))
        t.setWidth(2500)
        #expect(t.applied(width: 400, height: 300) == (1000, 750))
    }
}

@Suite("Image files")
struct ImageFilesTests {
    @Test("A result goes beside the original under its suffix and never over a file")
    func neverOverwrites() throws {
        let dir = FileManager.default.temporaryDirectory.appending(path: "image-scale-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        try Data("original".utf8).write(to: dir.appending(path: "shot 4x.png"))
        let url = try #require(ImageFiles.write(Data("new".utf8), in: dir, stem: "shot", suffix: " 4x", ext: "png"))
        #expect(url.lastPathComponent == "shot 4x 2.png")
        #expect(try String(contentsOf: dir.appending(path: "shot 4x.png"), encoding: .utf8) == "original")
    }

    @Test("A resized photo keeps its format; anything else is written as PNG")
    func formats() {
        #expect(ImageFormat.of(URL(filePath: "/a/b.JPG")) == .jpeg)
        #expect(ImageFormat.of(URL(filePath: "/a/b.heic")) == .heic)
        #expect(ImageFormat.of(URL(filePath: "/a/b.tiff")) == .png)
        #expect(ImageFormat.jpeg.fileExtension == "jpg")
    }

    @Test("Resampling makes the asked size")
    func resample() throws {
        let image = try #require(UpscaleTilingTests.noise(300, 200).image())
        let out = try #require(Resample.image(image, width: 150, height: 37))
        #expect(out.width == 150 && out.height == 37)
    }
}
