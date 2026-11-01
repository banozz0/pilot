import AppKit
import CoreGraphics

/// One way a screen can run: its size in points, the pixels behind them, and its refresh rate.
struct DisplayMode: Codable, Equatable, Hashable, Sendable {
    /// CoreGraphics's id for the mode on its screen (ioDisplayModeID).
    let id: Int32
    let width: Int, height: Int
    let pixelWidth: Int
    let refresh: Double

    /// What makes two modes the same size: the points, and the pixels behind them (HiDPI or not).
    struct Size: Hashable, Sendable { let width: Int, height: Int, pixelWidth: Int }
    var size: Size { Size(width: width, height: height, pixelWidth: pixelWidth) }
    var hiDPI: Bool { pixelWidth > width }

    /// "3440 × 1440", "· HiDPI" added when each point is more than one pixel: the size picker's row.
    var sizeLabel: String { "\(width) × \(height)" + (hiDPI ? " · HiDPI" : "") }
    /// "100 Hz"; nil when the screen does not say.
    var rate: String? { refresh > 0 ? "\(Int(refresh.rounded())) Hz" : nil }
    /// "3440 × 1440 · 100 Hz", "· HiDPI" last.
    var label: String { ["\(width) × \(height)", rate, hiDPI ? "HiDPI" : nil].compactMap { $0 }.joined(separator: " · ") }
}

struct DisplayInfo: Equatable, Sendable {
    let id: CGDirectDisplayID
    let name: String
    let main: Bool
    /// Where the screen sits in the arrangement, in points, macOS's top-left origin.
    let frame: CGRect
    var mode: DisplayMode
    /// Degrees.
    let rotation: Int
    /// Durable label key, independent of the current-session CoreGraphics handle.
    var displayUUID: String? = nil
}

enum DisplayIdentity {
    /// Read fresh: a cached UUID keyed by a numeric handle could name a replacement monitor after ID reuse.
    static func uuid(for display: CGDirectDisplayID) -> String? {
        guard let uuid = CGDisplayCreateUUIDFromDisplayID(display)?.takeRetainedValue() else { return nil }
        return CFUUIDCreateString(nil, uuid) as String
    }

    /// The screen's UUID, read fresh as above: what Monitors keys its pins by and Wallpaper a screen's own folders.
    static func uuid(of screen: NSScreen) -> String? { WallpaperScreen.number(screen).flatMap(uuid(for:)) }
}

/// The Mac's screens: CoreGraphics is the real one; the tests use a fake, so no test changes a display mode.
@MainActor
protocol DisplaySystem: AnyObject {
    func displays() -> [DisplayInfo]
    func modes(_ display: CGDirectDisplayID) -> [DisplayMode]
    /// For this login session only, or for good.
    func apply(_ mode: DisplayMode, to display: CGDirectDisplayID, permanently: Bool) throws
    /// Whether macOS lets Pilot turn this screen; false hides Rotate.
    func canRotate(_ display: CGDirectDisplayID) -> Bool
    /// Turns the screen to 0, 90, 180 or 270 degrees; macOS keeps a rotation by itself.
    func rotate(_ display: CGDirectDisplayID, to degrees: Int) throws
    /// Puts each screen's top-left corner at its point in the global space, for good, as System Settings' arrangement does.
    func arrange(_ origins: [CGDirectDisplayID: CGPoint]) throws
}

extension DisplaySystem {
    func canRotate(_ display: CGDirectDisplayID) -> Bool { false }
    func rotate(_ display: CGDirectDisplayID, to degrees: Int) throws { throw DisplayRotation.Unavailable() }
    func arrange(_ origins: [CGDirectDisplayID: CGPoint]) throws { throw CoreGraphicsDisplays.Refused(status: .notImplemented) }
}

/// Screen rotation (Sven 2026-10-22). macOS has no public call: this is MonitorPanel's MPDisplay, the private class behind
/// System Settings' own Rotation picker that displayplacer turns screens with on Apple silicon. It is looked up by name
/// on first use, so a macOS without it, or without one of its four selectors, hides Rotate instead of crashing.
@MainActor
enum DisplayRotation {
    static let degrees = [0, 90, 180, 270]

    struct Unavailable: Error, CustomStringConvertible {
        var description: String { "macOS does not let Pilot rotate this screen" }
    }

    private typealias SetOrientation = @convention(c) (AnyObject, Selector, Int32) -> Void
    private typealias Flag = @convention(c) (AnyObject, Selector) -> Bool

    /// MPDisplayMgr's class with every selector Pilot calls, nil when this macOS lacks any of them.
    private static let manager: NSObject.Type? = {
        guard dlopen("/System/Library/PrivateFrameworks/MonitorPanel.framework/MonitorPanel", RTLD_LAZY) != nil,
              let manager = NSClassFromString("MPDisplayMgr") as? NSObject.Type, let display = NSClassFromString("MPDisplay"),
              ["displays", "tryLockAccess", "unlockAccess"].allSatisfy({ manager.instancesRespond(to: NSSelectorFromString($0)) }),
              ["displayID", "canChangeOrientation", "orientation", "setOrientation:"].allSatisfy({ display.instancesRespond(to: NSSelectorFromString($0)) })
        else { slog.notice("rotation: MonitorPanel's display calls are missing; Rotate hidden"); return nil }
        return manager
    }()

    /// The manager's MPDisplay for `id`, read fresh: a new manager lists the screens as they are now.
    private static func display(_ id: CGDirectDisplayID) -> (manager: NSObject, display: NSObject)? {
        guard let manager = manager?.init(), let all = manager.value(forKey: "displays") as? [NSObject] else { return nil }
        return all.first { ($0.value(forKey: "displayID") as? NSNumber)?.uint32Value == id }.map { (manager, $0) }
    }

    static func canRotate(_ id: CGDirectDisplayID) -> Bool {
        (display(id)?.display.value(forKey: "canChangeOrientation") as? NSNumber)?.boolValue == true
    }

    /// setOrientation: takes a plain int, so it is called through its implementation; the manager's access lock is
    /// held round it as MonitorPanel's own callers do.
    static func rotate(_ id: CGDirectDisplayID, to degrees: Int) throws {
        guard Self.degrees.contains(degrees), let found = display(id),
              (found.display.value(forKey: "canChangeOrientation") as? NSNumber)?.boolValue == true,
              let set = class_getMethodImplementation(type(of: found.display), NSSelectorFromString("setOrientation:")),
              let lock = class_getMethodImplementation(type(of: found.manager), NSSelectorFromString("tryLockAccess"))
        else { throw Unavailable() }
        let locked = unsafeBitCast(lock, to: Flag.self)(found.manager, NSSelectorFromString("tryLockAccess"))
        unsafeBitCast(set, to: SetOrientation.self)(found.display, NSSelectorFromString("setOrientation:"), Int32(degrees))
        if locked { found.manager.perform(NSSelectorFromString("unlockAccess")) }
    }
}

/// CoreGraphics's public display calls (Setup › Displays, card agent-bo-95422804). The arrangement moves one screen beside
/// another (Sven 2026-10-30), its origins from DisplayArrangement so none lands on a third; the main display and
/// mirroring are read only.
final class CoreGraphicsDisplays: DisplaySystem {
    struct Refused: Error, CustomStringConvertible {
        let status: CGError
        var description: String { "macOS refused the change (CoreGraphics error \(status.rawValue))" }
    }

    func displays() -> [DisplayInfo] {
        var count: UInt32 = 0
        guard CGGetActiveDisplayList(0, nil, &count) == .success, count > 0 else { return [] }
        var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
        guard CGGetActiveDisplayList(count, &ids, &count) == .success else { return [] }
        let names = Dictionary(NSScreen.screens.compactMap { screen in
            (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber).map { ($0.uint32Value, screen.localizedName) }
        }, uniquingKeysWith: { a, _ in a })
        return ids.compactMap { id in
            guard let mode = CGDisplayCopyDisplayMode(id).map(Self.mode) else { return nil }
            return DisplayInfo(id: id, name: names[id] ?? "Display \(id)", main: CGDisplayIsMain(id) != 0, frame: CGDisplayBounds(id),
                               mode: mode, rotation: Int(CGDisplayRotation(id)), displayUUID: DisplayIdentity.uuid(for: id))
        }
    }

    func modes(_ display: CGDirectDisplayID) -> [DisplayMode] {
        // macOS lists a mode once per pixel encoding; each size and rate is kept once.
        var seen = Set<String>()
        return all(display).filter { $0.isUsableForDesktopGUI() }.map(Self.mode)
            .sorted { ($0.width, $0.height, $0.refresh, $0.pixelWidth) > ($1.width, $1.height, $1.refresh, $1.pixelWidth) }
            .filter { seen.insert($0.label).inserted }
    }

    func apply(_ mode: DisplayMode, to display: CGDirectDisplayID, permanently: Bool) throws {
        guard let target = all(display).first(where: { $0.ioDisplayModeID == mode.id }) else { throw Refused(status: .illegalArgument) }
        var config: CGDisplayConfigRef?
        var status = CGBeginDisplayConfiguration(&config)
        guard status == .success else { throw Refused(status: status) }
        status = CGConfigureDisplayWithDisplayMode(config, display, target, nil)
        guard status == .success else { CGCancelDisplayConfiguration(config); throw Refused(status: status) }
        status = CGCompleteDisplayConfiguration(config, permanently ? .permanently : .forSession)
        guard status == .success else { throw Refused(status: status) }
    }

    func canRotate(_ display: CGDirectDisplayID) -> Bool { DisplayRotation.canRotate(display) }
    func rotate(_ display: CGDirectDisplayID, to degrees: Int) throws { try DisplayRotation.rotate(display, to: degrees) }

    func arrange(_ origins: [CGDirectDisplayID: CGPoint]) throws {
        var config: CGDisplayConfigRef?
        var status = CGBeginDisplayConfiguration(&config)
        guard status == .success else { throw Refused(status: status) }
        for (display, origin) in origins {
            status = CGConfigureDisplayOrigin(config, display, Int32(origin.x), Int32(origin.y))
            guard status == .success else { CGCancelDisplayConfiguration(config); throw Refused(status: status) }
        }
        status = CGCompleteDisplayConfiguration(config, .permanently)
        guard status == .success else { throw Refused(status: status) }
    }

    private func all(_ display: CGDirectDisplayID) -> [CGDisplayMode] {
        let options = [kCGDisplayShowDuplicateLowResolutionModes: kCFBooleanTrue] as CFDictionary
        return CGDisplayCopyAllDisplayModes(display, options) as? [CGDisplayMode] ?? []
    }

    private static func mode(_ m: CGDisplayMode) -> DisplayMode {
        DisplayMode(id: m.ioDisplayModeID, width: m.width, height: m.height, pixelWidth: m.pixelWidth, refresh: m.refreshRate)
    }
}
