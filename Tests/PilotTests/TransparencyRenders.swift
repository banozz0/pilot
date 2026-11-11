#if DEBUG
import AppKit
import CoreImage
@testable import Clipboard
import Foundation
import PilotCore
import SwiftUI
import Testing
@testable import Pilot

/// Transparency (Sven, 2026-10-08, design round 15), opt-in like the other renders: Home at 1440 by 900 on Glass,
/// under Instrument and Toybox at Transparency 0, 50 and 100 %, in Tokyo Night and in Porcelain. An offscreen draw
/// cannot capture the window's blur, so the content is composited over the wallpaper at PILOT_WALLPAPER blurred in
/// CoreImage, under the ground's tint at its strength (whole while the window is solid). Seeded in a moved home with
/// Home's renders' fakes; nothing reaches the tiler, the clipboard or the timer.
/// `CFFIXED_USER_HOME=<fresh dir> PILOT_RENDER_DIR=<fresh dir> PILOT_WALLPAPER=<image> swift test --filter TransparencyRenders`
extension SharedLook {
@MainActor
@Suite("Transparency renders")
struct TransparencyRenders {
    nonisolated static let env = ProcessInfo.processInfo.environment

    @Test("Home in each style at Transparency 0, 50 and 100 % on Glass, dark and light",
          .enabled(if: env["PILOT_RENDER_DIR"] != nil && env["CFFIXED_USER_HOME"] != nil && env["PILOT_WALLPAPER"] != nil))
    func render() throws {
        let home = try #require(Self.env["CFFIXED_USER_HOME"])
        try #require((NSHomeDirectory() as NSString).resolvingSymlinksInPath == (home as NSString).resolvingSymlinksInPath,
                     "the home directory did not move; refusing to start an engine on Sven's data")
        let dir = URL(fileURLWithPath: try #require(Self.env["PILOT_RENDER_DIR"])).appendingPathComponent("transparency")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        testApp()
        DisplayFaces.directory = LookThemeTests.fonts
        DisplayFaces.register()
        let toml = (home as NSString).appendingPathComponent(".aerospace.toml")
        if !FileManager.default.fileExists(atPath: toml) { FileManager.default.createFile(atPath: toml, contents: Data()) }

        let engine = try HomeRenders.engine()
        SharedLook.StatsRenders.seed(SystemSampler.shared)
        var sources = HomeSources()
        sources.lastCopied = { HomeCopy(text: "pilot://open?page=look", at: Date().addingTimeInterval(-125), count: 48) }
        sources.recentCopies = { InstrumentRenders.clips }

        let only = Self.env["PILOT_RENDER_ONLY"]
        func wanted(_ name: String) -> Bool { only.map(name.contains) ?? true }

        let look = Look.shared
        defer {
            look.themeID = PilotTheme.defaultID; look.style = .instrument
            look.glass = false; look.transparency = 33
        }
        let size = NSSize(width: 1440, height: 900)
        let wall = try Self.blurredWallpaper(URL(fileURLWithPath: try #require(Self.env["PILOT_WALLPAPER"])), size: size)

        for theme in ["tokyo-night", "porcelain"] {
            for style in PilotStyle.allCases {
                for transparency in [0, 50, 100] {
                    let name = "transparency-\(style.rawValue)-\(theme)-\(String(format: "%03d", transparency))"
                    guard wanted(name) else { continue }
                    look.themeID = theme
                    look.style = style
                    look.glass = true
                    look.transparency = transparency
                    // A fresh window per shot, so none keeps the last one's drawing.
                    let model = AppWindowModel(defaults: try #require(UserDefaults(suiteName: testSuite())))
                    let window = AppWindowController.makeWindow(content: NSHostingView(rootView: AppWindowView(model: model)
                        .environment(engine).environment(\.homeSources, sources)))
                    defer { window.close() }
                    let backdrop = try #require(window.contentView as? MaterialBackdrop)
                    window.setContentSize(size)
                    model.go(AppPlace(.home))
                    AppWindowController.applyLook(look, to: window)
                    RunLoop.main.run(until: Date().addingTimeInterval(0.9))
                    backdrop.layoutSubtreeIfNeeded()
                    let content = try #require(snapshot(backdrop.content, scale: 1)?.cgImage)
                    // Behind the content: the blurred wallpaper under the ground's tint, or the ground whole while solid.
                    let solid = window.isOpaque
                    let ground = (window.isOpaque ? window.backgroundColor : (backdrop.effect as? NSGlassEffectView)?.tintColor)?
                        .usingColorSpace(.sRGB) ?? .black
                    let w = Int(size.width), h = Int(size.height)
                    let ctx = try #require(CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                                     space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                                     bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
                    let rect = CGRect(x: 0, y: 0, width: w, height: h)
                    ctx.draw(wall, in: rect)
                    ctx.setFillColor((solid ? ground.withAlphaComponent(1) : ground).cgColor)
                    ctx.fill(rect)
                    ctx.draw(content, in: rect)
                    let out = NSBitmapImageRep(cgImage: try #require(ctx.makeImage()))
                    try #require(out.representation(using: .png, properties: [:])).write(to: dir.appendingPathComponent("\(name).png"))
                }
            }
        }
    }

    /// The wallpaper cropped to fill `size`, blurred and lifted in saturation as macOS's window material shows it.
    static func blurredWallpaper(_ url: URL, size: NSSize) throws -> CGImage {
        let image = try #require(CIImage(contentsOf: url))
        let scale = max(size.width / image.extent.width, size.height / image.extent.height)
        let scaled = image.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        let crop = CGRect(x: (scaled.extent.width - size.width) / 2, y: (scaled.extent.height - size.height) / 2,
                          width: size.width, height: size.height)
        let blurred = scaled.clampedToExtent().applyingGaussianBlur(sigma: 30)
            .applyingFilter("CIColorControls", parameters: [kCIInputSaturationKey: 1.35])
            .cropped(to: crop)
            .transformed(by: CGAffineTransform(translationX: -crop.minX, y: -crop.minY))
        return try #require(CIContext().createCGImage(blurred, from: CGRect(origin: .zero, size: size)))
    }
}
}
#endif
