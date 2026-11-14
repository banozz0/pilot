import AppKit
import PilotCore

extension ControlVerbs {
    /// `layout` (layouts round 1, spec Projects/Pilot/specs/layouts-round1.html): the ready layouts and their cycle, and
    /// the tiles a layout gives 1 to n windows on a screen, read from the same tree the tiler builds. Reads only: a
    /// workspace's layout is `pilot add layouts`, its cycle the Cycle layout action and the bar's click.
    func registerLayout(screen: @escaping @MainActor () -> CGSize = { NSScreen.main?.visibleFrame.size ?? CGSize(width: 1440, height: 900) }) {
        let words = LayoutPreset.allCases.map(\.rawValue)
        register(ControlVerb("layout", help: "The ready layouts, which ones Cycle layout and a click on the shown workspace in the top bar go through, "
                             + "and in what order; tiles lists each window's tile, x, y, width and height in points from the top left, for 1 to "
                             + "--windows windows (6) on a screen of --screen (the main display's room), and the order the tiler's tree reads them.",
                             usage: "pilot layout | pilot layout cycle | pilot layout tiles <layout> [--windows <n>] [--screen <width>x<height>]",
                             flags: [.init("windows", help: "the most windows to lay out, 1 to 12 (6)"),
                                     .init("screen", help: "the room the tiles share, as <width>x<height> in points (the main display's)")]) { call throws(ControlError) in
            let args = call.arguments()
            func row(_ preset: LayoutPreset) -> JSONValue {
                .object(["layout": .string(preset.rawValue), "label": .string(preset.label), "inCycle": .bool(LayoutPreset.cycle.contains(preset))])
            }
            switch args.positional.first {
            case nil: return .array(LayoutPreset.allCases.map(row))
            case "cycle":
                // Each layout's next, a workspace with none (and Rows or Columns) starting the cycle.
                let next = ([nil] + LayoutPreset.allCases.map(Optional.some)).map { preset in
                    JSONValue.object(["from": .string(preset?.rawValue ?? "none"), "next": .string(LayoutPreset.next(after: preset).rawValue)])
                }
                return .object(["cycle": .array(LayoutPreset.cycle.map { .string($0.label) }), "next": .array(next)])
            case "tiles":
                let word = try args.word(1, "layout: \(words.joined(separator: ", "))")
                guard let preset = LayoutPreset(rawValue: word) else { throw ControlError(.badValue, "no layout \(word); layouts: \(words.joined(separator: ", "))") }
                let most = try args.value("windows").map { word throws(ControlError) in
                    guard let n = Int(word), (1...12).contains(n) else { throw ControlError(.badValue, "--windows: \(word) is not 1 to 12") }
                    return n
                } ?? 6
                let size = try args.value("screen").map { word throws(ControlError) in
                    let parts = word.split(separator: "x").compactMap { Double($0) }
                    guard parts.count == 2, parts.allSatisfy({ $0 >= 100 }) else { throw ControlError(.badValue, "--screen: \(word) is not <width>x<height>, each 100 or more") }
                    return CGSize(width: parts[0], height: parts[1])
                } ?? screen()
                let area = CGRect(origin: .zero, size: size)
                let counts = (1...most).map { n in
                    let tiles = preset.tiles(n, in: area).map { tile in
                        JSONValue.array([tile.minX, tile.minY, tile.width, tile.height].map { .number(($0 * 10).rounded() / 10) })
                    }
                    let reading = preset.tree(n, in: size)?.reading ?? Array(0..<n)
                    return JSONValue.object(["windows": .number(Double(n)), "tiles": .array(tiles), "reads": .array(reading.map { .number(Double($0 + 1)) })])
                }
                return .object(["layout": .string(preset.rawValue), "label": .string(preset.label),
                                "screen": .string("\(Int(size.width))x\(Int(size.height))"), "counts": .array(counts)])
            case let other?: throw ControlError(.badValue, "no layout \(other) part; pilot layout, pilot layout cycle or pilot layout tiles <layout>")
            }
        })
    }
}
