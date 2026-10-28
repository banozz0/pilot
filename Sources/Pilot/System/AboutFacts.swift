import AppKit
import Darwin
import Foundation
import IOKit
import PilotCore

/// What Hyper+Space › About shows (Sven 2026-10-24, Q443), Omarchy's About for this Mac: Hardware, Software, and Age /
/// Uptime / Update. Read only, through public APIs and no child process: sysctl, the IORegistry, CoreGraphics' displays,
/// the startup volume's resource values, ProcessInfo and the bundles' Info.plists. The theme and font rows are the view's,
/// as it draws them from the style it is in (MenuAboutScreen).
struct AboutFacts: Equatable, Sendable {
    /// One fact: its label, the value, a quieter note after it, a share drawn in the accent after the value, and whether
    /// the value is a number set in mono.
    struct Row: Equatable, Sendable, Identifiable {
        var label: String, value: String, note: String? = nil, share: Double? = nil, mono = false
        var id: String { label + value }
    }

    var hardware: [Row], software: [Row], age: [Row]

    /// Facts a render draws in this Mac's place (AboutRenders); nil in the app.
    @MainActor static var seed: AboutFacts?

    /// How many rows Hardware lists with `displays` screens, for the screen's height before the facts are read.
    static func hardwareRows(displays: Int) -> Int { 6 + max(displays, 1) }

    /// This Mac's facts: the displays on the main actor (AppKit's screens), the rest off it.
    @MainActor
    static func read() async -> AboutFacts {
        let displays = NSScreen.screens.compactMap(display)
        let pilot = Bundle.main
        let version = pilot.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
        let build = pilot.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "?"
        let updated = (try? pilot.executableURL?.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
        let ghostty = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.mitchellh.ghostty")
        return await Task.detached(priority: .userInitiated) {
            let memory = SystemReader.memory(), disk = SystemReader.disk()
            let cores = (SystemReader.sysctlInt("hw.perflevel0.physicalcpu"), SystemReader.sysctlInt("hw.perflevel1.physicalcpu"))
            let all = SystemReader.sysctlInt("hw.physicalcpu") ?? ProcessInfo.processInfo.processorCount
            let split = cores.0.flatMap { p in cores.1.map { "\(all) cores (\(p)P + \($0)E)" } } ?? "\(all) cores"
            let gpu = SystemReader.accelerators.compactMap(\.cores).max()
            var hardware = [
                Row(label: "Mac", value: productName() ?? SystemReader.machine.model, note: SystemReader.machine.model),
                Row(label: "Chip", value: SystemReader.machine.chip, note: split),
                Row(label: "GPU", value: gpu.map { "\($0) cores" } ?? "Integrated", mono: gpu != nil),
            ]
            hardware += displays.isEmpty ? [Row(label: "Display", value: "None")] : displays
            if let disk, disk.total > 0 {
                let used = Double(disk.total - disk.available)
                hardware.append(Row(label: "Disk", value: "\(SystemStats.decimal(used)) / \(SystemStats.decimal(Double(disk.total)))",
                                    note: fileSystem(), share: used / Double(disk.total), mono: true))
            }
            if memory.total > 0 {
                hardware.append(Row(label: "Memory", value: "\(SystemStats.memorySize(memory.used)) / \(SystemStats.memorySize(memory.total))",
                                    share: Double(memory.used) / Double(memory.total), mono: true))
            }
            hardware.append(memory.swapTotal == 0 ? Row(label: "Swap", value: "None")
                : Row(label: "Swap", value: "\(SystemStats.memorySize(memory.swapUsed)) / \(SystemStats.memorySize(memory.swapTotal))",
                      share: Double(memory.swapUsed) / Double(memory.swapTotal), mono: true))
            let terminal = ghostty.flatMap { Bundle(url: $0)?.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String }
            let software = [
                Row(label: "macOS", value: "macOS \(SystemReader.machine.macOS)", note: SystemReader.sysctlString("kern.osversion")),
                Row(label: "Pilot", value: version, note: "build \(build)", mono: true),
                Row(label: "Tiler", value: "Pilot tiler", note: "AeroSpace engine"),
                terminal.map { Row(label: "Terminal", value: "Ghostty \($0)", note: "libghostty in the bar drop") }
                    ?? Row(label: "Terminal", value: "libghostty", note: "in the bar drop"),
                Row(label: "Apps", value: "\(appCount())", note: "in Applications", mono: true),
            ]
            let now = Date()
            var age: [Row] = []
            if let setUp = setUpDate() {
                age.append(Row(label: "Mac age", value: days(from: setUp, to: now), note: "set up \(setUp.formatted(.dateTime.day().month(.wide).year()))"))
            }
            age.append(Row(label: "Uptime", value: bootTime().map { uptime(now.timeIntervalSince($0)) } ?? "?"))
            if let updated {
                age.append(Row(label: "Updated", value: updated.formatted(.dateTime.weekday(.wide).day().month(.wide).year().hour().minute()), note: "Pilot"))
            }
            return AboutFacts(hardware: hardware, software: software, age: age)
        }.value
    }

    /// A screen as "3440×1440 in 34″, 240 Hz", noted Built-in or External, Main, and Turned when rotated.
    @MainActor
    private static func display(_ screen: NSScreen) -> Row? {
        guard let id = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID else { return nil }
        let mode = CGDisplayCopyDisplayMode(id)
        let (w, h) = (mode?.pixelWidth ?? CGDisplayPixelsWide(id), mode?.pixelHeight ?? CGDisplayPixelsHigh(id))
        let mm = CGDisplayScreenSize(id)
        let inches = mm.width > 0 ? (mm.width * mm.width + mm.height * mm.height).squareRoot() / 25.4 : 0
        let hz = (mode?.refreshRate ?? 0) > 0 ? Int(mode!.refreshRate.rounded()) : screen.maximumFramesPerSecond
        var value = "\(w)×\(h)"
        if inches > 0 { value += " in \(Int(inches.rounded()))″" }
        if hz > 0 { value += ", \(hz) Hz" }
        var note = [CGDisplayIsBuiltin(id) != 0 ? "Built-in" : "External"]
        if CGDisplayIsMain(id) != 0, NSScreen.screens.count > 1 { note.append("Main") }
        let turned = Int(CGDisplayRotation(id).rounded())
        if turned != 0 { note.append("Turned \(turned)°") }
        return Row(label: "Display", value: value, note: note.joined(separator: " · "), mono: true)
    }

    /// The Mac's marketing name, "Mac mini (2024)", from the device tree's product node.
    private static func productName() -> String? {
        let entry = IORegistryEntryFromPath(kIOMainPortDefault, "IODeviceTree:/product")
        guard entry != 0 else { return nil }
        defer { IOObjectRelease(entry) }
        guard let data = IORegistryEntryCreateCFProperty(entry, "product-name" as CFString, kCFAllocatorDefault, 0)?
            .takeRetainedValue() as? Data else { return nil }
        let name = String(decoding: data.prefix { $0 != 0 }, as: UTF8.self)
        return name.isEmpty ? nil : name
    }

    /// The startup volume's format, "APFS".
    private static func fileSystem() -> String? {
        var fs = statfs()
        guard statfs("/", &fs) == 0 else { return nil }
        let name = withUnsafeBytes(of: fs.f_fstypename) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
        return name.isEmpty ? nil : name.uppercased()
    }

    /// The apps in /Applications, ~/Applications and /System/Applications, one folder deep (Utilities).
    private static func appCount() -> Int {
        let fm = FileManager.default
        let roots = ["/Applications", NSHomeDirectory() + "/Applications", "/System/Applications"]
        var seen = Set<String>()
        for root in roots {
            for name in (try? fm.contentsOfDirectory(atPath: root)) ?? [] {
                if name.hasSuffix(".app") { seen.insert(name); continue }
                var folder: ObjCBool = false
                guard !name.hasPrefix("."), fm.fileExists(atPath: root + "/" + name, isDirectory: &folder), folder.boolValue else { continue }
                for inner in (try? fm.contentsOfDirectory(atPath: root + "/" + name)) ?? [] where inner.hasSuffix(".app") { seen.insert(inner) }
            }
        }
        return seen.count
    }

    /// When Setup Assistant finished on this Mac; the startup volume's birth if that marker cannot be read.
    private static func setUpDate() -> Date? {
        let marker = URL(fileURLWithPath: "/var/db/.AppleSetupDone")
        if let date = (try? marker.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate { return date }
        return (try? URL(fileURLWithPath: "/").resourceValues(forKeys: [.volumeCreationDateKey]))?.volumeCreationDate
    }

    private static func bootTime() -> Date? {
        var boot = timeval()
        var size = MemoryLayout<timeval>.size
        guard sysctlbyname("kern.boottime", &boot, &size, nil, 0) == 0, boot.tv_sec > 0 else { return nil }
        return Date(timeIntervalSince1970: Double(boot.tv_sec))
    }

    /// "179 days", "1 day".
    static func days(from start: Date, to end: Date) -> String {
        let n = max(0, Calendar.current.dateComponents([.day], from: start, to: end).day ?? 0)
        return n == 1 ? "1 day" : "\(n) days"
    }

    /// "2 days, 21 hours, 58 mins", as fastfetch says it; the parts that are 0 left out, "0 mins" for none.
    static func uptime(_ seconds: TimeInterval) -> String {
        let total = max(0, Int(seconds) / 60)
        let parts = [(total / 1440, "day"), (total / 60 % 24, "hour"), (total % 60, "min")]
            .filter { $0.0 > 0 }.map { "\($0.0) \($0.1)\($0.0 == 1 ? "" : "s")" }
        return parts.isEmpty ? "0 mins" : parts.joined(separator: ", ")
    }
}

extension SystemReader {
    /// An integer sysctl, or nil when it does not read.
    static func sysctlInt(_ name: String) -> Int? {
        var value: Int32 = 0
        var size = MemoryLayout<Int32>.size
        return sysctlbyname(name, &value, &size, nil, 0) == 0 ? Int(value) : nil
    }
}
