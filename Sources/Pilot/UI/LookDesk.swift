import AppKit
import SwiftUI

/// Look's preview: a desk in the theme as it looks in use, scaled down from Sven's own desktop (pick A of the
/// look-preview-design round on build 2300, 2026-11-11, and his two tweaks: room round the panes, then "make it look
/// real": his Zed, his system-info block and his Obsidian graph). Three windows, main and stack, with the tiler's gaps on
/// the wallpaper: Zed on a Markdown file with its project tree, breadcrumb and soft-wrapped lines; a terminal with a
/// system-info block beside a HYPER keycap; and Obsidian's graph of a few hundred notes in coloured clusters beside its
/// folders. Every colour is one of the theme's roles and everything is fixed (the graph from a seeded generator), so it
/// draws once and never ticks. The apps keep the theme's background, so Glass, which is Pilot's own windows', does not
/// show here.
struct LookDesk: View {
    @Environment(\.ink) private var ink
    let look: Look
    let picture: Image?

    var body: some View {
        GeometryReader { g in
            let f = Self.font(g.size)
            let layout = Layout(g.size)
            let radius = ink.radius(6)
            ZStack(alignment: .topLeading) {
                window(.editor, layout.editor, f: f, radius: radius)
                window(.terminal, layout.terminal, f: f, radius: radius)
                window(.graph, layout.graph, f: f, radius: radius)
            }
        }
        .background { MiniDesktop(windows: [], wallpaper: picture) }
    }

    private enum App { case editor, terminal, graph }

    private func window(_ app: App, _ rect: CGRect, f: CGFloat, radius: CGFloat) -> some View {
        let c = look.colors, shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
        return VStack(spacing: 0) {
            switch app {
            case .editor: DeskEditor(colors: c, f: f, size: rect.size)
            case .terminal: DeskTerminal(colors: c, f: f)
            case .graph: DeskGraph(colors: c, f: f, size: rect.size)
            }
        }
        // Pinned to its window, so anything longer runs off its foot or its right edge, as in a real one.
        .frame(width: rect.width, height: rect.height, alignment: .topLeading)
        .background(c.ground)
        .clipShape(shape)
        .overlay { shape.strokeBorder(app == .editor ? c.accent : c.line2, lineWidth: app == .editor ? 1.25 : 0.75) }
        .shadow(color: .black.opacity(0.25), radius: 6, y: 2)
        .offset(x: rect.minX, y: rect.minY)
    }

    /// The text size for the preview's height: 5.5 pt in Look's row at 1000 by 660 (257 pt tall), 7.5 pt at 344 pt.
    static func font(_ size: CGSize) -> CGFloat { min(9, max(5, (size.height / 46 * 2).rounded() / 2)) }

    /// The editor as the main window and the terminal over Obsidian beside it, with gaps wide enough that the wallpaper
    /// reads round and between them, measured by the shorter side so a wide preview keeps its height for the windows.
    private struct Layout {
        let editor, terminal, graph: CGRect

        init(_ size: CGSize) {
            let side = min(size.width, size.height * 1.4)
            let outer = max(10, (side * 0.04).rounded()), gap = max(8, (side * 0.028).rounded())
            let area = CGRect(origin: .zero, size: size).insetBy(dx: outer, dy: outer)
            let main = ((area.width - gap) * 0.52).rounded(), right = area.minX + main + gap
            let top = ((area.height - gap) * 0.52).rounded()
            editor = CGRect(x: area.minX, y: area.minY, width: main, height: area.height)
            terminal = CGRect(x: right, y: area.minY, width: area.maxX - right, height: top)
            graph = CGRect(x: right, y: area.minY + top + gap, width: area.maxX - right, height: area.height - top - gap)
        }
    }
}

/// Text in runs of colour; `link` runs underlined.
private func runs(_ parts: [(String, Color)], link: Color? = nil) -> AttributedString {
    parts.reduce(into: AttributedString()) { line, run in
        var part = AttributedString(run.0)
        part.foregroundColor = run.1
        if let link, run.1 == link { part.underlineStyle = .single }
        line += part
    }
}

/// One line of fixed text that never wraps or ends in an ellipsis: a window too narrow cuts it at its edge.
private struct Line: View {
    let text: AttributedString
    init(_ parts: [(String, Color)]) { text = runs(parts) }

    // The hidden copy takes the width offered and the line's height; the drawn one keeps its length past the edge.
    var body: some View {
        Text(text).lineLimit(1).hidden().frame(maxWidth: .infinity, alignment: .leading)
            .overlay(alignment: .leading) { Text(text).fixedSize() }
    }
}

/// A window's title bar: its three lights, lit on the focused window, and its title.
private struct TitleBar<Trailing: View>: View {
    @Environment(\.ink) private var ink
    let colors: ThemeColors
    let f: CGFloat
    let focused: Bool
    let title: [(String, Color)]
    @ViewBuilder var trailing: Trailing

    var body: some View {
        let c = colors
        HStack(spacing: f * 0.45) {
            ForEach(Array((focused ? [c.problem, c.amber, c.good] : [c.line2, c.line2, c.line2]).enumerated()), id: \.offset) {
                Circle().fill($0.element).frame(width: f * 0.75, height: f * 0.75)
            }
            Text(runs(title)).font(ink.ui(f * 0.95, .medium)).lineLimit(1).fixedSize().padding(.leading, f * 0.6)
            Spacer(minLength: 0)
            trailing
        }
        .padding(.horizontal, f * 0.9)
        .frame(height: (f * 2.2).rounded())
        .background(c.sidebar)
        .overlay(alignment: .bottom) { c.line.frame(height: 0.5) }
    }
}

// MARK: - Zed

/// Zed on the repository's agent brief: the project tree with the file open, its tab and breadcrumb, Markdown in the
/// theme's syntax colours wrapped at the window's edge under its line numbers, and the status bar.
private struct DeskEditor: View {
    @Environment(\.ink) private var ink
    let colors: ThemeColors
    let f: CGFloat
    let size: CGSize

    var body: some View {
        let c = colors
        VStack(spacing: 0) {
            TitleBar(colors: c, f: f, focused: true, title: [("pilot", c.text), ("   main", c.text3)]) { EmptyView() }
            HStack(alignment: .top, spacing: 0) {
                // The tree only where the text keeps about 30 characters beside it.
                if size.width >= f * 26 {
                    tree.frame(width: (f * 9).rounded(), alignment: .leading).frame(maxHeight: .infinity, alignment: .top).background(c.sidebar)
                        .overlay(alignment: .trailing) { c.line.frame(width: 0.5) }
                }
                VStack(spacing: 0) {
                    tab
                    Line([("AGENTS.md", c.text3), (" › ", c.text3), ("# pilot — agent brief", c.text3)])
                        .font(ink.mono(f * 0.9)).padding(.horizontal, f).frame(height: f * 1.8)
                    // Over a clear ground that takes the space left, so the text's full height never pushes the status bar off.
                    Color.clear.overlay(alignment: .topLeading) { text }.clipped()
                }
            }
            HStack(spacing: f * 0.9) {
                ForEach(0..<4, id: \.self) { _ in RoundedRectangle(cornerRadius: f * 0.12).strokeBorder(c.text3, lineWidth: 0.6).frame(width: f * 0.8, height: f * 0.8) }
                Spacer(minLength: 0)
                Text("12:1").foregroundStyle(c.text3)
                Text("Markdown").foregroundStyle(c.text3)
            }
            .font(ink.mono(f * 0.85)).lineLimit(1)
            .padding(.horizontal, f * 0.9).frame(height: (f * 1.8).rounded()).background(c.sidebar)
            .overlay(alignment: .top) { c.line.frame(height: 0.5) }
        }
        .font(ink.mono(f)).lineLimit(1)
    }

    private var tab: some View {
        let c = colors
        return HStack(spacing: 0) {
            Text("‹  ›").foregroundStyle(c.text3).padding(.horizontal, f * 0.8)
            Text("AGENTS.md").foregroundStyle(c.text).padding(.horizontal, f * 1.1).frame(maxHeight: .infinity).background(c.ground)
                .overlay(alignment: .leading) { c.line.frame(width: 0.5) }.overlay(alignment: .trailing) { c.line.frame(width: 0.5) }
            Spacer(minLength: 0)
        }
        .font(ink.mono(f * 0.9))
        .frame(height: (f * 2).rounded()).background(c.sidebar)
        .overlay(alignment: .bottom) { c.line.frame(height: 0.5) }
    }

    /// The repository's top level as Zed lists it: folders first, then files, the open one picked.
    private var tree: some View {
        let c = colors
        let folders = [".build", ".github", "build", "Helpers", "Packaging", "Scripts", "site", "Sources", "Tests"]
        let files: [(String, Color)] = [(".gitignore", c.problem), ("AGENTS.md", c.second), ("CONTRIBUTING.md", c.second),
                                        ("GLOSSARY.md", c.second), ("LICENSE", c.amber), ("Package.swift", c.amber),
                                        ("README.md", c.second)]
        return VStack(alignment: .leading, spacing: f * 0.42) {
            row("pilot", icon: nil, colour: c.text2, depth: 0)
            ForEach(folders, id: \.self) { row($0, icon: c.text3, colour: c.text3, depth: 1, folder: true) }
            ForEach(files, id: \.0) { name, tint in
                row(name, icon: tint, colour: name == "AGENTS.md" ? c.text : c.text3, depth: 1)
                    .background { if name == "AGENTS.md" { c.selection } }
            }
        }
        .font(ink.mono(f * 0.82)).padding(.top, f * 0.7).clipped()
    }

    private func row(_ name: String, icon: Color?, colour: Color, depth: Int, folder: Bool = false) -> some View {
        HStack(spacing: f * 0.45) {
            if let icon {
                if folder {
                    RoundedRectangle(cornerRadius: f * 0.12).strokeBorder(icon, lineWidth: 0.6).frame(width: f * 0.85, height: f * 0.65)
                } else {
                    RoundedRectangle(cornerRadius: f * 0.12).fill(icon).frame(width: f * 0.65, height: f * 0.8)
                }
            }
            Text(name).foregroundStyle(colour).fixedSize()
        }
        .padding(.leading, f * (0.9 + Double(depth) * 0.6))
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// The brief's opening, wrapped at the window's edge as Zed's soft wrap does, each line under its number.
    private var text: some View {
        let c = colors
        let head = c.accent, code = c.good, link = c.second, list = c.third, plain = c.text, mark = c.text3
        let lines: [[(String, Color)]] = [
            [("# ", mark), ("pilot — agent brief", head)],
            [],
            [("Written to be public: ", plain), ("banozz0/pilot", link), (" carries this file, so nothing private goes in it. Pilot makes a Mac feel like ", plain), ("Omarchy", link), (": one native Swift/AppKit menu-bar app (macOS 27+) owning the Hyper key, every bind, tiling and workspaces (", plain), ("`Sources/PilotTiler`", code), ("), the launcher, web apps, clipboard and Quick AI.", plain)],
            [],
            [("## ", mark), ("Commands", head)],
            [("- ", list), ("`swift build`", code), (" and ", plain), ("`swift test`", code), (", at most 4 jobs (", plain), ("`-j 4`", code), ("). Opt-in tests are env-gated: ", plain), ("`PILOT_LIVE=1`", code), (", ", plain), ("`PILOT_FOCUS=1`", code), (".", plain)],
            [("- ", list), ("Prove behaviour end to end through the ", plain), ("`pilot`", code), (" command against a sandbox, output quoted.", plain)],
            [("- ", list), ("`Scripts/build-app.sh`", code), (" (release, signed, checks the size budget) once per change, before land.", plain)],
            [],
            [("## ", mark), ("Shape and rules", head)],
            [("- ", list), ("A HID-level CGEventTap makes the layer key Hyper and runs every bind in-process (", plain), ("ADR 0001", link), (").", plain)],
            [("- ", list), ("Binds: ", plain), ("`~/Library/Application Support/Pilot/binds.json`", code), (", schema 1.", plain)],
            [("- ", list), ("Tiling is Pilot's tiler alone; ", plain), ("`~/.aerospace.toml`", code), (" is an import, never written.", plain)],
            [("- ", list), ("System Events is the one automation target; run AppleScript in a child ", plain), ("`osascript`", code), (".", plain)],
            [("- ", list), ("Stay lean inside ", plain), ("`Scripts/lean-budgets.json`", code), ("; a budget rises only on a yes.", plain)],
            [],
            [("## ", mark), ("Extensions", head)],
            [("ADR 0010", link), (" is the contract: extensions speak JSON lines, Pilot draws.", plain)],
        ]
        // Smaller than the chrome's text, as dense as Zed's buffer beside its tree.
        let t = f * 0.86
        return VStack(alignment: .leading, spacing: f * 0.3) {
            ForEach(lines.indices, id: \.self) { i in
                HStack(alignment: .firstTextBaseline, spacing: f * 1.1) {
                    Text("\(i + 1)").font(ink.mono(t)).foregroundStyle(i == 0 ? c.text : c.text3).fixedSize().frame(width: f * 1.4, alignment: .trailing)
                    // A heading by its own weight of the mono face: fontWeight on a custom font falls back to the system's.
                    Text(lines[i].isEmpty ? AttributedString(" ") : runs(lines[i], link: link)).font(ink.mono(t, weight: lines[i].first?.0.hasPrefix("#") == true ? .semibold : .regular))
                        .lineLimit(nil).fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
        .padding(.top, f * 0.4).padding(.trailing, f * 0.8)
        // Its whole height, wrapped lines and all; the window cuts it at its foot.
        .fixedSize(horizontal: false, vertical: true)
    }
}

// MARK: - Terminal

/// A terminal after a system-info command: a HYPER keycap in box-drawing characters beside the Mac's details under
/// `you@studio` and a dashed rule, three usage bars under the keycap, and the theme's colours in a strip.
private struct DeskTerminal: View {
    @Environment(\.ink) private var ink
    let colors: ThemeColors
    let f: CGFloat

    var body: some View {
        let c = colors
        let rows = [("OS", "macOS 27.2 arm64"), ("HOST", "Mac mini"), ("KERNEL", "Darwin 27.2.0"), ("CPU", "Apple M4 · 10 cores"),
                    ("GPU", "Apple M4 · 10 cores"), ("MEMORY", "17.5 / 24.0 GiB"), ("DISK", "459 / 494 GB"), ("SHELL", "zsh 5.9"),
                    ("PKGS", "214 (brew)"), ("UPTIME", "8d 3h")]
        let line = f * 1.22
        VStack(spacing: 0) {
            TitleBar(colors: c, f: f, focused: false, title: [("~", c.text3)]) { EmptyView() }
            HStack(alignment: .top, spacing: f * 1.0) {
                VStack(alignment: .leading, spacing: 0) {
                    keycap.padding(.top, f * 0.2)
                    Spacer(minLength: f * 0.6)
                    VStack(alignment: .leading, spacing: f * 0.5) {
                        bar("CPU", 0.42, c.text2)
                        bar("MEM", 0.73, c.text2)
                        bar("DISK", 0.93, c.problem)
                    }
                }
                .fixedSize(horizontal: true, vertical: false)
                VStack(alignment: .leading, spacing: 0) {
                    Line([("you", c.text), ("@", c.text3), ("studio", c.text)]).font(ink.mono(f * 0.92, weight: .semibold)).frame(height: line)
                    Line([(String(repeating: "-", count: 60), c.text3)]).frame(height: line * 0.8)
                    ForEach(rows, id: \.0) { key, value in
                        HStack(spacing: 0) {
                            Text(key).foregroundStyle(c.text3).frame(width: f * 4.0, alignment: .leading)
                            Line([(value, c.text)])
                        }
                        .frame(height: line)
                    }
                    Spacer(minLength: f * 0.6)
                    HStack(spacing: 0) {
                        ForEach(Array([c.text3, c.problem, c.good, c.amber, c.accent, c.second, c.third, c.text].enumerated()), id: \.offset) {
                            Rectangle().fill($0.element)
                        }
                    }
                    .frame(height: f * 0.9)
                }
            }
            .font(ink.mono(f * 0.92)).lineLimit(1)
            .padding(.horizontal, f * 0.9).padding(.top, f * 0.8).padding(.bottom, f * 1.1)
        }
    }

    /// The Hyper key as a keycap: its back edges faint, its face in the accent, the legend in green and a bar under it.
    private var keycap: some View {
        let c = colors, edge = c.text3, face = c.accent
        let lines: [[(String, Color)]] = [
            [("  .---------.", edge)],
            [(" /         /", edge), ("|", edge)],
            [("+---------+", face), (" |", edge)],
            [("|", face), ("  HYPER  ", c.good), ("|", face), (" |", edge)],
            [("|", face), ("   ---   ", c.problem), ("|", face), (" +", c.problem)],
            [("|", face), ("         ", c.text), ("|", face), ("/", edge)],
            [("+---------+", face)],
        ]
        return VStack(alignment: .leading, spacing: 0) {
            ForEach(lines.indices, id: \.self) { Text(runs(lines[$0])).fixedSize().frame(height: f * 1.1) }
        }
    }

    private func bar(_ name: String, _ share: Double, _ colour: Color) -> some View {
        HStack(spacing: f * 0.6) {
            Text(name).foregroundStyle(colors.text3).frame(width: f * 2.4, alignment: .leading)
            Capsule().fill(colors.line)
                .overlay(alignment: .leading) { Capsule().fill(colour).frame(width: f * 4.6 * share) }
                .frame(width: f * 4.6, height: max(1.5, f * 0.32))
            Text("\(Int(share * 100))%").foregroundStyle(colors.text3)
        }
        .font(ink.mono(f * 0.8))
    }
}

// MARK: - Obsidian

/// Obsidian's graph view: the ribbon, the vault's folders, and a few hundred notes in coloured clusters joined by thin
/// links round a few bigger hubs.
private struct DeskGraph: View {
    @Environment(\.ink) private var ink
    let colors: ThemeColors
    let f: CGFloat
    let size: CGSize

    var body: some View {
        let c = colors
        VStack(spacing: 0) {
            TitleBar(colors: c, f: f, focused: false, title: [("Graph view", c.text2)]) { EmptyView() }
            HStack(spacing: 0) {
                VStack(spacing: f * 0.9) {
                    ForEach(0..<5, id: \.self) { _ in RoundedRectangle(cornerRadius: f * 0.12).strokeBorder(c.text3, lineWidth: 0.6).frame(width: f * 0.8, height: f * 0.8) }
                }
                .padding(.top, f).frame(width: f * 2.2).frame(maxHeight: .infinity, alignment: .top).background(c.sidebar)
                .overlay(alignment: .trailing) { c.line.frame(width: 0.5) }
                // The folders only where the graph keeps most of the window.
                if size.width >= f * 24 { folders.frame(width: (f * 9).rounded(), alignment: .leading).frame(maxHeight: .infinity, alignment: .top)
                    .background(c.sidebar).overlay(alignment: .trailing) { c.line.frame(width: 0.5) } }
                graph.frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }

    private var folders: some View {
        let c = colors
        let rows: [(String, Color)] = [("Projects", c.problem), ("Knowledge", c.third), ("Memory", c.second), ("Research", c.amber),
                                       ("Workflows", c.accent), ("Content", c.amber), ("Notes", c.good), ("Templates", c.third), ("Archive", c.text3)]
        return VStack(alignment: .leading, spacing: f * 0.5) {
            Text("Vault").foregroundStyle(c.text3).padding(.bottom, f * 0.2)
            ForEach(rows, id: \.0) { name, tint in
                HStack(spacing: f * 0.45) {
                    Text("›").foregroundStyle(c.text3)
                    RoundedRectangle(cornerRadius: f * 0.15).fill(tint).frame(width: f * 0.75, height: f * 0.75)
                    Text(name).foregroundStyle(c.text2).fixedSize()
                }
            }
        }
        .font(ink.ui(f * 0.9)).lineLimit(1).padding(.leading, f * 0.7).padding(.top, f * 0.8).clipped()
    }

    private var graph: some View {
        let c = colors
        let tints = [c.text3, c.accent, c.third, c.good, c.amber, c.problem, c.second]
        return Canvas { context, area in
            let box = CGRect(origin: .zero, size: area).insetBy(dx: area.width * 0.05, dy: area.height * 0.06)
            let at = { (p: CGPoint) in CGPoint(x: box.minX + box.width * p.x, y: box.minY + box.height * p.y) }
            var links = Path()
            for (a, b) in Notes.shared.links { links.move(to: at(Notes.shared.dots[a].place)); links.addLine(to: at(Notes.shared.dots[b].place)) }
            context.stroke(links, with: .color(c.line2.opacity(0.55)), lineWidth: 0.3)
            for dot in Notes.shared.dots {
                let r = f * (dot.hub ? 0.55 : 0.17)
                let p = at(dot.place)
                context.fill(Path(ellipseIn: CGRect(x: p.x - r, y: p.y - r, width: r * 2, height: r * 2)), with: .color(tints[dot.group]))
            }
        }
    }

    /// The notes and links, made once from a fixed seed: clusters round hubs (one big one in the middle), loose grey notes
    /// round them all.
    struct Notes {
        struct Dot { let place: CGPoint; let group: Int; let hub: Bool }
        let dots: [Dot]
        let links: [(Int, Int)]

        static let shared = Notes()

        private init() {
            var seed: UInt64 = 0x5EED_1A60_0D15_C0DE
            func next() -> CGFloat {
                seed = seed &* 6364136223846793005 &+ 1442695040888963407
                return CGFloat(seed >> 11) / CGFloat(1 << 53)
            }
            // Centre, group, notes, spread.
            let clusters: [(CGFloat, CGFloat, Int, Int, CGFloat)] = [
                (0.46, 0.55, 1, 110, 0.15), (0.3, 0.2, 4, 46, 0.07), (0.12, 0.14, 5, 14, 0.03), (0.6, 0.62, 3, 26, 0.045),
                (0.9, 0.52, 4, 30, 0.035), (0.68, 0.32, 2, 54, 0.13), (0.32, 0.78, 4, 40, 0.09), (0.18, 0.62, 6, 22, 0.05),
                (0.55, 0.48, 0, 70, 0.3),
            ]
            var dots: [Dot] = [], links: [(Int, Int)] = [], hubs: [Int] = []
            for (cx, cy, group, count, spread) in clusters {
                let hub = dots.count
                hubs.append(hub)
                dots.append(Dot(place: CGPoint(x: cx, y: cy), group: group == 0 ? 1 : group, hub: group != 0))
                for _ in 1..<count {
                    // Two uniforms summed lean to the middle, as a cluster does.
                    let x = cx + (next() + next() - 1) * spread * 1.6, y = cy + (next() + next() - 1) * spread * 1.6
                    let index = dots.count
                    dots.append(Dot(place: CGPoint(x: min(1, max(0, x)), y: min(1, max(0, y))), group: group, hub: false))
                    if next() < 0.7 { links.append((index, hub)) }
                    if next() < 0.5 { links.append((index, Int(next() * CGFloat(index)))) }
                }
            }
            for hub in hubs.dropFirst() { links.append((hub, hubs[0])) }
            self.dots = dots
            self.links = links
        }
    }
}
