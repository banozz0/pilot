import Accelerate
import AppKit
import CoreGraphics
import ImageIO
import ImageScale
import Observation
import OSLog
import PilotCore

/// Cursor sets (P84; builder spec vault `Projects/Pilot/Cursors 1.1/spec/cursor-effects.md` §1 and §6, route from the
/// research note `Research/Software/Custom cursors on macOS for Pilot.md`): Quiet, Toybox, Duo and Classic (T33, Q816)
/// replace macOS's pointer, I-beam, hands and the rest everywhere, in the set's own colours, the theme's or a fill and
/// outline the user picks (T33, recipe `Cursors 1.1/choices/cursor-designs.notes.md`). macOS has no public way to do
/// this, so every call is a private SkyLight one looked up with dlsym (as `WindowServerBlur` does), and the feature turns
/// itself off when one is missing. Written fresh: Mousecape's code is non-commercial, MaCursor's and oldcursor's GPL-3.0.
let cursorlog = Logger(subsystem: "dev.banozz.pilot", category: "cursor")

/// Look › Cursor's set: macOS's own on a fresh install (Q735). Classic is T32's design C, the one Sven picked (Q816).
enum CursorSetID: String, CaseIterable, Sendable {
    case macOS, quiet, toybox, duo, classic

    var title: String { self == .macOS ? "macOS" : rawValue.capitalized }
}

/// A set's colours: the theme's, re-applied on a theme change, the set's own (Q736), or the user's fill and outline
/// (Q815).
enum CursorColours: String, CaseIterable, Sendable {
    case theme, own, custom

    var title: String {
        switch self {
        case .theme: "Theme"
        case .own: "Design's own"
        case .custom: "Custom"
        }
    }
}

/// Custom's two colours on one set: each `theme` while unpicked, which reads as the theme's own fill or outline for it.
struct CursorCustom: Equatable, Sendable {
    let set: CursorSetID
    var fill: ColourChoice = .theme
    var outline: ColourChoice = .theme

    /// Which of a set's roles take the fill and the outline (the designer's mapping, cursor-designs.notes.md › Custom
    /// colours on Quiet, Toybox and Duo), and the role each reads its theme colour from. Every badge glyph (`b_ink`,
    /// `<badge>_ink`) takes the outline (Q819); a role in neither keeps the theme's colour unless the set derives it.
    struct Roles: Sendable {
        let fill: Set<String>, outline: Set<String>
        var lead = (fill: "body", outline: "rim")
    }

    static let roles: [CursorSetID: Roles] = [
        .quiet: Roles(fill: ["body", "hand", "cellfill", "zoomfill", "lens", "b_alias", "b_ctx", "b_work", "b_copy", "b_no", "b_help"],
                      outline: ["rim", "crease", "glass", "poof", "accent"]),
        .duo: Roles(fill: ["body", "hand", "cellfill", "zoomfill", "poof", "accent"], outline: ["rim", "crease", "glass"]),
        .toybox: Roles(fill: ["sun", "body", "hand", "accent", "b_ctx", "b_work", "b_copy", "b_no", "b_help", "b_alias"],
                       outline: ["ink", "rim", "crease", "lens", "shadow"]),
        .classic: Roles(fill: ["fill"], outline: ["outline"], lead: ("fill", "outline")),
    ]
    /// Duo's shade, its lens and badges: the fill at 62 % over black (gen.py's `mix(fill, "#000000", 0.62)`).
    static let duoShade: Set = ["shade", "lens", "b_alias", "b_copy", "b_ctx", "b_help", "b_no", "b_work"]
    /// Toybox's other candies, lifted toward white until they read at 4.5:1 on the outline (T1 1a).
    static let toyboxCandies: Set = ["lilac", "mint", "coral", "sky", "cellfill", "zoomfill"]

    static func isGlyph(_ role: String) -> Bool { role == "b_ink" || role.hasPrefix("b_") && role.hasSuffix("_ink") }

    /// The fill and outline painted on `set` over `themed` (the theme's palette): each picked colour, or the theme's.
    func colours(_ themed: [String: String]) -> (fill: UInt32, outline: UInt32) {
        let lead = Self.roles[set]?.lead ?? (fill: "body", outline: "rim")
        return (fill.resolved(Contrast.hex(themed[lead.fill] ?? "#111214")), outline.resolved(Contrast.hex(themed[lead.outline] ?? "#FFFFFF")))
    }

    /// `themed` with the two colours on their roles, and the set's own rules for what it derives from them.
    func palette(_ themed: [String: String]) -> [String: String] {
        guard let roles = Self.roles[set] else { return themed }
        let (fill, outline) = colours(themed)
        let (fillHex, outlineHex) = (ColourAnswer.hex(fill), ColourAnswer.hex(outline))
        var p = themed
        for role in themed.keys {
            if roles.fill.contains(role) { p[role] = fillHex } else if roles.outline.contains(role) || Self.isGlyph(role) { p[role] = outlineHex }
        }
        switch set {
        case .duo:
            // Duo's own rules (gen.py): the shade under the fill; the edge white under a dark rim.
            let shade = ColourAnswer.hex(Contrast.hex(Contrast.mix(Contrast.rgb(fill), [0, 0, 0], 0.62)))
            for role in Self.duoShade { p[role] = shade }
            p["edge"] = Contrast.ratio(outline, 0xFFFFFF) < 1.7 ? "#000000" : "#FFFFFF"
        case .toybox:
            for role in Self.toyboxCandies { if let c = themed[role] { p[role] = ColourAnswer.hex(Self.towards(Contrast.hex(c), outline, floor: 4.5)) } }
        default: break
        }
        return p
    }

    /// gen.py's `towards(c, "#FFFFFF", against, floor)`: `c` mixed toward white in 5 % steps until it reads at `floor`.
    static func towards(_ c: UInt32, _ against: UInt32, floor: Double) -> UInt32 {
        var t = 1.0
        func mixed(_ t: Double) -> UInt32 { Contrast.hex(Contrast.mix(Contrast.rgb(c), [255, 255, 255], t)) }
        while Contrast.ratio(mixed(t), against) < floor && t > 0.05 { t -= 0.05 }
        return mixed(t)
    }

    /// Fill against outline under 2:1 reads weak; the page warns and keeps the colours (Q817).
    static let weakRatio = 2.0
}

// MARK: - The artwork

/// The designer's code (spec §1), as given: a set's grey atlas read raw, and one frame built from its layers' colours.
enum CursorArt {
    struct Sheet { let grey: [UInt8]; let width: Int; let height: Int; let bytesPerRow: Int }

    /// A set's atlas at one scale, `<set>@<n>x.webp` (lossless) in `folder`, raw: no colour management touches the grey
    /// values. WebP has no grey format, so ImageIO decodes it as RGBX with R = G = B: the grey is channel 0 (T69).
    static func sheet(_ folder: URL, set: String, scale: Int) -> Sheet? {
        let url = folder.appending(path: "\(set)@\(scale)x.webp")
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil), let img = CGImageSourceCreateImageAtIndex(src, 0, nil),
              img.bitsPerComponent == 8, img.bitsPerPixel == 32, img.alphaInfo == .noneSkipLast,
              img.byteOrderInfo == .orderDefault || img.byteOrderInfo == .order32Big,
              let data = img.dataProvider?.data as Data?, data.count >= img.bytesPerRow * img.height else { return nil }
        let (width, height) = (img.width, img.height)
        var grey = [UInt8](repeating: 0, count: width * height)
        let error = data.withUnsafeBytes { rgbx in
            grey.withUnsafeMutableBytes { out in
                var from = vImage_Buffer(data: UnsafeMutableRawPointer(mutating: rgbx.baseAddress), height: vImagePixelCount(height),
                                         width: vImagePixelCount(width), rowBytes: img.bytesPerRow)
                var to = vImage_Buffer(data: out.baseAddress, height: vImagePixelCount(height), width: vImagePixelCount(width), rowBytes: width)
                return vImageExtractChannel_ARGB8888(&from, &to, 0, vImage_Flags(kvImageNoFlags))
            }
        }
        return error == kvImageNoError ? Sheet(grey: grey, width: width, height: height, bytesPerRow: width) : nil
    }

    /// One frame of a cursor: every layer's colour drawn through its mask, in order. `row` = the cursor's `row` plus
    /// the frame; `colours` = its `layers` looked up in the palette; `px` = 32 x scale.
    static func image(_ s: Sheet, colours: [CGColor], row: Int, px: Int) -> CGImage? {
        let srgb = CGColorSpace(name: CGColorSpace.sRGB)!
        guard let ctx = CGContext(data: nil, width: px, height: px, bitsPerComponent: 8, bytesPerRow: 0, space: srgb,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        let rect = CGRect(x: 0, y: 0, width: px, height: px)
        for (i, colour) in colours.enumerated() {
            var bytes = [UInt8](repeating: 0, count: px * px)
            for y in 0..<px {
                let start = (row * px + y) * s.bytesPerRow + i * px
                guard start + px <= s.grey.count else { return nil }
                bytes.replaceSubrange(y * px..<(y + 1) * px, with: s.grey[start..<start + px])
            }
            guard let provider = CGDataProvider(data: Data(bytes) as CFData),
                  let mask = CGImage(width: px, height: px, bitsPerComponent: 8, bitsPerPixel: 8, bytesPerRow: px,
                                     space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGBitmapInfo(rawValue: 0),
                                     provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent) else { return nil }
            ctx.saveGState()
            ctx.clip(to: rect, mask: mask)          // grey = how much of this layer's colour lands
            ctx.setFillColor(colour)
            ctx.fill(rect)
            ctx.restoreGState()
        }
        return ctx.makeImage()
    }

    /// "#RRGGBB" in sRGB.
    static func colour(_ hex: String) -> CGColor { colour(Contrast.hex(hex)) }
    static func colour(_ v: UInt32) -> CGColor {
        CGColor(srgbRed: CGFloat(v >> 16 & 255) / 255, green: CGFloat(v >> 8 & 255) / 255, blue: CGFloat(v & 255) / 255, alpha: 1)
    }
}

/// `Cursors/cursors.json`: per set, 30 cursors (hotspot in points on a 32 pt canvas, atlas row, frames, layer roles in
/// paint order) and the palettes, `own` plus one per theme id.
struct CursorCatalogue: Decodable, Sendable {
    struct Cursor: Decodable, Sendable {
        let hotspot: [Double]
        let row: Int
        let frames: Int
        let layers: [String]

        /// Its layers' colours in `palette`, in paint order.
        func colours(_ palette: [String: String]) -> [CGColor] { layers.map { CursorArt.colour(palette[$0] ?? "#000000") } }
    }

    struct CursorSet: Decodable, Sendable {
        let name: String
        let cursors: [String: Cursor]
        let palettes: [String: [String: String]]

        /// The set's own colours, the theme's (an unknown theme id falls back to `own`, spec §1), or Custom's two on
        /// top of the theme's; Custom without its colours reads as the theme's.
        func palette(_ colours: CursorColours, theme: String, custom: CursorCustom? = nil, resolved: PilotTheme? = nil) -> [String: String] {
            let own = palettes["own"] ?? [:]
            guard colours != .own else { return own }
            let themed: [String: String]
            if let resolved {
                // Preserve each designed atlas's role mapping; replace Lagoon's semantic colours by content.
                let reference = PilotTheme.standard
                let pairs: [(UInt32, UInt32)] = [(reference.sidebar, resolved.sidebar), (reference.text, resolved.text),
                    (reference.accent, resolved.accent), (reference.second, resolved.second), (reference.third, resolved.third),
                    (reference.problem, resolved.problem), (reference.surface, resolved.surface),
                    (0x1B7A95, Contrast.hex(Contrast.mix(Contrast.rgb(resolved.accent), [0, 0, 0], 0.62)))]
                let mapping = Dictionary(pairs.map { (ColourAnswer.hex($0.0).lowercased(), ColourAnswer.hex($0.1)) }, uniquingKeysWith: { first, _ in first })
                themed = (palettes["lagoon"] ?? own).mapValues { mapping[$0.lowercased()] ?? $0 }
            } else { themed = palettes[theme].map { $0.merging(own) { picked, _ in picked } } ?? own }
            guard colours == .custom, let custom else { return themed }
            return custom.palette(themed)
        }
    }

    let canvasPoints: Int
    let scales: [Int]
    let frameSeconds: Double
    let sets: [String: CursorSet]

    /// The sets shipped in the app's Resources (`Packaging/Cursors`), else in the renders' copy of them.
    static var folder: URL? { BundledJSON.folder("Cursors") }

    static func load(_ folder: URL) -> CursorCatalogue? {
        do { return try JSONDecoder().decode(CursorCatalogue.self, from: Data(contentsOf: folder.appending(path: "cursors.json"))) } catch {
            cursorlog.error("cursors.json: \(String(describing: error), privacy: .public)")
            return nil
        }
    }

    /// One cursor at one scale, every frame stacked top to bottom in one image: the shape each image in
    /// `CGSRegisterCursorWithImages`' array takes (Mousecape's representations, one per scale).
    static func strip(_ sheet: CursorArt.Sheet, cursor: Cursor, palette: [String: String], px: Int) -> CGImage? {
        let colours = cursor.colours(palette)
        guard let ctx = CGContext(data: nil, width: px, height: px * cursor.frames, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        for frame in 0..<cursor.frames {
            guard let image = CursorArt.image(sheet, colours: colours, row: cursor.row + frame, px: px) else { return nil }
            // Frame 0 on top: CoreGraphics counts up from the bottom.
            ctx.draw(image, in: CGRect(x: 0, y: (cursor.frames - 1 - frame) * px, width: px, height: px))
        }
        return ctx.makeImage()
    }
}

// MARK: - macOS's cursor names

/// Each of the designer's 30 cursors under the system names it stands for: Mousecape's name table (`MCDefs.m`, read
/// 2026-11-03), plus the `S` names macOS 26 draws the arrow and I-beam from (Mousecape #287, #308); on 27.0 the old
/// `Arrow` and `IBeam` register but are ignored, so both forms go in. `com.apple.cursor.20`, Cell XOR, also drew
/// crosshairs in some capes on 26 (#287); it takes the cell here. Counting Up and Down, Resize Square and Empty keep
/// macOS's.
enum CursorNames {
    static let coreGraphics = "com.apple.coregraphics."
    static func numbered(_ n: Int) -> String { "com.apple.cursor.\(n)" }

    static let byCursor: [String: [String]] = [
        "arrow": [coreGraphics + "Arrow", coreGraphics + "ArrowS"],
        "ibeam": [coreGraphics + "IBeam", coreGraphics + "IBeamS", coreGraphics + "IBeamXOR"],
        "ibeam-vertical": [numbered(26)],
        "pointing-hand": [numbered(13), numbered(2)],     // Pointing, Link
        "open-hand": [numbered(12)],
        "closed-hand": [numbered(11)],
        "crosshair": [numbered(7), numbered(8)],
        "cell": [numbered(41), numbered(20)],             // Cell, Cell XOR
        "move": [coreGraphics + "Move"],
        "busy": [coreGraphics + "Wait"],                  // the spinning wheel
        "working": [numbered(4)],                         // Busy: the arrow with a spinner
        "not-allowed": [numbered(3)],                     // Forbidden
        "context-menu": [coreGraphics + "ArrowCtx", numbered(24)],
        "copy": [coreGraphics + "Copy", numbered(5)],     // Copy, Copy Drag
        "alias": [coreGraphics + "Alias"],
        "help": [numbered(40)],
        "zoom-in": [numbered(42)],
        "zoom-out": [numbered(43)],
        "poof": [numbered(25)],
        "camera": [numbered(10), numbered(9)],
        "resize-ew": [numbered(28)],                      // Window E-W
        "resize-ns": [numbered(32)],                      // Window N-S
        "resize-nwse": [numbered(34), numbered(33), numbered(35)],   // Window NW-SE, NW, SE
        "resize-nesw": [numbered(30), numbered(29), numbered(37)],   // Window NE-SW, NE, SW
        "resize-col": [numbered(19)],                     // Resize W-E, a column's edge
        "resize-row": [numbered(23)],                     // Resize N-S, a row's edge
        "resize-e": [numbered(18), numbered(27)],
        "resize-w": [numbered(17), numbered(38)],
        "resize-n": [numbered(21), numbered(31)],
        "resize-s": [numbered(22), numbered(36)],
    ]
}

// MARK: - The private calls

/// SkyLight's cursor calls (CoreGraphics re-exports the CGS names) and HIServices' CoreCursor ones, looked up once;
/// nil when any is missing, and the sets are then off. Shapes from the zlib-licensed `CGSCursor.h`.
struct CursorCalls: @unchecked Sendable {
    typealias MainConnection = @convention(c) () -> Int32
    typealias Register = @convention(c) (Int32, UnsafePointer<CChar>, Bool, Bool, CGSize, CGPoint, UInt, CGFloat, CFArray,
                                         UnsafeMutablePointer<Int32>) -> Int32
    typealias Remove = @convention(c) (Int32, UnsafePointer<CChar>, Bool) -> Int32
    typealias CopyImages = @convention(c) (Int32, UnsafePointer<CChar>, UnsafeMutablePointer<CGSize>, UnsafeMutablePointer<CGPoint>,
                                           UnsafeMutablePointer<UInt>, UnsafeMutablePointer<CGFloat>,
                                           UnsafeMutablePointer<Unmanaged<CFArray>?>) -> Int32
    typealias DockOverride = @convention(c) (Int32, Bool) -> Void
    typealias UnregisterAll = @convention(c) (Int32) -> Int32
    typealias CoreSet = @convention(c) (Int32, Int32) -> Int32

    let connection: MainConnection
    let register: Register
    let remove: Remove
    let copyImages: CopyImages
    let dockOverride: DockOverride
    let unregisterAll: UnregisterAll
    let coreSet: CoreSet

    /// Every symbol the engine calls; the probe and `loaded` read the same list.
    static let symbols = ["CGSMainConnectionID", "CGSRegisterCursorWithImages", "CGSRemoveRegisteredCursor", "CGSCopyRegisteredCursorImages",
                          "CGSSetDockCursorOverride", "CoreCursorUnregisterAll", "CoreCursorSet"]

    /// Opened by path, so what a process happens to have loaded does not decide it.
    private static let libraries = [
        "/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight",
        "/System/Library/Frameworks/CoreGraphics.framework/CoreGraphics",
        "/System/Library/Frameworks/ApplicationServices.framework/Frameworks/HIServices.framework/HIServices",
    ]

    static func symbol(_ name: String) -> UnsafeMutableRawPointer? {
        for path in libraries {
            if let handle = dlopen(path, RTLD_LAZY | RTLD_NOLOAD) ?? dlopen(path, RTLD_LAZY), let found = dlsym(handle, name) { return found }
        }
        return nil
    }

    /// Each symbol and whether it resolves, looked up only, nothing called; logged, for the probe on each macOS release.
    static func probe() -> [(name: String, found: Bool)] {
        let found = symbols.map { ($0, symbol($0) != nil) }
        let os = ProcessInfo.processInfo.operatingSystemVersionString
        for (name, ok) in found { cursorlog.notice("cursor probe on \(os, privacy: .public): \(name, privacy: .public) \(ok ? "found" : "MISSING", privacy: .public)") }
        return found
    }

    static let loaded: CursorCalls? = {
        let found = symbols.map(symbol)
        guard found.allSatisfy({ $0 != nil }) else {
            let missing = zip(symbols, found).filter { $0.1 == nil }.map(\.0)
            cursorlog.error("cursor: \(missing.joined(separator: ", "), privacy: .public) not found, cursor sets are off")
            return nil
        }
        let p = found.map { $0! }
        return CursorCalls(connection: unsafeBitCast(p[0], to: MainConnection.self), register: unsafeBitCast(p[1], to: Register.self),
                           remove: unsafeBitCast(p[2], to: Remove.self), copyImages: unsafeBitCast(p[3], to: CopyImages.self),
                           dockOverride: unsafeBitCast(p[4], to: DockOverride.self), unregisterAll: unsafeBitCast(p[5], to: UnregisterAll.self),
                           coreSet: unsafeBitCast(p[6], to: CoreSet.self))
    }()

    struct Registered {
        let size: CGSize, hotspot: CGPoint, frames: Int, duration: CGFloat
        /// One per scale, frames stacked.
        let images: [CGImage]
    }
}

/// What the engine reads and writes of the system's cursors: SkyLight's calls in Pilot.app, a fake in the tests, so no
/// test registers a real cursor.
protocol CursorSystem: Sendable {
    /// What is registered under `name` now; nil when nothing is.
    func read(_ name: String) -> CursorCalls.Registered?
    /// Registers `cursor` under `name` for the whole session, at once; 0 when it took.
    func register(_ name: String, _ cursor: CursorCalls.Registered) -> Int32
    /// Removes a numbered `com.apple.cursor.*` name (the `com.apple.coregraphics.*` ones answer 1000 on 27).
    func remove(_ name: String)
    /// CoreCursor's own reset: everything unregistered, then each of its cursors set back.
    func resetCoreCursors() -> Int32
    func dockOverride(_ on: Bool)
}

/// The real calls on the main connection.
struct LiveCursors: CursorSystem {
    let calls: CursorCalls
    let cid: Int32

    init?() {
        guard let calls = CursorCalls.loaded else { return nil }
        self.calls = calls
        cid = calls.connection()
    }

    func read(_ name: String) -> CursorCalls.Registered? {
        var size = CGSize.zero, hotspot = CGPoint.zero, frames: UInt = 0, duration: CGFloat = 0
        var images: Unmanaged<CFArray>?
        let status = name.withCString { calls.copyImages(cid, $0, &size, &hotspot, &frames, &duration, &images) }
        guard status == 0, let array = images?.takeRetainedValue() as? [CGImage], !array.isEmpty else { return nil }
        return .init(size: size, hotspot: hotspot, frames: Int(frames), duration: duration, images: array)
    }

    func register(_ name: String, _ c: CursorCalls.Registered) -> Int32 {
        var seed: Int32 = 0
        return name.withCString { calls.register(cid, $0, true, true, c.size, c.hotspot, UInt(c.frames), c.duration, c.images as CFArray, &seed) }
    }

    func remove(_ name: String) { _ = name.withCString { calls.remove(cid, $0, false) } }

    func resetCoreCursors() -> Int32 {
        let unregistered = calls.unregisterAll(cid)
        // Each CoreCursorSet also sets Pilot's own current cursor: end on 0, the arrow in Mousecape's numbering, not 44 (T31).
        for n in (Int32(0)..<45).reversed() { _ = calls.coreSet(cid, n) }
        return unregistered
    }

    func dockOverride(_ on: Bool) { calls.dockOverride(cid, on) }
}

// MARK: - The backup of macOS's own cursors

/// macOS's own `com.apple.coregraphics.*` cursors as they were before Pilot's first apply, on disk, so Restore can put
/// back the names `CGSRemoveRegisteredCursor` will not remove (it answers 1000 on 27, Mousecape #308). It is the gate:
/// Pilot registers such a name only while this macOS build's backup holds it, so Restore can always undo what Pilot did.
struct CursorBackup: Codable {
    struct Cursor: Codable {
        let name: String
        let width, height, hotX, hotY: Double
        let frames: Int
        let duration: Double
        /// PNGs, one per scale.
        let images: [Data]

        init?(_ name: String, _ registered: CursorCalls.Registered) {
            let pngs = registered.images.compactMap(ImageFormat.png.encode)
            guard !pngs.isEmpty, pngs.count == registered.images.count else { return nil }
            self.name = name
            (width, height) = (registered.size.width, registered.size.height)
            (hotX, hotY) = (registered.hotspot.x, registered.hotspot.y)
            (frames, duration) = (registered.frames, registered.duration)
            images = pngs
        }

        /// The cursor as saved, or nil when a PNG no longer decodes.
        var registered: CursorCalls.Registered? {
            let decoded = images.compactMap(CursorBackup.image)
            guard !decoded.isEmpty, decoded.count == images.count else { return nil }
            return .init(size: CGSize(width: width, height: height), hotspot: CGPoint(x: hotX, y: hotY), frames: frames,
                         duration: duration, images: decoded)
        }
    }

    let build: String
    let cursors: [Cursor]

    static var url: URL { PilotFolder.support.appending(path: "Cursors/macOS backup.plist") }

    /// macOS's version and build ("Version 27.2 (Build 27C52)"): a new build can bring new cursors.
    static let osBuild = ProcessInfo.processInfo.operatingSystemVersionString

    /// The backup saved for `build`; one from another macOS build reads as none.
    static func load(_ url: URL, build: String) -> CursorBackup? {
        guard let data = try? Data(contentsOf: url), let backup = try? PropertyListDecoder().decode(CursorBackup.self, from: data) else { return nil }
        return backup.build == build ? backup : nil
    }

    func save(_ url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = PropertyListEncoder()
        encoder.outputFormat = .binary
        try encoder.encode(self).write(to: url, options: .atomic)
    }

    static func image(_ png: Data) -> CGImage? {
        CGImageSourceCreateWithData(png as CFData, nil).flatMap { CGImageSourceCreateImageAtIndex($0, 0, nil) }
    }

    /// The names it holds: each encoded when it was taken.
    var held: Set<String> { Set(cursors.map(\.name)) }

    /// Holds every name Pilot may register; a backup that does not is retaken while nothing of Pilot's is registered.
    var complete: Bool { held.isSuperset(of: CursorNames.coreGraphicsNames) }

    /// The cursors Restore puts back, by name, decoded; one whose PNG no longer decodes is left out and counted.
    func decoded() -> [String: CursorCalls.Registered] {
        Dictionary(cursors.compactMap { c in c.registered.map { (c.name, $0) } }, uniquingKeysWith: { first, _ in first })
    }
}

extension CursorNames {
    /// The names only the backup can put back.
    static let coreGraphicsNames = Set(byCursor.values.joined().filter { $0.hasPrefix(coreGraphics) })
}

/// Where the engine keeps its state, and which macOS build and boot this is. `applied` = Pilot's art may be registered in
/// this boot: it is stamped with `kern.bootsessionuuid` before the first register and cleared only by a full Restore, so
/// a restart (macOS updates restart) reads as not applied and a stale backup is retaken. Registrations last a login
/// session, so after a logout alone the stamp still reads applied: the safe side, the saved backup serves.
struct CursorPlace: @unchecked Sendable {   // UserDefaults is thread-safe
    static let appliedKey = "look.cursorApplied"

    let backupURL: URL
    let build: String
    let session: String
    let defaults: UserDefaults

    var applied: Bool { defaults.string(forKey: Self.appliedKey) == session }
    func stamp(_ applied: Bool) {
        if applied { defaults.set(session, forKey: Self.appliedKey) } else { defaults.removeObject(forKey: Self.appliedKey) }
    }

    /// This boot. Were the UUID ever missing, every boot reads as one: the backup gate alone then keeps Restore whole.
    static let bootSession = SystemReader.sysctlString("kern.bootsessionuuid") ?? "unknown"

    static func live(_ defaults: UserDefaults) -> CursorPlace {
        CursorPlace(backupURL: CursorBackup.url, build: CursorBackup.osBuild, session: bootSession, defaults: defaults)
    }
}

// MARK: - Apply and restore

/// The work itself, off the main thread (the bind tap shares it) on one serial queue, so an apply and a restore never
/// interleave and the applied stamp is written in order. Only `CursorSets.shared` in Pilot.app reaches it with the
/// real calls; the tests pass a fake `CursorSystem`.
enum CursorEngine {
    static let queue = DispatchQueue(label: "dev.banozz.pilot.cursor", qos: .userInitiated)

    /// Registers `set` in `colours` (the theme `theme`'s when it follows the theme), each cursor under every name it
    /// stands for, read back to confirm; then the Dock override. macOS's own are backed up first, and a
    /// `com.apple.coregraphics.*` name the backup does not hold keeps macOS's cursor. Returns the page's line.
    static func apply(_ set: CursorSetID, colours: CursorColours, theme: String, custom: CursorCustom? = nil, resolved: PilotTheme? = nil, system: (any CursorSystem)?,
                      place: CursorPlace, folder: URL? = CursorCatalogue.folder) -> String {
        guard let system else { return "This macOS lacks the private calls cursor sets need, so they are off." }
        guard let folder, let catalogue = CursorCatalogue.load(folder), let art = catalogue.sets[set.rawValue] else {
            return "The cursor sets are missing from Pilot's Resources."
        }
        let held: Set<String>
        do { held = try backUp(system, place: place).held } catch { return error.line }
        let palette = art.palette(colours, theme: theme, custom: custom, resolved: resolved)
        let points = CGFloat(catalogue.canvasPoints)
        var sheets = [Int: CursorArt.Sheet]()
        for scale in catalogue.scales { sheets[scale] = CursorArt.sheet(folder, set: set.rawValue, scale: scale) }
        place.stamp(true)    // before the first register, so even a crash part-way leaves it set
        var names = 0, confirmed = 0, kept = 0, arrow = false
        // The arrow last: a register with `instantly` evidently also makes that cursor the current one of the connection that
        // registers it, Pilot's own, so over Pilot's windows the last one stayed up (a camera, a zoom, resize arrows: the
        // dictionary's order, new each launch) until AppKit next set a cursor (T31).
        for (id, cursor) in art.cursors.sorted(by: { ($0.key == "arrow" ? 1 : 0, $0.key) < ($1.key == "arrow" ? 1 : 0, $1.key) }) {
            let images = catalogue.scales.compactMap { scale in
                sheets[scale].flatMap { CursorCatalogue.strip($0, cursor: cursor, palette: palette, px: catalogue.canvasPoints * scale) }
            }
            guard images.count == catalogue.scales.count, cursor.hotspot.count == 2 else {
                cursorlog.error("cursor: \(set.rawValue, privacy: .public) \(id, privacy: .public) did not build")
                continue
            }
            let hotspot = CGPoint(x: cursor.hotspot[0], y: cursor.hotspot[1])
            let ours = CursorCalls.Registered(size: CGSize(width: points, height: points), hotspot: hotspot, frames: cursor.frames,
                                              duration: cursor.frames > 1 ? catalogue.frameSeconds : 0, images: images)
            for name in CursorNames.byCursor[id] ?? [] {
                if CursorNames.coreGraphicsNames.contains(name) && !held.contains(name) {
                    kept += 1
                    cursorlog.notice("cursor: \(name, privacy: .public) keeps macOS's, it is not in the backup")
                    continue
                }
                names += 1
                let status = system.register(name, ours)
                let back = system.read(name)
                let ok = status == 0 && back.map { $0.frames == cursor.frames && abs($0.hotspot.x - hotspot.x) < 0.5 && abs($0.hotspot.y - hotspot.y) < 0.5 } == true
                if ok { confirmed += 1 } else {
                    cursorlog.error("cursor: \(name, privacy: .public) registered \(status), read back \(back == nil ? "nothing" : "a different cursor", privacy: .public)")
                }
                if ok && id == "arrow" { arrow = true }
            }
        }
        system.dockOverride(true)
        cursorlog.notice("cursor: \(set.rawValue, privacy: .public) applied, \(confirmed) of \(names) names confirmed, \(kept) kept macOS's")
        let keptLine = kept == 0 ? "" : " \(kept) stay macOS's: Pilot could not back them up first."
        return arrow ? "\(set.title) is on: \(confirmed) of \(names) cursor names confirmed.\(keptLine)"
            : "\(set.title) went in, but macOS did not confirm the arrow.\(keptLine) Restore brings macOS's back."
    }

    /// The backup `apply` registers against. While Pilot's art is registered in this boot session nothing new can be
    /// taken (it would save Pilot's art as macOS's), so the saved one serves, or none. Otherwise a backup from another
    /// macOS build or one missing a name is retaken; a read that gives nothing, or a save that throws, refuses the apply.
    static func backUp(_ system: any CursorSystem, place: CursorPlace) throws(BackupFailure) -> CursorBackup {
        let saved = CursorBackup.load(place.backupURL, build: place.build)
        if place.applied { return saved ?? CursorBackup(build: place.build, cursors: []) }
        if let saved, saved.complete { return saved }
        let names = CursorNames.coreGraphicsNames.sorted()
        let taken = CursorBackup(build: place.build, cursors: names.compactMap { name in system.read(name).flatMap { CursorBackup.Cursor(name, $0) } })
        guard !taken.cursors.isEmpty else {
            cursorlog.error("cursor: macOS gave none of its \(names.count) cursors to back up, nothing applied")
            throw BackupFailure(line: "macOS would not hand over its own cursors to back up, so Pilot changed nothing.")
        }
        do { try taken.save(place.backupURL) } catch {
            cursorlog.error("cursor: backup failed, nothing applied: \(String(describing: error), privacy: .public)")
            throw BackupFailure(line: "Pilot could not save macOS's cursors first, so it changed nothing.")
        }
        cursorlog.notice("cursor: backed up \(taken.cursors.count) of macOS's \(names.count) cursors")
        return taken
    }

    struct BackupFailure: Error { let line: String }

    /// macOS's cursors back: the backup re-registered (the only way back for `com.apple.coregraphics.*` on 27), the
    /// numbered names removed, then CoreCursor's own reset and the Dock override off. The stamp clears only when every
    /// backed-up cursor went back, so a later backup never saves Pilot's art as macOS's.
    static func restore(system: (any CursorSystem)?, place: CursorPlace) -> String {
        guard let system else { return "This macOS lacks the private calls, so Pilot changed nothing. A restart brings macOS's cursor back." }
        let applied = place.applied
        // Nothing of Pilot's is registered in this boot: only the harmless resets, never the backup over macOS's own.
        let backup = applied ? CursorBackup.load(place.backupURL, build: place.build) : nil
        let restorable = backup?.decoded() ?? [:]
        let back = restorable.filter { system.register($0.key, $0.value) == 0 }.count
        for name in CursorNames.byCursor.values.joined() where !CursorNames.coreGraphicsNames.contains(name) { system.remove(name) }
        let unregistered = system.resetCoreCursors()
        system.dockOverride(false)
        cursorlog.notice("cursor: restored \(back) of \(restorable.count) from the backup, CoreCursorUnregisterAll \(unregistered)")
        if !applied { return "macOS's cursor is on." }
        guard backup != nil else { return "macOS's cursor is back, but its backup is gone: a restart brings back its arrow and I-beam." }
        guard let backup, back == backup.cursors.count else {
            return "\(back) of macOS's \(backup?.cursors.count ?? 0) backed-up cursors came back. A restart brings back the rest."
        }
        place.stamp(false)
        return "macOS's cursor is back."
    }
}

// MARK: - The setting

/// Look › Cursor's store: the set, its colours and Custom's fill and outline, saved as they change, applied by the shared store in Pilot.app alone,
/// never in a test run (the sandbox host is one), so no test and no agent run can change Sven's real cursor.
@Observable @MainActor
final class CursorSets {
    static let shared = CursorSets()

    var set: CursorSetID {
        didSet {
            defaults.set(set.rawValue, forKey: Key.set)
            if set != oldValue { apply() }
        }
    }
    var colours: CursorColours {
        didSet {
            defaults.set(colours.rawValue, forKey: Key.colours)
            if colours != oldValue && set != .macOS { apply() }
        }
    }
    /// Custom's fill and outline, on any set (Q815): `theme` until picked. A well fires on every drag, so these settle
    /// before an apply.
    var fill: ColourChoice { didSet { picked(fill, was: oldValue, Key.fill) } }
    var outline: ColourChoice { didSet { picked(outline, was: oldValue, Key.outline) } }
    /// Custom's two colours on `set`.
    func custom(_ set: CursorSetID) -> CursorCustom { CursorCustom(set: set, fill: fill, outline: outline) }

    private func picked(_ colour: ColourChoice, was old: ColourChoice, _ key: String) {
        defaults.set(colour.rawValue, forKey: key)
        if colour != old && colours == .custom { reapply(after: 0.3) }
    }
    /// The last apply's or restore's one line for the page; nil before any.
    private(set) var status: String?
    /// Runs queued or running: an earlier apply's end must not clear Working while a later restore still runs.
    private var inFlight = 0
    var working: Bool { inFlight > 0 }

    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var observers: [NSObjectProtocol] = []

    enum Key {
        static let set = "look.cursor", colours = "look.cursorColours", fill = "look.cursorFill", outline = "look.cursorOutline"
    }

    /// A test run's store saves to a throwaway suite (`UserDefaults.pilot`).
    init(defaults: UserDefaults = .pilot()) {
        self.defaults = defaults
        set = defaults.string(forKey: Key.set).flatMap(CursorSetID.init(rawValue:)) ?? .macOS
        colours = defaults.string(forKey: Key.colours).flatMap(CursorColours.init(rawValue:)) ?? .theme
        fill = defaults.string(forKey: Key.fill).flatMap(ColourChoice.init(rawValue:)) ?? .theme
        outline = defaults.string(forKey: Key.outline).flatMap(ColourChoice.init(rawValue:)) ?? .theme
    }

    /// The store a Look's page and keys bind to: the shared one for `Look.shared`, else one of its own per Look (a
    /// test's or render's), so each test's keys start from the defaults.
    static func of(_ look: Look) -> CursorSets {
        if look === Look.shared { return .shared }
        if let made = stores.object(forKey: look) { return made }
        let made = CursorSets()
        stores.setObject(made, forKey: look)
        return made
    }
    private static let stores = NSMapTable<Look, CursorSets>.weakToStrongObjects()

    /// Only Pilot.app itself changes the system cursor: never a test, the sandbox host or a render.
    private var mayApply: Bool { self === Self.shared && defaults.isApp && !isTestRun && Bundle.main.bundleIdentifier == "dev.banozz.pilot" }

    /// Accessibility › Display › Pointer's own colours: while they are on, a set reverts outside the front window
    /// (MaCursor #7, #21), so the page offers Reset Colors first.
    static var accessibilityColoursOn: Bool {
        CFPreferencesCopyAppValue("cursorIsCustomized" as CFString, "com.apple.universalaccess" as CFString) as? Bool ?? false
    }
    /// Where Reset Colors is (the anchor is unverified on 27; the pane opens either way).
    static let pointerSettings = URL(string: "x-apple.systempreferences:com.apple.Accessibility-Settings.extension?Display")!

    /// At launch (Pilot is the login item, so this is the login re-apply): the saved set, then again on wake, a display
    /// change, a switch back to this user and, following the theme, a theme change. With macOS's cursor saved and nothing
    /// applied, nothing is called at all.
    func start() {
        guard mayApply, observers.isEmpty else { return }
        let workspace = NSWorkspace.shared.notificationCenter
        for (center, name) in [(workspace, NSWorkspace.didWakeNotification), (workspace, NSWorkspace.sessionDidBecomeActiveNotification),
                               (NotificationCenter.default, NSApplication.didChangeScreenParametersNotification)] {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.reapply(after: 1) }
            })
        }
        followTheme()
        if set != .macOS { apply() } else if CursorPlace.live(defaults).applied { restore() }
    }

    /// Re-applies the set once things settle (a wake, a display change and a colour well's drag come in bursts).
    private func reapply(after seconds: Double) {
        guard set != .macOS else { return }
        generation += 1
        let mine = generation
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(seconds))
            guard let self, mine == generation else { return }
            apply()
        }
    }

    private func followTheme() {
        withObservationTracking { _ = Look.shared.paletteRevision } onChange: { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                if self.colours != .own { self.reapply(after: 0.2) }   // Custom stands on the theme's colours too
                self.followTheme()
            }
        }
    }

    /// The saved set onto the system, or macOS's back when it is macOS.
    func apply() {
        guard mayApply else { return }
        if set == .macOS { restore(); return }
        let (set, colours, theme, custom, resolved) = (set, colours, Look.shared.themeID, custom(set), Look.shared.packAppearance)
        run { CursorEngine.apply(set, colours: colours, theme: theme, custom: custom, resolved: resolved, system: LiveCursors(), place: $0) }
    }

    /// Look › Cursor › Restore: macOS's cursor saved first, so the next login does not bring Pilot's set back, then put back.
    func restore() {
        if set != .macOS { set = .macOS; return }    // set's didSet calls apply, which restores
        guard mayApply else { return }
        run { CursorEngine.restore(system: LiveCursors(), place: $0) }
    }

    /// `work` on the engine's queue, which alone writes the applied stamp; its line then goes to the page, the hops to
    /// main in the queue's order, so the newest line lands last.
    private func run(_ work: @escaping @Sendable (CursorPlace) -> String) {
        inFlight += 1
        let place = CursorPlace.live(defaults)
        CursorEngine.queue.async { [weak self] in
            let line = work(place)
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.inFlight -= 1
                    self.status = line
                }
            }
        }
    }
}

// MARK: - Samples for the page

/// Look › Cursor's small pictures: a few cursors' first frames, copied out of the 2x atlases once while the page shows
/// (so only those rows stay in memory) and drawn in a palette; each cursor keeps its last picture, and each set its last
/// palette, so a well's drag redraws only what changed.
@MainActor
final class CursorSamples {
    /// What the page draws: the tiles' arrow and hand, and Custom's sample.
    static let shown = ["arrow", "ibeam", "pointing-hand", "busy"]

    private let folder: URL?
    private lazy var catalogue = folder.flatMap(CursorCatalogue.load)
    /// Per set, the shown cursors' first frames, one row each, and each one's row there.
    private var rows: [CursorSetID: (sheet: CursorArt.Sheet, row: [String: Int])] = [:]
    private var palettes: [CursorSetID: (key: String, palette: [String: String])] = [:]
    private var images: [String: (palette: [String], image: CGImage)] = [:]

    init(folder: URL? = CursorCatalogue.folder, catalogue: CursorCatalogue? = nil) {
        self.folder = folder
        if let catalogue { self.catalogue = catalogue }
    }

    /// `set`'s palette in `colours` on `theme`, Custom's from `custom`; empty when the art is missing.
    func palette(_ set: CursorSetID, _ colours: CursorColours, theme: String, custom: CursorCustom, resolved: PilotTheme? = nil) -> [String: String] {
        let key = "\(colours) \(theme) \(custom.fill.rawValue) \(custom.outline.rawValue) \(String(describing: resolved))"
        if let kept = palettes[set], kept.key == key { return kept.palette }
        let palette = catalogue?.sets[set.rawValue]?.palette(colours, theme: theme, custom: custom, resolved: resolved) ?? [:]
        palettes[set] = (key, palette)
        return palette
    }

    /// `cursor` (one of `shown`) of `set` at 2x, its first frame, in `palette`.
    func image(_ set: CursorSetID, _ cursor: String, palette: [String: String]) -> CGImage? {
        guard let catalogue, let c = catalogue.sets[set.rawValue]?.cursors[cursor], let art = rows(set), let row = art.row[cursor] else { return nil }
        let used = c.layers.map { palette[$0] ?? "" }, key = "\(set.rawValue) \(cursor)"
        if let kept = images[key], kept.palette == used { return kept.image }
        guard let image = CursorArt.image(art.sheet, colours: c.colours(palette), row: row, px: catalogue.canvasPoints * 2)
        else { return nil }
        images[key] = (used, image)
        return image
    }

    /// The shown cursors' first frames of `set`, copied out of its 2x atlas on first use.
    private func rows(_ set: CursorSetID) -> (sheet: CursorArt.Sheet, row: [String: Int])? {
        if let kept = rows[set] { return kept }
        guard let folder, let catalogue, let art = catalogue.sets[set.rawValue],
              let full = CursorArt.sheet(folder, set: set.rawValue, scale: 2) else { return nil }
        let px = catalogue.canvasPoints * 2
        var grey = [UInt8](), row = [String: Int]()
        for name in Self.shown {
            guard let c = art.cursors[name] else { continue }
            let start = c.row * px * full.bytesPerRow, end = start + px * full.bytesPerRow
            guard end <= full.grey.count else { continue }
            row[name] = row.count
            grey += full.grey[start..<end]
        }
        let made = (CursorArt.Sheet(grey: grey, width: full.width, height: px * row.count, bytesPerRow: full.bytesPerRow), row)
        rows[set] = made
        return made
    }
}
