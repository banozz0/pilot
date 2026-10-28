import AppKit
import CoreGraphics
import IOKit
import PilotCore

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
    func readDDC(_ display: UInt32) -> Double? {
        guard let writeI2C, let readI2C, let service = lock.withLock({ ddc[display]?.service }) ?? service(for: display) else { return nil }
        for _ in 1...3 {
            var request = DDC.get(DDC.brightness)
            for _ in 1...2 {
                usleep(10_000)
                _ = writeI2C(service, DDC.chip, DDC.dataAddress, &request, UInt32(request.count))
            }
            usleep(50_000)
            var reply = [UInt8](repeating: 0, count: DDC.replyLength)
            guard readI2C(service, DDC.chip, 0, &reply, UInt32(reply.count)) == kIOReturnSuccess,
                  let value = DDC.reply(reply, for: DDC.brightness) else { continue }
            lock.withLock { ddc[display] = (service, value.max) }
            return Double(value.current) / Double(value.max)
        }
        slog.notice("brightness: display \(display, privacy: .public) does not answer DDC")
        return nil
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

    /// The keyboard's brightness keys (card agent-bo-95423314), from inside the tap callback: the first press asks for
    /// the focused window's screen and its route, its step runs after the callback returns.
    static func key(_ press: BrightnessKeys.Press, switchOn: Bool) -> Bool {
        let first = press.isDown && !press.isRepeat
        let (taken, screen) = keys.route(press, switchOn: switchOn) {
            Screens.focusedScreen.flatMap { screen in number(screen).map { (screen, engine.screens[$0]?.route) } }
        }
        if first { slog.notice("brightness key \(press.up ? "up" : "down", privacy: .public): \(taken ? "taken" : "passed to macOS", privacy: .public)\(screen.map { " on \($0.localizedName)" } ?? "", privacy: .public)") }
        if let screen { DispatchQueue.main.async { step(screen, up: press.up) } }
        return taken
    }

    private static var keys = BrightnessKeys.Router<NSScreen>()

    private static func number(_ screen: NSScreen) -> UInt32? {
        (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value
    }
}
