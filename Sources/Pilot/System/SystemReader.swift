import CoreWLAN
import Darwin
import Foundation
import IOKit
import IOKit.ps
import PilotCore
import SystemConfiguration

/// Reads one SystemStats.Raw through public macOS APIs, as exelban/stats (MIT) does for the same numbers, none of its
/// code: Mach host statistics for CPU and memory, sysctl for memory pressure and the interfaces' 64-bit byte counters,
/// the startup volume's resource values, IOKit's power sources and graphics accelerators, ProcessInfo for heat and
/// kern.boottime for uptime; per core, Mach's processor info; the startup disk's speed, battery health and Bluetooth HID
/// batteries from the IORegistry; temperatures, fans and power from the SMC's private interface (SMC); the primary interface's address through SystemConfiguration (card agent-bo-95422831). The
/// per-tick read is a few system calls plus the SMC's, about 4 ms on an M4; only `ps` (the process list, while a view shows it,
/// about 50 ms) and `system_profiler` (earbud batteries, with the slow readings) start a process, the two side by side,
/// and nothing starts a helper.
enum SystemReader {
    /// The parts asked for and nothing else (card agent-bo-95422836): the menu bar's CPU and RAM item asks for two Mach
    /// calls, This Mac's rows for everything; the slow parts (disk space, about 20 ms; the IP, battery health, charger;
    /// Bluetooth through system_profiler) and the process list only when asked.
    static func read(_ parts: SystemStats.Parts) async -> SystemStats.Raw {
        async let ps = parts.contains(.processes)
            ? (try? await ChildProcess.run("/bin/ps", Activity.psArguments, timeout: .seconds(2))) : nil
        async let profiler = parts.contains(.bluetooth)
            ? (try? await ChildProcess.run("/usr/sbin/system_profiler", ["SPBluetoothDataType", "-json"], timeout: .seconds(5))) : nil
        let info = ProcessInfo.processInfo
        let (gpu, gpuDetail) = parts.contains(.gpu) ? graphics() : (nil, nil)
        let details = parts.contains(.details)
        var raw = SystemStats.Raw(time: info.systemUptime, cpu: parts.contains(.cpu) ? cpu() : .zero,
                                  memory: parts.contains(.memory) ? memory() : .zero, network: parts.contains(.network) ? network() : .zero,
                                  battery: parts.contains(.battery) ? battery() : nil,
                                  thermal: details ? thermal(info.thermalState) : .nominal,
                                  uptime: details ? sinceBoot() ?? info.systemUptime : info.systemUptime, gpu: gpu)
        raw.parts = parts
        if parts.contains(.sensors) { raw.sensors = SMC.shared.sensors() }
        // A Mac with no battery shows its draw in the battery's place: one SMC key, not the sensors' walk.
        if parts.contains(.battery), raw.battery == nil { raw.systemPower = raw.sensors?.power ?? SMC.shared.power() }
        // With the CPU, not This Mac's details: the CPU item's tooltip shows it (card agent-bo-95423038), and it is one call.
        if parts.contains(.cpu) {
            var load = [Double](repeating: 0, count: 3)
            if getloadavg(&load, 3) == 3 { raw.load = load }
        }
        if details {
            raw.gpuDetail = gpuDetail
            if raw.battery != nil {
                let battery = properties(services("AppleSmartBattery"), ["Temperature", "Voltage", "Amperage", "AdapterDetails"])
                raw.batteryPower = battery.lazy.compactMap(SystemStats.BatteryPower.reading).first
                raw.adapterVolts = battery.lazy.compactMap { ($0["AdapterDetails"] as? [String: Any])?["AdapterVoltage"] as? NSNumber }
                    .first.flatMap { $0.doubleValue > 0 ? $0.doubleValue / 1000 : nil }
            }
            raw.cores = cores()
            raw.efficiencyCores = efficiencyCores
        }
        if parts.contains(.diskIO) {
            raw.diskIO = SystemStats.diskIO(startupDiskDriver.flatMap {
                IORegistryEntryCreateCFProperty($0, "Statistics" as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() as? [String: Any]
            })
        }
        if parts.contains(.diskSpace) { raw.slow.disk = disk() }
        if parts.contains(.slowDetails) {
            (raw.slow.localIP, raw.slow.interface) = primaryInterface()
            raw.slow.machine = machine
            raw.slow.wifi = wifiLink()
            raw.slow.diskKind = diskKind
            raw.slow.chargerWatts = (IOPSCopyExternalPowerAdapterDetails()?.takeRetainedValue() as? [String: Any])?[kIOPSPowerAdapterWattsKey] as? Int
            raw.slow.batteryHealth = properties(services("AppleSmartBattery"), ["CycleCount", "AppleRawMaxCapacity", "NominalChargeCapacity",
                                                                               "DesignCapacity"]).lazy.compactMap(SystemStats.BatteryHealth.reading).first
        }
        if !parts.isDisjoint(with: [.bluetooth, .bluetoothHID]) {
            // system_profiler's earbuds only with .bluetooth; empty data reads as none.
            raw.slow.bluetooth = SystemStats.bluetooth(hid: properties(services("AppleDeviceManagementHIDEventService"), ["Product", "BatteryPercent"]),
                                                       profiler: Data((await profiler ?? "").utf8))
        }
        if let ps = await ps {
            // Activity's listing: the busiest lists keep ps's resident size, the tree takes the footprint where it reads.
            let tree = Activity.parse(ps)
            raw.processes = tree.map(KillProcess.Row.init)
            let (io, footprints) = processUsage(tree.map(\.pid))
            raw.processIO = io
            raw.tree = Activity.footprinted(tree) { footprints[$0] }
        }
        return raw
    }

    /// One nettop snapshot of every process's bytes in and out (about five seconds; Stats reads it the same way).
    static func netTop() async -> String? {
        try? await ChildProcess.run("/usr/bin/nettop", ["-P", "-L", "1", "-x", "-J", "bytes_in,bytes_out"], timeout: .seconds(15))
    }

    /// Each process's bytes read from and written to disk since it started, and its memory as Activity Monitor counts it
    /// (the footprint, for Activity.footprinted), from one proc_pid_rusage each; a process macOS will not
    /// show, such as another user's, is left out, as in Stats.
    private static func processUsage(_ pids: [Int32]) -> (io: [Int32: SystemStats.DiskIO], footprints: [Int32: UInt64]) {
        var counts: [Int32: SystemStats.DiskIO] = [:], footprints: [Int32: UInt64] = [:]
        for pid in pids {
            var info = rusage_info_v2()
            let ok = withUnsafeMutablePointer(to: &info) {
                $0.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { proc_pid_rusage(pid, RUSAGE_INFO_V2, $0) }
            }
            guard ok == 0 else { continue }
            counts[pid] = .init(read: info.ri_diskio_bytesread, written: info.ri_diskio_byteswritten)
            footprints[pid] = info.ri_phys_footprint
        }
        return (counts, footprints)
    }

    /// The Wi-Fi link from CoreWLAN: channel, band, signal, noise, rate and standard; nil with Wi-Fi off or not joined.
    /// Never the network's name, which needs Location access (macOS hides it without).
    private static func wifiLink() -> SystemStats.WiFiLink? {
        guard let wifi = CWWiFiClient.shared().interface(), wifi.powerOn(), let channel = wifi.wlanChannel(), wifi.rssiValue() != 0 else { return nil }
        let band: String? = switch channel.channelBand {
        case .band2GHz: "2.4 GHz"
        case .band5GHz: "5 GHz"
        case .band6GHz: "6 GHz"
        default: nil
        }
        let standard: String? = switch wifi.activePHYMode() {
        case .mode11a: "802.11a"
        case .mode11b: "802.11b"
        case .mode11g: "802.11g"
        case .mode11n: "802.11n"
        case .mode11ac: "802.11ac"
        case .mode11ax: "802.11ax"
        default: nil
        }
        return .init(channel: channel.channelNumber, band: band, signal: wifi.rssiValue(), noise: wifi.noiseMeasurement(),
                     rate: wifi.transmitRate(), standard: standard)
    }

    /// The startup volume's file system and its disk's connection, read once.
    private static let diskKind: SystemStats.DiskKind = {
        let fileSystem = try? URL(fileURLWithPath: "/").resourceValues(forKeys: [.volumeLocalizedFormatDescriptionKey]).volumeLocalizedFormatDescription
        let connection = startupDiskDriver.flatMap {
            IORegistryEntrySearchCFProperty($0, kIOServicePlane, "Protocol Characteristics" as CFString, kCFAllocatorDefault,
                                            IOOptionBits(kIORegistryIterateRecursively | kIORegistryIterateParents)) as? [String: Any]
        }?["Physical Interconnect"] as? String
        return .init(fileSystem: fileSystem, connection: connection)
    }()

    /// This Mac's public address from api.ipify.org: the one reading that calls the internet, made only while the setting
    /// that shows it is on (SystemSampler).
    static func publicIP() async -> String? {
        var request = URLRequest(url: URL(string: "https://api.ipify.org")!)
        request.timeoutInterval = 10
        guard let (data, _) = try? await URLSession.shared.data(for: request) else { return nil }
        let ip = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        return !ip.isEmpty && ip.count <= 45 && ip.allSatisfy({ $0.isHexDigit || $0 == "." || $0 == ":" }) ? ip : nil
    }

    /// Every IOKit service of `className`, each retained for the caller to release (or keep, as `accelerators` does).
    private static func services(_ className: String) -> [io_service_t] {
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching(className), &iterator) == KERN_SUCCESS else { return [] }
        defer { IOObjectRelease(iterator) }
        var services: [io_service_t] = []
        while case let service = IOIteratorNext(iterator), service != 0 { services.append(service) }
        return services
    }

    /// The named properties of each of `services`, those it has; releases the services.
    private static func properties(_ services: [io_service_t], _ keys: [String]) -> [[String: Any]] {
        services.map { service in
            defer { IOObjectRelease(service) }
            var values: [String: Any] = [:]
            for key in keys {
                values[key] = IORegistryEntryCreateCFProperty(service, key as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue()
            }
            return values
        }
    }

    /// Each core's ticks, in macOS's order (the efficiency cores first on Apple silicon).
    private static func cores() -> [SystemStats.CPUTicks] {
        var count: natural_t = 0, info: processor_info_array_t?, infoCount: mach_msg_type_number_t = 0
        guard host_processor_info(mach_host_self(), PROCESSOR_CPU_LOAD_INFO, &count, &info, &infoCount) == KERN_SUCCESS,
              let info else { return [] }
        defer { vm_deallocate(mach_task_self_, vm_address_t(bitPattern: info), vm_size_t(infoCount) * vm_size_t(MemoryLayout<integer_t>.stride)) }
        let states = Int(CPU_STATE_MAX)
        return (0..<Int(count)).map { core in
            let tick = { (state: Int32) in UInt64(UInt32(bitPattern: info[core * states + Int(state)])) }
            return .init(user: tick(CPU_STATE_USER), system: tick(CPU_STATE_SYSTEM), idle: tick(CPU_STATE_IDLE), nice: tick(CPU_STATE_NICE))
        }
    }

    /// hw.perflevel1's cores when it is the efficiency level; 0 on a Mac with one kind of core.
    private static let efficiencyCores: Int = {
        guard sysctlString("hw.perflevel1.name") == "Efficiency" else { return 0 }
        var cores: Int32 = 0
        var size = MemoryLayout<Int32>.size
        return sysctlbyname("hw.perflevel1.logicalcpu", &cores, &size, nil, 0) == 0 ? Int(cores) : 0
    }()

    /// A string sysctl, or nil when it does not read.
    static func sysctlString(_ name: String) -> String? {
        var size = 0
        guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0 else { return nil }
        var value = [CChar](repeating: 0, count: size)
        return sysctlbyname(name, &value, &size, nil, 0) == 0 ? String(cString: value) : nil
    }

    /// The interface macOS routes through (State:/Network/Global/IPv4's PrimaryInterface): its IPv4 address, and its
    /// name, hardware address and the DNS servers in use (State:/Network/Global/DNS).
    private static func primaryInterface() -> (String?, SystemStats.Interface?) {
        guard let global = SCDynamicStoreCopyValue(nil, "State:/Network/Global/IPv4" as CFString) as? [String: Any],
              let primary = global["PrimaryInterface"] as? String else { return (nil, nil) }
        let dns = (SCDynamicStoreCopyValue(nil, "State:/Network/Global/DNS" as CFString) as? [String: Any])?["ServerAddresses"] as? [String] ?? []
        var list: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&list) == 0, let first = list else { return (nil, .init(name: primary, hardwareAddress: nil, dns: dns)) }
        defer { freeifaddrs(list) }
        var ip: String?
        for entry in sequence(first: first, next: { $0.pointee.ifa_next }) {
            guard let address = entry.pointee.ifa_addr, address.pointee.sa_family == UInt8(AF_INET),
                  String(cString: entry.pointee.ifa_name) == primary else { continue }
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            if getnameinfo(address, socklen_t(address.pointee.sa_len), &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0 {
                ip = String(cString: host)
                break
            }
        }
        // The interface's own address from SystemConfiguration, as networksetup reads it: on macOS 27 getifaddrs and
        // ifconfig show 02:00:00:00:00:00 in its place.
        let hardware = (SCNetworkInterfaceCopyAll() as? [SCNetworkInterface])?
            .first { SCNetworkInterfaceGetBSDName($0) as String? == primary }
            .flatMap { SCNetworkInterfaceGetHardwareAddressString($0) as String? }
        return (ip, .init(name: primary, hardwareAddress: hardware, dns: dns))
    }

    /// The chip, model identifier and macOS version, read once.
    static let machine: SystemStats.Machine = {
        let v = ProcessInfo.processInfo.operatingSystemVersion
        return .init(chip: sysctlString("machdep.cpu.brand_string") ?? "?", model: sysctlString("hw.model") ?? "?",
                     macOS: "\(v.majorVersion).\(v.minorVersion)" + (v.patchVersion > 0 ? ".\(v.patchVersion)" : ""))
    }()

    /// Wall time since kern.boottime; systemUptime leaves out the time the Mac slept.
    private static func sinceBoot() -> TimeInterval? {
        var boot = timeval()
        var size = MemoryLayout<timeval>.size
        guard sysctlbyname("kern.boottime", &boot, &size, nil, 0) == 0, boot.tv_sec > 0 else { return nil }
        return Date().timeIntervalSince1970 - (Double(boot.tv_sec) + Double(boot.tv_usec) / 1_000_000)
    }

    /// One host_statistics flavour into `value`, which stays zeroed when the call fails.
    private static func host<T>(_ value: inout T, _ flavor: Int32, _ call: (host_t, host_flavor_t, host_info_t, UnsafeMutablePointer<mach_msg_type_number_t>) -> kern_return_t) {
        var count = mach_msg_type_number_t(MemoryLayout<T>.size / MemoryLayout<integer_t>.size)
        _ = withUnsafeMutablePointer(to: &value) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { call(mach_host_self(), flavor, $0, &count) }
        }
    }

    private static func cpu() -> SystemStats.CPUTicks {
        var load = host_cpu_load_info()
        host(&load, HOST_CPU_LOAD_INFO, host_statistics)
        let t = load.cpu_ticks
        return .init(user: UInt64(t.0), system: UInt64(t.1), idle: UInt64(t.2), nice: UInt64(t.3))
    }

    static func memory() -> SystemStats.Memory {
        var vm = vm_statistics64()
        host(&vm, HOST_VM_INFO64) { host_statistics64($0, $1, $2, $3) }
        var level: Int32 = 1
        var size = MemoryLayout<Int32>.size
        sysctlbyname("kern.memorystatus_vm_pressure_level", &level, &size, nil, 0)
        var swap = xsw_usage()
        size = MemoryLayout<xsw_usage>.size
        sysctlbyname("vm.swapusage", &swap, &size, nil, 0)
        return .init(total: ProcessInfo.processInfo.physicalMemory, pageSize: UInt64(getpagesize()),
                     active: UInt64(vm.active_count), inactive: UInt64(vm.inactive_count), speculative: UInt64(vm.speculative_count),
                     wired: UInt64(vm.wire_count), compressed: UInt64(vm.compressor_page_count), purgeable: UInt64(vm.purgeable_count),
                     external: UInt64(vm.external_page_count), pressure: .init(level: level),
                     swapUsed: swap.xsu_used, swapTotal: swap.xsu_total)
    }

    /// The Wi-Fi and Ethernet interfaces (en0, en1 …), summed from the routing table's 64-bit counters.
    private static func network() -> SystemStats.Network {
        var mib: [Int32] = [CTL_NET, PF_ROUTE, 0, 0, NET_RT_IFLIST2, 0]
        var length = 0
        guard sysctl(&mib, 6, nil, &length, nil, 0) == 0, length > 0 else { return .init(received: 0, sent: 0) }
        var buffer = [UInt8](repeating: 0, count: length)
        guard sysctl(&mib, 6, &buffer, &length, nil, 0) == 0 else { return .init(received: 0, sent: 0) }
        let wired = wiredInterfaces()
        var received: UInt64 = 0, sent: UInt64 = 0
        buffer.withUnsafeBytes { raw in
            var offset = 0
            while offset + MemoryLayout<if_msghdr>.size <= length {
                let header = raw.load(fromByteOffset: offset, as: if_msghdr.self)
                guard header.ifm_msglen > 0 else { break }
                if Int32(header.ifm_type) == RTM_IFINFO2 {
                    let message = raw.load(fromByteOffset: offset, as: if_msghdr2.self)
                    if wired.contains(UInt32(message.ifm_index)) {
                        received += message.ifm_data.ifi_ibytes
                        sent += message.ifm_data.ifi_obytes
                    }
                }
                offset += Int(header.ifm_msglen)
            }
        }
        return .init(received: received, sent: sent)
    }

    /// The indexes of the en interfaces (Wi-Fi, Ethernet), named in one call rather than one per interface.
    private static func wiredInterfaces() -> Set<UInt32> {
        guard let list = if_nameindex() else { return [] }
        defer { if_freenameindex(list) }
        var indexes: Set<UInt32> = []
        var entry = list
        while entry.pointee.if_index != 0 {
            if let name = entry.pointee.if_name, String(cString: name).hasPrefix("en") { indexes.insert(entry.pointee.if_index) }
            entry += 1
        }
        return indexes
    }

    static func disk() -> SystemStats.Disk? {
        let keys: Set<URLResourceKey> = [.volumeAvailableCapacityForImportantUsageKey, .volumeTotalCapacityKey]
        guard let values = try? URL(fileURLWithPath: "/").resourceValues(forKeys: keys),
              let available = values.volumeAvailableCapacityForImportantUsage, let total = values.volumeTotalCapacity else { return nil }
        return .init(available: available, total: Int64(total))
    }

    /// The internal battery, or nil on a Mac with none.
    static func battery() -> SystemStats.Battery? {
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let list = IOPSCopyPowerSourcesList(info)?.takeRetainedValue() as? [CFTypeRef] else { return nil }
        for source in list {
            guard let d = IOPSGetPowerSourceDescription(info, source)?.takeUnretainedValue() as? [String: Any],
                  d[kIOPSTypeKey] as? String == kIOPSInternalBatteryType,
                  let current = d[kIOPSCurrentCapacityKey] as? Int, let max = d[kIOPSMaxCapacityKey] as? Int, max > 0 else { continue }
            return .reading(percent: current * 100 / max, charging: d[kIOPSIsChargingKey] as? Bool ?? false,
                            onACPower: d[kIOPSPowerSourceStateKey] as? String == kIOPSACPowerValue,
                            toFull: d[kIOPSTimeToFullChargeKey] as? Int, toEmpty: d[kIOPSTimeToEmptyKey] as? Int)
        }
        return nil
    }

    /// Each graphics accelerator, with its model ("Apple M4") and GPU core count, matched and read once: a Mac's set does
    /// not change while Pilot runs (the services are kept for its lifetime).
    static let accelerators: [(service: io_service_t, model: String?, cores: Int?)] = services("IOAccelerator").map { service in
        let value = { (key: String) in IORegistryEntryCreateCFProperty(service, key as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() }
        return (service, value("model") as? String, (value("gpu-core-count") as? NSNumber)?.intValue)
    }

    /// The block storage driver under the startup volume: from the BSD disk "/" is mounted from, up the service plane
    /// (through APFS's container to the physical disk), matched once and kept, as the startup disk never changes.
    private static let startupDiskDriver: io_registry_entry_t? = {
        var fs = statfs()
        guard statfs("/", &fs) == 0 else { return nil }
        let device = withUnsafeBytes(of: fs.f_mntfromname) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
        var entry = IOServiceGetMatchingService(kIOMainPortDefault, IOBSDNameMatching(kIOMainPortDefault, 0, (device as NSString).lastPathComponent))
        while entry != 0 {
            if IOObjectConformsTo(entry, "IOBlockStorageDriver") != 0 { return entry }
            var parent: io_registry_entry_t = 0
            let found = IORegistryEntryGetParentEntry(entry, kIOServicePlane, &parent) == KERN_SUCCESS
            IOObjectRelease(entry)
            entry = found ? parent : 0
        }
        return nil
    }()

    /// The busiest graphics accelerator's own busy share (its PerformanceStatistics, as Stats reads it); nil with none.
    /// With the busiest accelerator's parts (renderer, tiler) and its name and cores, as Stats' GPU popup shows them.
    private static func graphics() -> (Double?, SystemStats.GPUDetail?) {
        var busiest: (load: Double, detail: SystemStats.GPUDetail)?
        for accelerator in accelerators {
            let service = accelerator.service
            guard let property = IORegistryEntryCreateCFProperty(service, "PerformanceStatistics" as CFString, kCFAllocatorDefault, 0),
                  let statistics = property.takeRetainedValue() as? [String: Any],
                  let load = SystemStats.gpuLoad(statistics), load >= busiest?.load ?? 0 else { continue }
            busiest = (load, .reading(statistics, model: accelerator.model, cores: accelerator.cores))
        }
        return (busiest?.load, busiest?.detail)
    }

    private static func thermal(_ state: ProcessInfo.ThermalState) -> SystemStats.Thermal {
        switch state {
        case .nominal: .nominal
        case .fair: .fair
        case .serious: .serious
        case .critical: .critical
        @unknown default: .nominal
        }
    }
}
