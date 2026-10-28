import AppKit
import PilotCore

/// What `pilot stats` reaches (CLI W9): This Mac's one sampler, held for one beat as the Stats page holds it while it
/// shows, then its readings, busiest lists and minute history. The tests hand in their own sampler and screens.
@MainActor
final class ControlStats {
    var sampler = SystemSampler.shared
    /// Stats' Public IP switch: on, the beat also fetches the address, as the page does while it shows.
    var publicIPOn: @MainActor () -> Bool = { Engine.shared?.settings.showPublicIP ?? false }
    var screens: @MainActor () -> Int = { NSScreen.screens.count }
    /// The beat's tick, the page's 2 s; and how long it waits for a reading with rates before answering what it has.
    var every: Duration = .seconds(SystemStats.interval)
    var wait: Duration = .seconds(6)

    /// The cards a caller may narrow to: the page's blocks, then its machine line.
    static let cards = StatsCard.allCases.map(\.rawValue) + ["batteries", "busiest", "machine"]
    /// Each card in words, for `pilot help stats <card>`.
    static let cardHelp: [String: String] = [
        "cpu": "percent now; apps, macOS and idle shares; each core's percent; performance and efficiency cores; load over 1, 5, 15 min",
        "memory": "percent used; pressure (normal, warning, critical); used, total, apps, wired, compressed, swap in bytes",
        "storage": "startup disk: used percent, free and total bytes, low (under 20 GB free), read and write bytes a second",
        "network": "down and up bytes a second, the Wi-Fi link (signal, noise, channel, rate), local address, bytes moved today, public IP while its switch is on",
        "temperature": "CPU average and hottest, GPU and chip in °C, macOS's heat level, the whole Mac's power in W",
        "fan": "each fan's rpm, lowest and top rpm, percent of its top",
        "graphics": "percent busy, renderer and tiler, chip, GPU cores, screens",
        "batteries": "the Mac's battery (percent, state, minutes left, health, cycles, charger W) and Bluetooth devices' batteries",
        "busiest": "the five busiest apps by CPU and memory, and by network once nettop has read twice (about 10 s of the page showing)",
        "machine": "chip, model, macOS and uptime",
    ]
    /// The history fields each card charts.
    static let cardFields: [String: [String]] = [
        "cpu": ["cpu"], "memory": ["ram"], "storage": ["diskRead", "diskWrite"], "network": ["down", "up"],
        "temperature": ["heat"], "fan": ["fan"], "graphics": ["gpu"],
    ]
    /// StatsHistory.Point.fields' names, in its order; the first three are shares, answered as percent.
    static let fieldNames = ["cpu", "ram", "gpu", "down", "up", "diskRead", "diskWrite", "heat", "fan"]
    /// The words --range takes: the page's "2 min" as 2m, or StatsRange's own names.
    static func range(_ word: String) -> StatsRange? { word == "2m" ? .twoMinutes : StatsRange(rawValue: word) }

    /// Holds a watch for every reading and the busiest (and the public IP when its switch is on) until a tick after the
    /// ask has read with rates, or `wait` passes; timeout when nothing was ever read.
    func beat() async throws(ControlError) {
        // Locked or asleep, the sampler reads nothing (ScreenEvents), as the page then shows nothing new.
        guard !sampler.paused else { throw ControlError(.notReady, "the screen is locked or its displays sleep, so nothing is read") }
        let before = sampler.latest?.time, ip = publicIPOn()
        let held = Task { [sampler, every] in await sampler.watch(every: every, needs: ip ? [.rows, .processes, .publicIP] : [.rows, .processes]) }
        defer { held.cancel() }
        let clock = ContinuousClock(), end = clock.now.advanced(by: wait)
        while clock.now < end, !Task.isCancelled {
            if let raw = sampler.latest, raw.parts.isSuperset(of: [.cpu, .details]), before.map({ raw.time > $0 }) ?? true,
               sampler.latestValues?.cpu != nil, !sampler.busiestCPU.isEmpty, !ip || sampler.publicIP != nil { return }
            try? await Task.sleep(for: .milliseconds(50))
        }
        guard sampler.latest != nil else { throw ControlError(.timeout, "this Mac's readings did not come in \(wait.components.seconds) s") }
    }

    /// Every card as the page shows it now.
    func cards(today: [StatsHistory.Point]) -> [String: JSONValue] {
        let raw = sampler.latest, v = sampler.latestValues, slow = raw?.slow
        func object(_ pairs: [String: JSONValue?]) -> JSONValue { .object(pairs.compactMapValues(\.self)) }
        let percent = { (share: Double?) in share.map { JSONValue.number(($0 * 1000).rounded() / 10) } }
        let number = { (x: Double?) in x.flatMap { $0.isFinite ? JSONValue.number(($0 * 10).rounded() / 10) : nil } }
        let bytes = { (x: UInt64) in JSONValue.number(Double(x)) }
        let sensors = raw?.sensors
        let heat = { (prefixes: [String]) in sensors.flatMap { SystemStats.temperature($0.temperatures, prefixes: prefixes) } }
        let cpuHeat = heat(SystemStats.cpuSensors)
        let power = sensors?.power.flatMap { $0.isFinite && $0 > 0 && $0 < 2000 ? $0 : nil }
        let sane = { (rpm: Double) in rpm.isFinite && rpm >= 0 && rpm < 20_000 }
        let m = raw?.memory
        let count = raw?.cores.count ?? 0, efficiency = raw?.efficiencyCores ?? 0
        func rows(_ list: [SystemStats.Row]) -> JSONValue {
            .array(list.map { row in
                object(["name": .string(row.name), "value": .string(row.value),
                        "pid": Double(row.explanation.replacingOccurrences(of: "pid ", with: "")).map(JSONValue.number)])
            })
        }
        return [
            "machine": object(["chip": slow?.machine.map { .string($0.chip) }, "model": slow?.machine.map { .string($0.model) },
                               "macOS": slow?.machine.map { .string($0.macOS) },
                               "uptime": raw.map { .string(SystemStats.duration(minutes: Int($0.uptime / 60))) },
                               "uptimeSeconds": raw.map { .number($0.uptime.rounded()) }]),
            "cpu": object(["percent": percent(v?.cpu), "apps": percent(v?.split?[0]), "macOS": percent(v?.split?[1]), "idle": percent(v?.split?[2]),
                           "cores": v?.cores.map { .array($0.compactMap(percent)) }, "coreCount": count > 0 ? .number(Double(count)) : nil,
                           "performanceCores": count > 0 ? .number(Double(count - efficiency)) : nil,
                           "efficiencyCores": count > 0 ? .number(Double(efficiency)) : nil,
                           "load": raw.flatMap { $0.load.count == 3 ? .array($0.load.compactMap(number)) : nil }]),
            "memory": object(["percent": percent(v?.ram), "pressure": m.map { .string($0.pressure.rawValue) },
                              "used": m.map { bytes($0.used) }, "total": m.map { bytes($0.total) }, "apps": m.map { bytes($0.app) },
                              "wired": m.map { bytes($0.wired * $0.pageSize) }, "compressed": m.map { bytes($0.compressed * $0.pageSize) },
                              "swapUsed": m.map { bytes($0.swapUsed) }, "swapTotal": m.map { bytes($0.swapTotal) }]),
            // A macOS update wants about 20 GB free: the page's Low space line.
            "storage": object(["usedPercent": percent(raw?.diskUsed), "free": slow?.disk.map { .number(Double($0.available)) },
                               "total": slow?.disk.map { .number(Double($0.total)) }, "low": slow?.disk.map { .bool($0.available < 20_000_000_000) },
                               "readPerSecond": number(v?.diskRead), "writePerSecond": number(v?.diskWrite),
                               "fileSystem": slow?.diskKind?.fileSystem.map(JSONValue.string), "connection": slow?.diskKind?.connection.map(JSONValue.string)]),
            "network": object(["downPerSecond": number(v?.down), "upPerSecond": number(v?.up), "address": slow?.localIP.map(JSONValue.string),
                               "wifi": slow?.wifi.map { w in object(["signal": .number(Double(w.signal)), "noise": .number(Double(w.noise)),
                                                                     "channel": .number(Double(w.channel)), "band": w.band.map(JSONValue.string),
                                                                     "rate": number(w.rate), "standard": w.standard.map(JSONValue.string)]) },
                               // Each minute's average rate, a minute long: what moved today while Pilot read.
                               "today": today.isEmpty ? nil : .number(today.reduce(0) { $0 + (($1.down ?? 0) + ($1.up ?? 0)) * 60 }.rounded()),
                               "publicIP": publicIPOn() ? sampler.publicIP.map(JSONValue.string) ?? .null : nil]),
            "temperature": object(["cpu": number(cpuHeat?.average), "cpuHottest": number(cpuHeat?.hottest),
                                   "gpu": number(heat(SystemStats.gpuSensors)?.average), "chip": number(heat(SystemStats.socSensors)?.average),
                                   "thermal": raw.map { .string($0.thermal.rawValue) }, "power": number(power)]),
            "fan": .array((sensors?.fans ?? []).filter { sane($0.actual) }.map { f in
                let top = sane(f.maximum) && f.maximum > 0 ? f.maximum : nil
                return object(["rpm": number(f.actual.rounded()), "lowest": sane(f.minimum) && f.minimum > 0 ? number(f.minimum.rounded()) : nil,
                               "top": number(top?.rounded()), "percentOfTop": percent(top.map { f.actual / $0 })])
            }),
            "graphics": object(["percent": percent(v?.gpu), "renderer": percent(raw?.gpuDetail?.renderer), "tiler": percent(raw?.gpuDetail?.tiler),
                                "chip": raw?.gpuDetail?.model.map(JSONValue.string), "cores": raw?.gpuDetail?.cores.map { .number(Double($0)) },
                                "screens": .number(Double(screens()))]),
            "batteries": object(["battery": raw?.battery.map { b in
                                     object(["percent": .number(Double(b.percent)),
                                             "state": .string(b.charging ? "charging" : b.pluggedIn ? "plugged in" : "on battery"),
                                             "minutesLeft": b.minutesLeft.map { .number(Double($0)) },
                                             "health": slow?.batteryHealth.map { .number(Double($0.percent)) },
                                             "cycles": slow?.batteryHealth.map { .number(Double($0.cycles)) },
                                             "chargerWatts": slow?.chargerWatts.map { .number(Double($0)) }])
                                 } ?? .null,
                                 "bluetooth": .array((slow?.bluetooth ?? []).map { object(["name": .string($0.name), "level": .string($0.level)]) }),
                                 "power": number(power)]),
            "busiest": object(["cpu": rows(sampler.busiestCPU), "memory": rows(sampler.busiestMemory), "network": rows(sampler.busiestNetwork)]),
        ]
    }

    /// The range's points, oldest first, each field in `fields`: the sampler's last 2 minutes (every 2 s, no times), or
    /// the minute history's last hour or today.
    func history(_ range: StatsRange, fields: [String], now: Date) -> JSONValue {
        let points = range == .twoMinutes ? sampler.history.map { StatsHistory.Point(time: now, $0) } : sampler.minutes.points(range, now: now)
        let times = ISO8601DateFormatter()
        let shown = zip(Self.fieldNames, StatsHistory.Point.fields).enumerated().filter { fields.contains($0.element.0) }
        return .object([
            "range": .string(range.rawValue), "every": .number(range == .twoMinutes ? SystemStats.interval : 60),
            "points": .array(points.map { point in
                var entry: [String: JSONValue] = range == .twoMinutes ? [:] : ["time": .string(times.string(from: point.time))]
                for (i, (name, field)) in shown {
                    guard let value = point[keyPath: field], value.isFinite else { continue }
                    entry[name] = .number(i < 3 ? (value * 1000).rounded() / 10 : (value * 10).rounded() / 10)
                }
                return .object(entry)
            }),
        ])
    }
}

extension ControlVerbs {
    /// `stats`: the Mac › Stats page's readings, read for one beat.
    func registerStats(_ app: ControlStats) {
        let cards = ControlStats.cards, ranges = ["2m", StatsRange.hour.rawValue, StatsRange.today.rawValue]
        register(ControlVerb("stats", help: "This Mac's readings as the Stats page shows them; --range adds the charts' points.",
                             usage: "pilot stats [--card <card>] [--range 2m|hour|today]",
                             flags: [.init("card", help: "one card: \(cards.joined(separator: ", "))"),
                                     .init("range", help: "the charts' points: 2m (every 2 s while a reading shows), hour or today (a minute each)")],
                             schema: {
                                 .object(["cards": .object(ControlStats.cardHelp.mapValues(JSONValue.string)), "ranges": .array(ranges.map(JSONValue.string)),
                                          "units": .string("percent 0 to 100; bytes, and bytes a second for rates; °C; W; rpm; a reading the Mac does not give is left out"),
                                          "history": .string("points oldest first: cpu, ram, gpu in percent; down, up, diskRead, diskWrite in bytes a second; heat in °C; fan in rpm")])
                             },
                             index: { .object(["cards": .array(cards.map(JSONValue.string)), "ranges": .array(ranges.map(JSONValue.string))]) },
                             detail: { word in ControlStats.cardHelp[word].map { "\(word): \($0)" } }) { call throws(ControlError) in
            let args = call.arguments()
            let card = args.value("card")
            if let card, !cards.contains(card) { throw ControlError(.badValue, "no card \(card); cards: \(cards.joined(separator: ", "))") }
            let range = try args.value("range").map { word throws(ControlError) in
                guard let range = ControlStats.range(word) else { throw ControlError(.badValue, "no range \(word); ranges: \(ranges.joined(separator: ", "))") }
                return range
            }
            if let card, range != nil, ControlStats.cardFields[card] == nil {
                throw ControlError(.badValue, "\(card) has no chart; --range takes \(ControlStats.cardFields.keys.sorted().joined(separator: ", ")) or no card")
            }
            try await app.beat()
            let now = Date()
            var answer = app.cards(today: app.sampler.minutes.points(.today, now: now))
            if let card { answer = answer.filter { $0.key == card } }
            if let range {
                let fields = card.flatMap { ControlStats.cardFields[$0] } ?? ControlStats.fieldNames
                answer["history"] = app.history(range, fields: fields, now: now)
            }
            return .object(answer)
        })
    }
}
