import CoreGraphics
import Foundation
import Testing
@testable import ImageScale

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

@Suite("Image files")
struct ImageFilesTests {
    static func noise(_ w: Int, _ h: Int, alpha: Bool = false) -> PixelBuffer {
        let b = PixelBuffer(width: w, height: h, space: CGColorSpace(name: CGColorSpace.sRGB)!, hasAlpha: alpha)
        var seed: UInt32 = 7
        for i in 0..<b.bytes.count where alpha || i % 4 != 3 {
            seed = seed &* 1_664_525 &+ 1_013_904_223
            b.bytes[i] = UInt8(truncatingIfNeeded: seed >> 24)
        }
        return b
    }

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
        let image = try #require(Self.noise(300, 200).image())
        let out = try #require(Resample.image(image, width: 150, height: 37))
        #expect(out.width == 150 && out.height == 37)
    }
}
