import AppKit
import CoreGraphics
import IOKit
import PilotCore
import Synchronization

/// Brightness on the Mac (story 144, card agent-bo-95423313): Apple's private DisplayServices for Apple screens, DDC/CI
/// over IOAVService for other monitors. Private symbols through dlsym, as CoreBrightnessNightShift does, so a missing one
/// reads as no control. m1ddc's way of finding a screen's DCPAVServiceProxy and MonitorControl's timing (both MIT) are the
/// reference; no file is copied. Calls block, so they run on the screen's queue (Brightness), never on the main thread.
final class DisplayBrightness: BrightnessHardware, @unchecked Sendable {
    private typealias CanChange = @convention(c) (UInt32) -> Bool
    private typealias Get = @convention(c) (UInt32, UnsafeMutablePointer<Float>) -> Int32
    private typealias SetLevel = @convention(c) (UInt32, Float) -> Int32
    private typealias InfoDictionary = @convention(c) (UInt32) -> Unmanaged<CFDictionary>?
    private typealias CreateService = @convention(c) (CFAllocator?, io_service_t) -> Unmanaged<CFTypeRef>?
    private typealias I2C = @convention(c) (CFTypeRef, UInt32, UInt32, UnsafeMutableRawPointer, UInt32) -> IOReturn

    private let canChange: CanChange?, get: Get?, set: SetLevel?
    private let info: InfoDictionary?, create: CreateService?, writeI2C: I2C?, readI2C: I2C?
    /// Each DDC screen's service and its maximum, found by its first read.
    private var ddc: [UInt32: (service: CFTypeRef, max: Int)] = [:]
    private let lock = NSLock()

    init() {
        let services = dlopen("/System/Library/PrivateFrameworks/DisplayServices.framework/DisplayServices", RTLD_LAZY)
        let coreDisplay = dlopen("/System/Library/Frameworks/CoreDisplay.framework/CoreDisplay", RTLD_LAZY)
        // RTLD_DEFAULT: IOAVService lives in IOKit, which Pilot links.
        let linked = UnsafeMutableRawPointer(bitPattern: -2)
        func symbol<T>(_ handle: UnsafeMutableRawPointer?, _ name: String, _: T.Type) -> T? {
            handle.flatMap { dlsym($0, name) }.map { unsafeBitCast($0, to: T.self) }
        }
        canChange = symbol(services, "DisplayServicesCanChangeBrightness", CanChange.self)
        get = symbol(services, "DisplayServicesGetBrightness", Get.self)
        set = symbol(services, "DisplayServicesSetBrightness", SetLevel.self)
        info = symbol(coreDisplay, "CoreDisplay_DisplayCreateInfoDictionary", InfoDictionary.self)
        create = symbol(linked, "IOAVServiceCreateWithService", CreateService.self)
        writeI2C = symbol(linked, "IOAVServiceWriteI2C", I2C.self)
        readI2C = symbol(linked, "IOAVServiceReadI2C", I2C.self)
    }

    func readApple(_ display: UInt32) -> Double? {
        guard let canChange, let get, canChange(display) else { return nil }
        var level: Float = -1
        return get(display, &level) == 0 && level >= 0 ? Double(level) : nil
    }

    /// Get VCP 0x10, up to three tries: the request twice 10 ms apart, 50 ms for the monitor, then its 11-byte reply.
    /// Refused when no request write went through: the link itself turned DDC/CI down, as a MegaChips DP-to-HDMI
    /// converter does with 0xe0114000 while it still passes the EDID (probe, 2026-11-16); longer waits don't help.
    func readDDC(_ display: UInt32) -> DDCRead {
        guard let writeI2C, let readI2C, let service = lock.withLock({ ddc[display]?.service }) ?? service(for: display) else { return .silent }
        var wentThrough = false, refusal = kIOReturnError
        for _ in 1...3 {
            var request = DDC.get(DDC.brightness)
            for _ in 1...2 {
                usleep(10_000)
                let sent = writeI2C(service, DDC.chip, DDC.dataAddress, &request, UInt32(request.count))
                if sent == kIOReturnSuccess { wentThrough = true } else { refusal = sent }
            }
            usleep(50_000)
            var reply = [UInt8](repeating: 0, count: DDC.replyLength)
            guard readI2C(service, DDC.chip, 0, &reply, UInt32(reply.count)) == kIOReturnSuccess,
                  let value = DDC.reply(reply, for: DDC.brightness) else { continue }
            lock.withLock { ddc[display] = (service, value.max) }
            return .level(Double(value.current) / Double(value.max))
        }
        if !wentThrough {
            slog.notice("brightness: display \(display, privacy: .public)'s link refuses DDC (0x\(String(UInt32(bitPattern: refusal), radix: 16), privacy: .public)): an adapter on the way passes no DDC/CI")
            return .refused
        }
        slog.notice("brightness: display \(display, privacy: .public) does not answer DDC")
        return .silent
    }

    func write(_ level: Double, to display: UInt32, over route: BrightnessRoute) -> Bool {
        let done: Bool
        switch route {
        case .apple: done = set.map { $0(display, Float(level)) == 0 } ?? false
        case .ddc: done = writeDDC(level, display)
        case .none: done = false
        }
        if !done { slog.error("brightness: display \(display, privacy: .public) refused \(level, privacy: .public) over \(route.rawValue, privacy: .public)") }
        return done
    }

    /// Set VCP 0x10, sent twice 10 ms apart as MonitorControl does, then 50 ms before the next write so the monitor
    /// keeps up; newer values wait in the queue meanwhile.
    private func writeDDC(_ level: Double, _ display: UInt32) -> Bool {
        guard let writeI2C, let screen = lock.withLock({ ddc[display] }) else { return false }
        var packet = DDC.set(DDC.brightness, to: UInt16((level * Double(screen.max)).rounded()))
        var result = kIOReturnError
        for _ in 1...2 {
            usleep(10_000)
            result = writeI2C(screen.service, DDC.chip, DDC.dataAddress, &packet, UInt32(packet.count))
        }
        usleep(50_000)
        return result == kIOReturnSuccess
    }

    /// The screen's DCPAVServiceProxy, m1ddc's way: its framebuffer from CoreDisplay's IODisplayLocation, then the first
    /// external proxy that follows that framebuffer in the registry, before the next one.
    private func service(for display: UInt32) -> CFTypeRef? {
        guard let info, let create, let dictionary = info(display)?.takeRetainedValue() as? [String: Any],
              let location = dictionary["IODisplayLocation"] as? String else { return nil }
        let framebuffer = IORegistryEntryCopyFromPath(kIOMainPortDefault, location as CFString)
        guard framebuffer != 0 else { return nil }
        defer { IOObjectRelease(framebuffer) }
        var target: UInt64 = 0
        IORegistryEntryGetRegistryEntryID(framebuffer, &target)
        let root = IORegistryGetRootEntry(kIOMainPortDefault)
        defer { IOObjectRelease(root) }
        var iterator: io_iterator_t = 0
        guard IORegistryEntryCreateIterator(root, kIOServicePlane, IOOptionBits(kIORegistryIterateRecursively), &iterator) == KERN_SUCCESS else { return nil }
        defer { IOObjectRelease(iterator) }
        var following = false
        while case let entry = IOIteratorNext(iterator), entry != 0 {
            defer { IOObjectRelease(entry) }
            if IOObjectConformsTo(entry, "IOMobileFramebuffer") != 0 {
                var id: UInt64 = 0
                IORegistryEntryGetRegistryEntryID(entry, &id)
                following = id == target
                continue
            }
            guard following, IOObjectConformsTo(entry, "DCPAVServiceProxy") != 0,
                  IORegistryEntryCreateCFProperty(entry, "Location" as CFString, nil, 0)?.takeRetainedValue() as? String == "External"
            else { continue }
            return create(kCFAllocatorDefault, entry)?.takeRetainedValue()
        }
        return nil
    }
}

/// Pilot's one brightness model and its keys (story 144): read at launch, after a wake and when the screens change.
@MainActor
enum ScreenBrightness {
    static let engine = Brightness(hardware: DisplayBrightness())
    private static var pending: Task<Void, Never>?

    /// Reads every screen now and again after each display change or wake, never on a timer.
    static func start() {
        refresh(after: 0)
        CGDisplayRegisterReconfigurationCallback({ _, flags, _ in
            guard !flags.contains(.beginConfigurationFlag) else { return }
            Task { @MainActor in ScreenBrightness.refresh(after: 1) }
        }, nil)
        // A monitor waking from sleep takes a moment before it answers DDC.
        for name in [NSWorkspace.didWakeNotification, NSWorkspace.screensDidWakeNotification] {
            _ = NSWorkspace.shared.notificationCenter.addObserver(forName: name, object: nil, queue: .main) { _ in
                MainActor.assumeIsolated { refresh(after: 2) }
            }
        }
    }

    /// One read after the burst of changes settles.
    private static func refresh(after seconds: Double) {
        pending?.cancel()
        pending = Task {
            try? await Task.sleep(for: .seconds(seconds))
            guard !Task.isCancelled else { return }
            await engine.refresh(displays())
            routes.withLock { $0 = engine.screens.mapValues(\.route) }
        }
    }

    /// The screens AppKit has, each with MonitorControl's guard: a non-Apple screen with HDR on is no Apple display.
    static func displays() -> [Brightness.Display] {
        NSScreen.screens.compactMap { screen in
            guard let id = number(screen) else { return nil }
            let hdr = screen.maximumPotentialExtendedDynamicRangeColorComponentValue > 1
            return Brightness.Display(id: id, appleAllowed: CGDisplayVendorNumber(id) == 0x610 || !hdr)
        }
    }

    /// Hyper+F1 and F2 on the focused window's screen, with Shift on every screen; each changed screen shows its level
    /// HUD (card agent-bo-95423314).
    static func step(up: Bool, everyScreen: Bool) {
        let screens = everyScreen ? NSScreen.screens : Screens.focusedScreen.map { [$0] } ?? []
        guard !screens.isEmpty else { return HUD.tip("No screen to dim", seconds: 1.5) }
        for screen in screens { step(screen, up: up) }
    }

    private static func step(_ screen: NSScreen, up: Bool) {
        guard let id = number(screen) else { return }
        let level = engine.step(id, up: up)
        slog.notice("brightness \(screen.localizedName, privacy: .public) \(level.map { String($0) } ?? "no control", privacy: .public)")
        LevelHUD.show(level.map { .level($0) } ?? (engine.screens[id] == nil ? .reading : .noControl), screen: screen, id: id)
    }

    /// Setup › Displays' Brightness keys switch, as the keyboard tap reads it off the main thread (PilotSettings sets it).
    nonisolated static let keysOn = Atomic(false)
    /// Each screen's route as the last read found it, by display id, for the keyboard tap off the main thread.
    nonisolated private static let routes = Mutex<[UInt32: BrightnessRoute]>([:])
    nonisolated private static let keys = Mutex(BrightnessKeys.Router<UInt32>())

    /// The keyboard's brightness keys (card agent-bo-95423314), from inside the tap callback on the tap thread: the first
    /// press asks for the focused window's display and its route, its step runs on the main thread after the callback
    /// returns.
    nonisolated static func key(_ press: BrightnessKeys.Press, switchOn: Bool) -> Bool {
        let first = press.isDown && !press.isRepeat
        let (taken, display) = keys.withLock { keys in
            keys.route(press, switchOn: switchOn) {
                let display = focusedDisplay()
                return (display, routes.withLock { $0[display] })
            }
        }
        if first { slog.notice("brightness key \(press.up ? "up" : "down", privacy: .public): \(taken ? "taken" : "passed to macOS", privacy: .public)\(display.map { " on display \($0)" } ?? "", privacy: .public)") }
        if let display { onMain { if let screen = NSScreen.screens.first(where: { number($0) == display }) { step(screen, up: press.up) } } }
        return taken
    }

    /// The display holding the focused window's centre, else the main one: Screens.focusedScreen's display, read off the
    /// main thread from the Accessibility API and CoreGraphics' display bounds (AX coordinates both). A mirror is left out,
    /// as NSScreen lists only the display it mirrors.
    nonisolated private static func focusedDisplay() -> UInt32 {
        var count: UInt32 = 0
        CGGetActiveDisplayList(0, nil, &count)
        var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
        CGGetActiveDisplayList(count, &ids, &count)
        let shown = ids.prefix(Int(count)).filter { CGDisplayMirrorsDisplay($0) == kCGNullDirectDisplay }
        guard let frame = focusedWindowFrame(),
              let index = WindowGeometry.screen(holding: frame, among: shown.map(CGDisplayBounds)) else { return CGMainDisplayID() }
        return shown[index]
    }

    /// AXWindow.focused()'s frame, read off the main thread: the front app's focused window when it is a standard one
    /// (a standard subrole, or none and a close button), else nil.
    nonisolated private static func focusedWindowFrame() -> CGRect? {
        guard let pid = NSWorkspace.shared.frontmostApplication?.processIdentifier else { return nil }
        func value(_ element: AXUIElement, _ attribute: String) -> AnyObject? {
            var v: AnyObject?
            return AXUIElementCopyAttributeValue(element, attribute as CFString, &v) == .success ? v : nil
        }
        guard let found = value(AXUIElementCreateApplication(pid), kAXFocusedWindowAttribute) else { return nil }
        let window = found as! AXUIElement
        let subrole = value(window, kAXSubroleAttribute) as? String
        guard subrole.map({ $0 == kAXStandardWindowSubrole }) ?? (value(window, kAXCloseButtonAttribute) != nil) else { return nil }
        guard let pos = value(window, kAXPositionAttribute), let size = value(window, kAXSizeAttribute) else { return nil }
        var p = CGPoint.zero, s = CGSize.zero
        AXValueGetValue(pos as! AXValue, .cgPoint, &p)
        AXValueGetValue(size as! AXValue, .cgSize, &s)
        return CGRect(origin: p, size: s)
    }

    private static func number(_ screen: NSScreen) -> UInt32? {
        (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value
    }
}
