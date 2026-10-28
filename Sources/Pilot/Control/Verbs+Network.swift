import PilotCore

/// What `pilot wifi` and `pilot bluetooth` reach (CLI W8): the Mac's Wi-Fi and paired Bluetooth devices, through the same
/// calls as System › Wi-Fi and Bluetooth. Made on first use and kept, so a join finds the networks the last list scanned.
/// The tests hand in the Setup fakes, so nothing turns Wi-Fi off, scans, joins, connects or raises a macOS prompt.
@MainActor
final class NetworkTools {
    lazy var wifi: WiFiSystem = CoreWLANSystem()
    lazy var bluetooth: BluetoothSystem = IOBluetoothSystem()

    /// allowed, notAsked or denied.
    static func access(_ access: PrivacyAccess) -> JSONValue { .string("\(access)") }

    /// The System section where Sven gives what a verb lacks: the verbs never raise macOS's prompt, which needs his hands.
    static func next(_ section: SetupSection) -> String { "Next: pilot open system --section \(section.rawValue)" }

    /// Why a Location or Bluetooth answer other than allowed stops a verb, and where Sven gives it.
    static func blocked(_ access: PrivacyAccess, notAsked: String, denied: String, section: SetupSection) -> ControlError {
        ControlError(.notReady, "\(access == .denied ? denied : notAsked) \(next(section))")
    }
}

extension ControlVerbs {
    /// `pilot wifi [on|off|networks|join]` and `pilot bluetooth [connect|disconnect]`.
    func registerNetwork(_ tools: NetworkTools) {
        let wifiWords = ["status", "on", "off", "networks", "join"], bluetoothWords = ["devices", "connect", "disconnect"]
        let wifiIndex = JSONValue.array(wifiWords.map(JSONValue.string)), bluetoothIndex = JSONValue.array(bluetoothWords.map(JSONValue.string))
        let wifiDetail: [String: String] = [
            "status": "pilot wifi: on, the joined network, signal (dBm), rate (Mbit/s) and Location access; macOS hides the network's name without Location. present false: this Mac has no Wi-Fi.",
            "on": "pilot wifi on|off: turns Wi-Fi on or off, as the page's switch, and answers the status after.",
            "networks": "pilot wifi networks [--fresh]: the networks nearby, strongest first, each name once: name, signal, secured, joined. --fresh scans the radio (Scan again); otherwise macOS's last results. Needs Wi-Fi on and Location access.",
            "join": "pilot wifi join <name>: joins an open network, or a secured one this Mac knows (macOS uses its saved password), and answers the status after. A password is typed on the page, never sent through the command.",
        ]
        let bluetoothDetail: [String: String] = [
            "devices": "pilot bluetooth: Bluetooth access and, once allowed, the paired devices: address, name, connected.",
            "connect": "pilot bluetooth connect|disconnect <address|name>: connects or disconnects a paired device, as its row's button, and answers its row after.",
        ]
        register(ControlVerb("wifi", help: "Wi-Fi's status, on or off, the networks nearby, and joining an open or known one.",
                             usage: "pilot wifi [status | on | off | networks [--fresh] | join <name>]",
                             flags: [.init("fresh", help: "networks only: scan the radio instead of macOS's last results", takesValue: false)],
                             schema: {
                                 .object(["subcommands": wifiIndex, "rowKey": .string("name"),
                                          "status": .object(["present": .string("false: this Mac has no Wi-Fi"), "on": .string("the radio"),
                                                             "network": .string("the joined network, absent when off, not joined or hidden for want of Location"),
                                                             "signal": .string("dBm"), "rate": .string("Mbit/s"), "location": .string("allowed, notAsked or denied")]),
                                          "rows": .object(["name": .string("the network"), "signal": .string("dBm"), "secured": .string("needs a password"),
                                                           "joined": .string("the network this Mac is on")])])
                             },
                             index: { .object(["subcommands": wifiIndex]) },
                             detail: { word in wifiDetail[word == "off" ? "on" : word] }) { call throws(ControlError) in
            let args = call.arguments()
            let word = args.positional.first ?? "status"
            if word != "networks", let refusal = ControlVerb.unknownFlag(args.flags, known: [], in: "pilot wifi \(word)") { throw refusal }
            switch word {
            case "status": return Self.wifiStatus(tools.wifi)
            case "on", "off": return try await Self.wifiPower(word == "on", tools.wifi)
            case "networks": return try await Self.networks(tools.wifi, fresh: args.has("fresh"))
            case "join": return try await Self.join(try args.word(1, "network name"), tools.wifi)
            case let other: throw ControlError(.badValue, "no wifi \(other); subcommands: \(wifiWords.joined(separator: ", "))")
            }
        })
        register(ControlVerb("bluetooth", help: "Bluetooth access, the paired devices, and connecting or disconnecting one.",
                             usage: "pilot bluetooth [devices | connect <address|name> | disconnect <address|name>]", flags: [],
                             schema: {
                                 .object(["subcommands": bluetoothIndex, "rowKey": .string("address"),
                                          "access": .string("allowed, notAsked or denied; devices are listed only once allowed"),
                                          "rows": .object(["address": .string("the device's Bluetooth address"), "name": .string("its name"),
                                                           "connected": .string("connected now")])])
                             },
                             index: { .object(["subcommands": bluetoothIndex]) },
                             detail: { word in bluetoothDetail[word == "disconnect" ? "connect" : word] }) { call throws(ControlError) in
            let args = call.arguments()
            switch args.positional.first ?? "devices" {
            case "devices": return await Self.bluetoothDevices(tools.bluetooth)
            case let word where word == "connect" || word == "disconnect":
                return try await Self.connect(word == "connect", try args.word(1, "device address or name"), tools.bluetooth)
            case let other: throw ControlError(.badValue, "no bluetooth \(other); subcommands: \(bluetoothWords.joined(separator: ", "))")
            }
        })
    }

    private static func wifiStatus(_ wifi: WiFiSystem) -> JSONValue {
        guard let status = wifi.status() else { return .object(["present": .bool(false)]) }
        var answer: [String: JSONValue] = ["present": .bool(true), "on": .bool(status.on), "location": NetworkTools.access(wifi.locationAccess())]
        answer["network"] = status.network.map(JSONValue.string)
        answer["signal"] = status.signal.map { .number(Double($0)) }
        answer["rate"] = status.rate.map(JSONValue.number)
        return .object(answer)
    }

    /// The status, or bad-value on a Mac with no Wi-Fi.
    private static func present(_ wifi: WiFiSystem) throws(ControlError) -> WiFiStatus {
        guard let status = wifi.status() else { throw ControlError(.badValue, "this Mac has no Wi-Fi") }
        return status
    }

    private static func wifiPower(_ on: Bool, _ wifi: WiFiSystem) async throws(ControlError) -> JSONValue {
        _ = try present(wifi)
        do { try await wifi.setPower(on) } catch {
            throw ControlError(.badValue, "macOS did not turn Wi-Fi \(on ? "on" : "off"): \(error.localizedDescription)")
        }
        slog.notice("wi-fi \(on ? "on" : "off", privacy: .public), from the pilot command")
        return wifiStatus(wifi)
    }

    /// What the page's list and join need: Wi-Fi on and Location access. The status, or not-ready saying which is missing.
    private static func listable(_ wifi: WiFiSystem) throws(ControlError) -> WiFiStatus {
        let status = try present(wifi)
        guard status.on else { throw ControlError(.notReady, "Wi-Fi is off. Next: pilot wifi on") }
        let location = wifi.locationAccess()
        guard location == .allowed else {
            throw NetworkTools.blocked(location, notAsked: SetupWiFi.hiddenLine + " Show networks on the page asks.", denied: SetupWiFi.deniedLine, section: .wifi)
        }
        return status
    }

    private static func scan(_ wifi: WiFiSystem, fresh: Bool) async throws(ControlError) -> [WiFiNetwork] {
        do { return try await wifi.scan(fresh: fresh) } catch { throw ControlError(.badValue, "Scanning failed: \(error.localizedDescription)") }
    }

    /// The page's list: strongest first, each name once, the joined one marked.
    private static func networks(_ wifi: WiFiSystem, fresh: Bool) async throws(ControlError) -> JSONValue {
        let joined = try listable(wifi).network
        let found = try await scan(wifi, fresh: fresh)
        return .array(Dictionary(found.map { ($0.name, $0) }, uniquingKeysWith: { $0.signal >= $1.signal ? $0 : $1 }).values
            .sorted { ($0.signal, $1.name) > ($1.signal, $0.name) }
            .map { .object(["name": .string($0.name), "signal": .number(Double($0.signal)), "secured": .bool($0.secured), "joined": .bool($0.name == joined)]) })
    }

    /// Joins `name` with no password: an open network, or a secured one macOS has saved. macOS's last scan is read first,
    /// as the page's list is; a name it lacks is scanned for by the join itself.
    private static func join(_ name: String, _ wifi: WiFiSystem) async throws(ControlError) -> JSONValue {
        _ = try listable(wifi)
        let open = try await scan(wifi, fresh: false).first { $0.name == name }.map { !$0.secured } ?? false
        do { try await wifi.join(name, password: nil) } catch {
            let password = open ? "" : "; a secured network this Mac does not know needs its password on the page. \(NetworkTools.next(.wifi))"
            throw ControlError(.badValue, "Did not join: \(error.localizedDescription)\(password)")
        }
        slog.notice("wi-fi join done, from the pilot command")
        return wifiStatus(wifi)
    }

    private static func bluetoothDevices(_ bluetooth: BluetoothSystem) async -> JSONValue {
        let access = bluetooth.authorization()
        var answer: [String: JSONValue] = ["access": NetworkTools.access(access)]
        // Listing before access is given would raise macOS's prompt, so it waits for the page's Show paired devices.
        if access == .allowed { answer["devices"] = .array(await bluetooth.paired().map(row)) }
        return .object(answer)
    }

    private static func row(_ device: BluetoothDevice) -> JSONValue {
        .object(["address": .string(device.address), "name": .string(device.name), "connected": .bool(device.connected)])
    }

    /// Connects or disconnects the paired device `target` names, by address or by a name only one has; one already so is
    /// answered as it is. Its row is read again after.
    private static func connect(_ connecting: Bool, _ target: String, _ bluetooth: BluetoothSystem) async throws(ControlError) -> JSONValue {
        let access = bluetooth.authorization()
        guard access == .allowed else {
            throw NetworkTools.blocked(access, notAsked: "Pilot has not asked for Bluetooth yet; Show paired devices on the page asks.",
                                       denied: SetupBluetooth.deniedLine, section: .bluetooth)
        }
        let device = try pick(target, await bluetooth.paired())
        guard device.connected != connecting else { return row(device) }
        let ok = connecting ? await bluetooth.connect(device.address) : await bluetooth.disconnect(device.address)
        slog.notice("bluetooth \(connecting ? "connect" : "disconnect", privacy: .public) \(ok ? "done" : "failed", privacy: .public), from the pilot command")
        guard ok else {
            throw ControlError(.badValue, connecting ? "Did not connect: it may be off, asleep or out of range" : "macOS did not disconnect it")
        }
        return row(await bluetooth.paired().first { $0.address == device.address } ?? device)
    }

    private static func pick(_ target: String, _ devices: [BluetoothDevice]) throws(ControlError) -> BluetoothDevice {
        if let device = devices.first(where: { $0.address.caseInsensitiveCompare(target) == .orderedSame }) { return device }
        let named = devices.filter { $0.name == target }
        guard named.count <= 1 else {
            throw ControlError(.badValue, "\(named.count) paired devices are named \(target); name one by address: \(named.map(\.address).joined(separator: ", "))")
        }
        guard let device = named.first else { throw ControlError(.badValue, "no paired device \(target); pilot bluetooth lists them") }
        return device
    }
}
