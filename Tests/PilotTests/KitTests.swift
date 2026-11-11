#if DEBUG
import AppKit
import PilotCore
import SwiftUI
import Testing
@testable import Pilot

/// Design round 4's twelve components (card agent-bo-95422891), section 5 of the approved artifact 5sh21HWjCjsWYAwWKTibcE:
/// each follows the theme and takes its colours from the theme's roles.
/// Drawn offscreen in a window never shown; the theme is previewed on the shared look without saving anything.
extension SharedLook {
@MainActor
@Suite("Component kit")
struct KitTests {
    /// Each sample's drawing per theme, made once for the whole suite.
    static var drawn: [String: [UInt32]] = [:]

    /// The sample drawn on the theme's ground at 2x, as packed device RGB, every 2nd pixel of every 2nd row.
    static func draw(_ sample: KitSample, theme id: String) async throws -> [UInt32] {
        let key = "\(sample)|\(id)"
        if let made = drawn[key] { return made }
        // The other theme is up only within this main-actor turn: a suite drawing alongside never draws on it.
        await Task.yield()
        Look.shared.preview(id)
        defer { Look.shared.preview(PilotTheme.defaultID) }
        let view = sample.demo.padding(14).frame(width: 420)
            .styled(.window).pilotTheme().background(Theme.background)
        let made = Self.pixels(try #require(snapshot(drawing: view)))
        drawn[key] = made
        return made
    }

    /// Round 4's Paper's ground was its raised colour, so a suite drawing while Paper leaked out of a draw counted a pill that was
    /// not there (StripStyleTests' hover, HomePageTests' pixel pairs, on a loaded Mac).
    @Test("A draw on another theme puts Lagoon back before any other main-actor work runs")
    func previewStaysInItsTurn() async throws {
        Self.drawn.removeValue(forKey: "\(KitSample.chip)|workshop")
        let seen = Task { @MainActor in
            var ids: Set<String> = []
            while !Task.isCancelled { ids.insert(Look.shared.theme.id); await Task.yield() }
            return ids
        }
        _ = try await Self.draw(.chip, theme: "workshop")
        seen.cancel()
        #expect(await seen.value == [PilotTheme.defaultID])
    }

    static func pixels(_ rep: NSBitmapImageRep) -> [UInt32] {
        var out: [UInt32] = [], p = [Int](repeating: 0, count: 4)
        out.reserveCapacity(rep.pixelsWide * rep.pixelsHigh / 4)
        for y in stride(from: 0, to: rep.pixelsHigh, by: 2) {
            for x in stride(from: 0, to: rep.pixelsWide, by: 2) {
                rep.getPixel(&p, atX: x, y: y)
                out.append(UInt32(p[0]) << 16 | UInt32(p[1]) << 8 | UInt32(p[2]))
            }
        }
        return out
    }

    /// More than 1 % of the pixels differ, or the sizes do.
    static func differ(_ a: [UInt32], _ b: [UInt32]) -> Bool {
        guard a.count == b.count else { return true }
        var n = 0
        for i in a.indices where a[i] != b[i] { n += 1 }
        return n > a.count / 100
    }

    @Test("Twelve components, as section 5 lists them, then the previews' mini desktop")
    func twelve() {
        #expect(KitSample.allCases.map(\.title) == ["Toggle", "Slider", "Segmented", "List row", "Chip", "Key cap", "Stat tile",
                                                    "Mini graph", "Search field", "Button", "Empty state", "Popover", "Mini desktop"])
    }

    @Test("Each component follows the theme", arguments: KitSample.allCases)
    func followsTheme(_ sample: KitSample) async throws {
        let night = try await Self.draw(sample, theme: "lagoon"), paper = try await Self.draw(sample, theme: "workshop")
        #expect(Self.differ(night, paper), "\(sample.title) ignores the theme")
    }

    /// Every solid colour a component fills an area with is a theme role, or a role laid over the ground at some strength
    /// (selection, soft fills), or the white of Calm's thumbs: no colour of its own.
    @Test("Each component's colours come from the theme", arguments: KitSample.allCases)
    func colours(_ sample: KitSample) async throws {
        for id in ["dusk", "phosphor"] { try await coloursCome(from: id, sample) }
    }

    private func coloursCome(from id: String, _ sample: KitSample) async throws {
        let t = try #require(PilotTheme.named(id))
        let roles = [t.ground, t.sidebar, t.surface, t.raised, t.line, t.line2, t.text, t.text2, t.text3, t.accent, t.second,
                     t.third, t.good, t.amber, t.problem, t.keyFill, t.onAccent, 0xFFFFFF, 0x000000] + t.graphs
        let ground = Contrast.rgb(t.ground)
        let rep = try await Self.draw(sample, theme: id)
        var counts: [UInt32: Int] = [:]
        for p in rep { counts[p, default: 0] += 1 }
        let total = counts.values.reduce(0, +)
        for (colour, n) in counts where n * 200 > total {
            let c = Contrast.rgb(colour)
            let explained = roles.contains { role in
                let r = Contrast.rgb(role)
                // Over the ground, the surface a component sits on, or the accent (a lit focus edge).
                return [ground, Contrast.rgb(t.surface), Contrast.rgb(t.raised), Contrast.rgb(t.accent)].contains { base in
                    let d = zip(r, base).map { $0 - $1 }, v = zip(c, base).map { $0 - $1 }
                    let dd = d.reduce(0) { $0 + $1 * $1 }
                    let a = dd == 0 ? 0 : max(0, min(1, zip(d, v).reduce(0) { $0 + $1.0 * $1.1 } / dd))
                    return zip(c, zip(r, base)).allSatisfy { abs($0 - ($1.0 * a + $1.1 * (1 - a))) < 7 }
                }
            }
            #expect(explained, "\(sample.title) fills \(colour) (\(n) of \(total)), no role of \(id)'s")
        }
    }

    @Test("A chip says its colour: green and red chips differ, a plain one is neither")
    func chipColours() async throws {
        Look.shared.preview(PilotTheme.defaultID)
        // Toybox's chips carry a colour; Instrument's have none (one signal colour).
        let toybox = StyleTokens.of(.toybox, theme: Look.shared.theme)
        let draw = { (chip: Chip) in Self.pixels(try #require(try await snapshot(rendering: chip.padding(4).style(toybox)))) }
        let green = try await draw(Chip(text: "running", color: Theme.green)), red = try await draw(Chip(text: "running", color: Theme.red))
        let plain = try await draw(Chip(text: "running"))
        #expect(Self.differ(green, red) && Self.differ(green, plain) && Self.differ(red, plain))
    }

    @Test("The nine focus borders draw nine ways in Toybox (Instrument's focus is its ring alone)")
    func focusBorders() async throws {
        var drawn: [[UInt32]] = []
        let toybox = StyleTokens.of(.toybox, theme: Look.shared.theme)
        for border in FocusBorder.allCases {
            let view = RoundedRectangle(cornerRadius: 8).fill(Color(hex: 0x1F2335)).frame(width: 120, height: 60)
                .focusBorder(border, on: true, radius: 8).padding(12).background(Color(hex: 0x1A1B26)).style(toybox)
            drawn.append(Self.pixels(try #require(try await snapshot(rendering: view))))
        }
        for i in drawn.indices { for j in drawn.indices where j > i {
            #expect(Self.differ(drawn[i], drawn[j]), "\(FocusBorder.allCases[i]) and \(FocusBorder.allCases[j]) look the same")
        } }
    }
}
}
#endif
