import AppKit
import PilotCore
import PilotTiler

extension ControlVerbs {
    /// `layout` (layouts round 1, spec Projects/Pilot/specs/layouts-round1.html): the ready layouts and their cycle, and
    /// the tiles a layout gives 1 to n windows on a screen, read from the same tree the tiler builds. Reads only: a
    /// workspace's layout is `pilot add layouts`, its cycle the Cycle layout action and the bar's click.
    func registerLayout() {
        register(ControlVerb("layout", help: "The ready layouts, which ones Cycle layout and a click on the shown workspace in the top bar go through, "
                             + "and in what order; tiles lists each window's tile, x, y, width and height in points from the top left, for 1 to "
                             + "--windows windows (6) on a screen of --screen (the main display's room), and the order the tiler's tree reads them. "
                             + "Scrolling's are the strip's frames at --strip's look, scrolled to show --focus (the newest); a column scrolled off "
                             + "lies past the screen's edge. --gap and --min lay them as the tiler does: the inner gap between tiles, and a "
                             + "window that cannot shrink below its least size given it, the tiles beside it giving way.",
                             usage: "pilot layout | pilot layout cycle | pilot layout tiles <layout> [--windows <n>] [--screen <width>x<height>] [--strip thirds|centred|halves] [--focus <n>] [--gap <points>] [--min <window>=<width>x<height>[,…]]",
                             flags: [.init("windows", help: "the most windows to lay out, 1 to 12 (6)"),
                                     .init("screen", help: "the room the tiles share, as <width>x<height> in points (the main display's)"),
                                     .init("strip", help: "scrolling's look, \(Self.cases(PilotBlock.StripLook.self)) (halves, the default)"),
                                     .init("focus", help: "scrolling's focused column, 1 first (the newest)"),
                                     .init("gap", help: "the inner gap between tiles, in points (0)"),
                                     .init("min", help: "windows' least sizes, as <window>=<width>x<height>, comma-separated, window 1 first in open order")]) { call throws(ControlError) in
            let args = call.arguments()
            func row(_ preset: LayoutPreset) -> JSONValue {
                .object(["layout": .string(preset.rawValue), "label": .string(preset.label), "inCycle": .bool(LayoutPreset.cycle.contains(preset))])
            }
            switch args.positional.first {
            case nil: return .array(LayoutPreset.allCases.map(row))
            case "cycle":
                // Each layout's next, a workspace with none (and Rows) starting the cycle.
                let next = ([nil] + LayoutPreset.allCases.map(Optional.some)).map { preset in
                    JSONValue.object(["from": .string(preset?.rawValue ?? "none"), "next": .string(LayoutPreset.next(after: preset).rawValue)])
                }
                return .object(["cycle": .array(LayoutPreset.cycle.map { .string($0.label) }), "next": .array(next)])
            case "tiles":
                let preset: LayoutPreset = try Self.choice(try args.word(1, "layout: \(Self.cases(LayoutPreset.self))"), "layout")
                let most = try args.value("windows").map { word throws(ControlError) in
                    guard let n = Int(word), (1...12).contains(n) else { throw ControlError(.badValue, "--windows: \(word) is not 1 to 12") }
                    return n
                } ?? 6
                let size = try args.value("screen").map { word throws(ControlError) in try Self.size(word, "--screen", least: 100) }
                    ?? NSScreen.main?.visibleFrame.size ?? CGSize(width: 1440, height: 900)
                let area = CGRect(origin: .zero, size: size)
                let strip: PilotBlock.StripLook = try args.value("strip").map { word throws(ControlError) in try Self.choice(word, "--strip") } ?? .halves
                let focus = try args.value("focus").map { word throws(ControlError) in
                    guard let n = Int(word), n >= 1 else { throw ControlError(.badValue, "--focus: \(word) is not a column, 1 first") }
                    return n - 1
                }
                let gap: CGFloat = try args.value("gap").map { word throws(ControlError) -> CGFloat in
                    guard let points = Double(word), (0...100).contains(points) else { throw ControlError(.badValue, "--gap: \(word) is not 0 to 100 points") }
                    return CGFloat(points)
                } ?? 0
                var minimums: [Int: CGSize] = [:]
                for entry in (args.value("min") ?? "").split(separator: ",") {
                    let sides = entry.split(separator: "=")
                    guard sides.count == 2, let window = Int(sides[0]), window >= 1 else {
                        throw ControlError(.badValue, "--min: \(entry) is not <window>=<width>x<height>")
                    }
                    minimums[window - 1] = try Self.size(String(sides[1]), "--min", least: 0)
                }
                let counts = (1...most).map { n in
                    let tiles = (preset == .scrolling ? StripPreview.frames(n, look: strip, focus: focus, in: size) : preset.frames(n, in: area, gap: gap, minimums: minimums)).map { tile in
                        JSONValue.array([tile.minX, tile.minY, tile.width, tile.height].map { .number(($0 * 10).rounded() / 10) })
                    }
                    let reading = preset.reading(of: Array(0..<n), in: size)
                    return JSONValue.object(["windows": .number(Double(n)), "tiles": .array(tiles), "reads": .array(reading.map { .number(Double($0 + 1)) })])
                }
                var answer: [String: JSONValue] = ["layout": .string(preset.rawValue), "label": .string(preset.label),
                                                   "screen": .string("\(Int(size.width))x\(Int(size.height))"), "counts": .array(counts)]
                if preset == .scrolling { answer["strip"] = .string(strip.rawValue) }
                return .object(answer)
            case let other?: throw ControlError(.badValue, "no layout \(other) part; pilot layout, pilot layout cycle or pilot layout tiles <layout>")
            }
        })
    }

    /// A `<width>x<height>` value of `flag`, each side `least` or more.
    private static func size(_ word: String, _ flag: String, least: Double) throws(ControlError) -> CGSize {
        let parts = word.split(separator: "x").compactMap { Double($0) }
        guard parts.count == 2, parts.allSatisfy({ $0 >= least }) else {
            throw ControlError(.badValue, "\(flag): \(word) is not <width>x<height>, each \(Int(least)) or more")
        }
        return CGSize(width: parts[0], height: parts[1])
    }
}
