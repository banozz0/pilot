#if DEBUG
import PilotCore
import SwiftUI

/// The kit's gallery (card agent-bo-95422891), debug builds only: the twelve components of the approved artifact's
/// section 5, each with the sample the artifact draws. The renders and the kit's tests draw from it.
enum KitSample: String, CaseIterable, CustomStringConvertible {
    case toggle, slider, segmented, row, chip, keyCap, stat, graph, search, button, empty, popover

    var description: String { title }

    var title: String {
        switch self {
        case .toggle: "Toggle"
        case .slider: "Slider"
        case .segmented: "Segmented"
        case .row: "List row"
        case .chip: "Chip"
        case .keyCap: "Key cap"
        case .stat: "Stat tile"
        case .graph: "Mini graph"
        case .search: "Search field"
        case .button: "Button"
        case .empty: "Empty state"
        case .popover: "Popover"
        }
    }

    /// What it is used for, as the artifact's first column says.
    var use: String {
        switch self {
        case .toggle: "on / off"
        case .slider: "strength, gaps"
        case .segmented: "one of a few"
        case .row: "menu, clipboard"
        case .chip: "counts, filters"
        case .keyCap: "binds, hints"
        case .stat: "This Mac"
        case .graph: "readings"
        case .search: "menu, clipboard"
        case .button: "actions"
        case .empty: "nothing yet"
        case .popover: "menu-bar items"
        }
    }

    static let cpu: [Double] = [12, 18, 14, 22, 30, 26, 19, 23, 35, 28, 21, 17, 24, 31, 27, 22, 19, 25, 33, 29, 23, 20, 26, 23]

    @MainActor @ViewBuilder var demo: some View {
        switch self {
        case .toggle: SampleToggles()
        case .slider: SampleSlider()
        case .segmented: SampleSegments()
        case .row: SampleRows()
        case .chip: SampleChips()
        case .keyCap: SampleKeys()
        case .stat: SampleStats()
        case .graph: SampleGraph()
        case .search: SampleSearch()
        case .button: SampleButtons()
        case .empty: SampleEmpty()
        case .popover: SamplePopover().floating()
        }
    }
}

private struct SampleToggles: View {
    @State private var on = true
    var body: some View {
        HStack(spacing: 10) {
            Toggle("On", isOn: $on).toggleStyle(.pilotSwitch)
            Toggle("Off", isOn: Binding(get: { !on }, set: { on = !$0 })).toggleStyle(.pilotSwitch)
        }
    }
}

private struct SampleSlider: View {
    @State private var value = 0.6
    var body: some View {
        HStack(spacing: 10) {
            KitSlider(value: $value, label: "Strength")
            Text("\(Int(value * 100))%").font(Theme.mono(11.5)).foregroundStyle(Theme.text2)
        }
    }
}

private struct SampleSegments: View {
    @State private var picked = 0
    var body: some View {
        Segments(selection: $picked, options: [(0, "Solid"), (1, "Tinted"), (2, "Glass")], label: "Material")
    }
}

/// An app's icon as the artifact draws it: a rounded square in its colour with its letter.
struct SampleAppIcon: View {
    let letter: String
    let colour: Color
    var size: CGFloat = 20
    var body: some View {
        Text(letter).font(.system(size: size * 0.48, weight: .bold)).foregroundStyle(.white)
            .frame(width: size, height: size)
            .background(colour.gradient, in: .rect(cornerRadius: size * 0.27))
    }
}

private struct SampleRows: View {
    var body: some View {
        VStack(spacing: 0) {
            KitRow(selected: true) {
                SampleAppIcon(letter: "G", colour: Theme.selected, size: 24); Text("Ghostty").fontWeight(.semibold); Spacer()
                Text("Workspace 1").font(.system(size: 12)).opacity(0.72)
            }
            KitRow { Squircle(symbol: "square.grid.2x2", colour: Theme.third); Text("Go to workspace 2") }
        }
    }
}

private struct SampleChips: View {
    var body: some View {
        HStack(spacing: 8) {
            Chip(text: "CPU", color: Theme.graph(0))
            Chip(text: "1 conflict", color: Theme.yellow)
            Chip(text: "Storage")
        }
    }
}

private struct SampleKeys: View {
    var body: some View {
        HStack(spacing: 10) {
            Kbd(text: "Hyper")
            Kbd(text: "Space")
            BoardKey(legend: "B", colour: Theme.module(0), state: .picked).frame(width: 46)
            BoardKey(legend: "Y", state: .free).frame(width: 46)
        }
    }
}

private struct SampleStats: View {
    var body: some View {
        // In the block it lives in, focused, so the theme's focus border shows too.
        Tile(title: "This Mac", symbol: "cpu", focused: true) {
            HStack(spacing: 18) {
                StatReading(label: "CPU", value: "23", fraction: 0.23, colour: Theme.graph(0))
                StatReading(label: "Memory", value: "61", fraction: 0.61, colour: Theme.graph(1))
                StatReading(label: "Network", value: "2.1", fraction: 0.42, colour: Theme.graph(2))
            }
        }
    }
}

private struct SampleGraph: View {
    var body: some View {
        MiniGraph(values: KitSample.cpu, colour: Theme.graph(0)).frame(width: 220, height: 40)
    }
}

private struct SampleSearch: View {
    @State private var text = ""
    var body: some View {
        SearchBox(prompt: "Find a setting…", text: $text)
    }
}

private struct SampleButtons: View {
    var body: some View {
        HStack(spacing: 8) {
            Button("Change key") {}.buttonStyle(.pilotPrimary)
            Button("Copy") {}.buttonStyle(.pilotSoft)
            Button("Remove") {}.buttonStyle(.pilot)
        }
    }
}

private struct SampleEmpty: View {
    var body: some View {
        EmptyState(title: "No web apps yet", line: "Paste a link and Pilot makes it an app.", action: ("Paste a link", {}))
    }
}

private struct SamplePopover: View {
    @State private var volume = 0.5
    var body: some View {
        KitPopover {
            HStack { Text("Sound").fontWeight(.semibold); Spacer(); Text("50%").font(Theme.mono(12)).foregroundStyle(Theme.text2) }
            KitSlider(value: $volume, label: "Volume", width: 206).padding(.top, 8)
            HStack(spacing: 6) {
                Image(systemName: "speaker.wave.2"); Text("MacBook Speakers"); Spacer()
                Image(systemName: "checkmark").foregroundStyle(Theme.accent)
            }
            .font(.system(size: 12)).foregroundStyle(Theme.text2).padding(.top, 8)
        }
    }
}

/// Section 5 as a table: the component and its use, then its drawing on the theme's ground.
struct KitGallery: View {
    var body: some View {
        Grid(alignment: .leading, horizontalSpacing: 0, verticalSpacing: 0) {
            GridRow {
                ForEach(["component", "sample"], id: \.self) {
                    Text($0).font(Theme.mono(12, weight: .medium)).foregroundStyle(Theme.muted).padding(12)
                }
            }
            ForEach(KitSample.allCases, id: \.self) { sample in
                Theme.line.frame(height: 1).gridCellUnsizedAxes(.horizontal)
                GridRow {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(sample.title).font(.system(size: 14, weight: .semibold))
                        Text(sample.use).font(.system(size: 12)).foregroundStyle(Theme.muted)
                    }
                    .frame(width: 140, alignment: .leading).padding(14)
                    sample.demo
                        .padding(14).frame(width: 420, alignment: .leading)
                        .background(Theme.background, in: .rect(cornerRadius: 12))
                        .overlay { RoundedRectangle(cornerRadius: 12).strokeBorder(Theme.line) }
                        .padding(10)
                }
            }
        }
        .padding(8)
        .background(Theme.sidebar)
    }
}
#endif
