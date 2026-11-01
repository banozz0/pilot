import AppKit
import PilotCore
import SwiftUI

// Mockup E's preview and app picker (card agent-bo-95422980): the workspace drawn as a screen, each placed app a tile
// with its icon and name, the dashed spot where the next app goes; under own sizes an accent line between two apps that
// drags their percents. A spot clicked opens the picker hung off it.

/// The workspace as a screen: a menu bar strip, then the placed apps where the layout puts them, 6 pt apart. Until the
/// layout's spots are full its empty ones show as dashed spots (Sven 2026-10-30: main + stack draws the main and the
/// stacked pair); past that the next app's spot is a strip where it joins. Scrolling's strip shows three columns whole;
/// each column past them peeks in at the right edge with its number, and the next app's spot is the strip's next column.
struct WorkspacePreview: View {
    @Environment(\.ink) private var ink

    @Binding var draft: WorkspacePresetDraft
    @Binding var hovered: Int?
    let picking: WorkspaceEditor.Spot?
    /// Each spot's frame in the popup, for the picker.
    @Binding var spots: [WorkspaceEditor.Spot: CGRect]
    let open: (WorkspaceEditor.Spot) -> Void

    private static let gap: CGFloat = 6, strip: CGFloat = 34

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: ink.radius(8), style: .continuous)
        GeometryReader { g in
            // Laid out half a gap past each edge, then each tile inset by half a gap: 6 pt between, flush at the edges.
            let half = Self.gap / 2
            let area = CGRect(origin: .zero, size: g.size).insetBy(dx: -half, dy: -half)
            let preview = draft.shape(in: area) ?? {
                let full = draft.preview(in: area, strip: Self.strip + Self.gap)
                return (full.apps, [full.next])
            }()
            let strip = draft.layout == .scrolling
            ZStack(alignment: .topLeading) {
                ForEach(Array(draft.apps.enumerated()), id: \.element.bundleId) { i, app in
                    let r = preview.apps[i].insetBy(dx: half, dy: half)
                    PreviewTile(app: app, place: draft.place(of: i), ownSizes: draft.layout == nil,
                                size: r.size, hovered: hovered == i, on: picking == .app(i),
                                peek: strip && i >= LayoutPreset.shownColumns ? i + 1 : nil,
                                open: { open(.app(i)) },
                                remove: { withAnimation(Kit.change) { hovered = nil; draft.remove(at: i) } },
                                hover: { inside in hovered = inside ? i : (hovered == i ? nil : hovered) })
                        .frame(width: r.width, height: r.height)
                        .onGeometryChange(for: CGRect.self) { $0.frame(in: .named(WorkspaceEditor.space)) } action: { spots[.app(i)] = $0 }
                        .position(x: r.midX, y: r.midY)
                }
                // The layout's empty spots, the first where the next app lands; a click on any adds to the first.
                ForEach(preview.open.indices, id: \.self) { k in
                    let r = preview.open[k].insetBy(dx: half, dy: half), spot = WorkspaceEditor.Spot.open(k)
                    AddSpot(big: k == 0 && r.width >= 150 && r.height >= 90, narrow: r.width < 90 && r.width < r.height, on: picking == spot) { open(spot) }
                        .frame(width: r.width, height: r.height)
                        .onGeometryChange(for: CGRect.self) { $0.frame(in: .named(WorkspaceEditor.space)) } action: { spots[spot] = $0 }
                        .position(x: r.midX, y: r.midY)
                }
                if draft.layout == nil {
                    ForEach(0..<max(0, draft.apps.count - 1), id: \.self) { i in
                        SizeDivider(draft: $draft, divider: i, tiles: preview.apps, height: g.size.height)
                    }
                }
            }
            .coordinateSpace(.named(SizeDivider.space))
        }
        .padding(.horizontal, 7).padding(.bottom, 7).padding(.top, 16)
        .frame(minHeight: 150)
        .background {
            shape.fill(ink.well)
                .overlay(alignment: .top) {
                    VStack(spacing: 0) { ink.text.opacity(0.05).frame(height: 9); ink.line.frame(height: 1) }
                }
                .clipShape(shape)
        }
        .overlay { shape.strokeBorder(ink.line2) }
        .animation(Kit.change, value: draft.apps.map(\.bundleId))
        .animation(Kit.change, value: draft.layout)
    }
}

/// A placed app: its icon and name, where it sits (a ready layout) or its percent (own sizes); the mouse over it shows
/// Replace and Remove as buttons (card agent-bo-95423003, Sven: "the x should be like a button when mouse is on the
/// window with either remove or replace app"), and a click anywhere else on it replaces it too.
struct PreviewTile: View {
    @Environment(\.ink) private var ink
    enum HoverButtons { case labelled, signs }
    enum HoverAction: CaseIterable {
        case replace, remove
        var title: String { self == .replace ? "Replace" : "Remove" }
        var symbol: String { self == .replace ? "arrow.left.arrow.right" : "trash" }
    }

    /// Words on the buttons where the tile has room for both side by side under its name, else their signs alone.
    static func hoverButtons(_ size: CGSize) -> HoverButtons { size.width >= 170 && size.height >= 90 ? .labelled : .signs }

    let app: WorkspacePreset.App
    /// Where it sits: a ready layout's role shown at the top left; under own sizes the percent shows under the name.
    let place: String
    let ownSizes: Bool
    let size: CGSize
    let hovered: Bool
    let on: Bool
    /// A strip's column past the screen's right edge, its number: it peeks in, too narrow for its name.
    var peek: Int?
    let open: () -> Void
    let remove: () -> Void
    let hover: (Bool) -> Void

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: AddSpot.radius, style: .continuous)
        if let peek { peeking(shape, number: peek) } else { whole(shape) }
    }

    /// The tile's ground: lit under the mouse; a peeking column a shade darker, the way one off the screen reads.
    private func card(_ shape: RoundedRectangle) -> some View {
        shape.fill(hovered ? ink.selected : peek == nil ? ink.tile : ink.tile.mix(with: ink.well, by: 0.3))
            .overlay { shape.strokeBorder(on ? ink.accent : ink.line2, lineWidth: on ? 1.5 : 1) }
    }

    private func whole(_ shape: RoundedRectangle) -> some View {
        // A tall tile takes the big icon, a stacked one the small; one too small for an icon keeps its name.
        let icon: CGFloat? = size.width < 60 ? nil : size.height >= 180 && size.width >= 90 ? 40 : size.height >= 68 ? 30 : size.height >= 54 ? 22 : nil
        return ZStack {
            Button(action: open) {
                VStack(spacing: 6) {
                    if let icon { AppGlyph(bundles: [app.bundleId], symbol: "app.dashed", size: icon) }
                    Text(app.name).font(ink.ui(12.5, .medium)).foregroundStyle(ink.text).lineLimit(1).truncationMode(.tail)
                    if ownSizes { Text("\(app.percent) %").font(ink.mono(11)).foregroundStyle(ink.text2) }
                }
                .padding(.horizontal, 8)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background { card(shape) }
                .contentShape(shape)
            }
            .buttonStyle(.kitPress)
            .accessibilityLabel("\(app.name), \(place)")
            .accessibilityHint("Swaps it for another app")
            if !ownSizes, size.height >= 70 {
                Text(place).font(ink.mono(10)).foregroundStyle(ink.muted).lineLimit(1)
                    .padding(.top, 6).padding(.leading, 7).padding(.trailing, 30)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    .allowsHitTesting(false).accessibilityHidden(true)
            }
            if hovered {
                hoverPair()
                    .padding(.bottom, Self.hoverButtons(size) == .labelled ? 12 : 6)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
                    .transition(.opacity)
            }
        }
        .onHover(perform: hover)
        .animation(Kit.change, value: hovered)
    }

    /// A peeking column: its number and icon; under them, Replace and Remove stack as signs. Where it is too short for
    /// both, the icon gives way to them.
    private func peeking(_ shape: RoundedRectangle, number: Int) -> some View {
        let icon = min(30, size.width - 12), pair: CGFloat = 22 * 2 + 4 + 6
        // Too short for the icon in the middle and the signs under it with 4 pt between.
        let crowded = size.height < icon + 2 * pair + 8
        return ZStack {
            card(shape).allowsHitTesting(false)
            Button(action: open) {
                ZStack {
                    if icon >= 16 {
                        AppGlyph(bundles: [app.bundleId], symbol: "app.dashed", size: icon).opacity(hovered && crowded ? 0 : 1)
                    }
                    if size.height >= 70 {
                        Text("\(number)").font(ink.mono(10)).foregroundStyle(ink.muted)
                            .padding(.top, 6).frame(maxHeight: .infinity, alignment: .top)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .contentShape(.rect)
            }
            .buttonStyle(.kitPress)
            .help("\(app.name), \(place)")
            .accessibilityLabel("\(app.name), \(place)")
            .accessibilityHint("Swaps it for another app")
            if hovered && size.width >= 24 {
                hoverPair(stacked: true)
                    .padding(.bottom, 6)
                    .frame(maxHeight: .infinity, alignment: .bottom)
                    .transition(.opacity)
            }
        }
        .onHover(perform: hover)
        .animation(Kit.change, value: hovered)
    }
}

extension PreviewTile {
    /// Replace and Remove: labelled buttons, or their signs on a small tile, each named for VoiceOver; `stacked` puts
    /// the signs one over the other, for a peeking column.
    @ViewBuilder fileprivate func hoverPair(stacked: Bool = false) -> some View {
        let labelled = !stacked && Self.hoverButtons(size) == .labelled
        let radius = ink.radius(!labelled ? 5 : 15)
        let stack = stacked ? AnyLayout(VStackLayout(spacing: 4)) : AnyLayout(HStackLayout(spacing: labelled ? 8 : 4))
        stack {
            ForEach(HoverAction.allCases, id: \.self) { action in
                Button(action: action == .replace ? open : remove) {
                    HStack(spacing: 6) {
                        Image(systemName: action.symbol).font(ink.ui(11, .semibold))
                        if labelled { Text(action.title).font(ink.ui(12.5, .semibold)) }
                    }
                    .foregroundStyle(action == .remove ? ink.red : ink.text)
                    .padding(.horizontal, labelled ? 12 : 6).frame(minWidth: stacked ? 24 : nil).frame(height: labelled ? 30 : 22)
                    .background(ink.background, in: .rect(cornerRadius: radius, style: .continuous))
                    .overlay { RoundedRectangle(cornerRadius: radius, style: .continuous).strokeBorder(ink.line2) }
                    .shadow(color: .black.opacity(0.25), radius: 4, y: 2)
                    .contentShape(.rect)
                }
                .buttonStyle(.kitPress)
                .help("\(action.title) \(app.name)")
                .accessibilityLabel("\(action.title) \(app.name)")
            }
        }
    }
}

/// The dashed spot where the next app goes: big and alone on an empty screen, a strip once apps are placed, lit while
/// its picker is open.
struct AddSpot: View {
    @Environment(\.ink) private var ink
    static var radius: CGFloat { Theme.radius(9) }

    let big: Bool
    /// A strip down the right, too narrow for the word beside the plus.
    let narrow: Bool
    let on: Bool
    let open: () -> Void
    @State private var hovered = false

    var body: some View {
        Button(action: open) {
            DashedFace(on: on, hovered: hovered) {
                if big {
                    VStack(spacing: 8) { Image(systemName: "plus").font(ink.ui(22, .light)); Text("Click to add an app").font(ink.ui(13)) }
                } else if narrow {
                    VStack(spacing: 4) { Image(systemName: "plus").font(ink.ui(14)); Text("Add").font(ink.ui(11)) }
                } else {
                    HStack(spacing: 6) { Image(systemName: "plus").font(ink.ui(14)); Text("Add").font(ink.ui(12)) }
                }
            }
        }
        .buttonStyle(.kitPress)
        .focusBorder(on: on, radius: Self.radius)
        .onHover { hovered = $0 }
        .animation(Kit.change, value: hovered)
        .accessibilityLabel("Add an app")
    }
}

/// A dashed spot's face, the next app's and From a preset's: muted words in a dashed outline, lit under the mouse, in
/// the accent while its picker is open.
struct DashedFace<Content: View>: View {
    @Environment(\.ink) private var ink
    var on = false
    let hovered: Bool
    @ViewBuilder var label: Content

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: AddSpot.radius, style: .continuous)
        label
            .foregroundStyle(on ? ink.accentText : hovered ? ink.text2 : ink.muted)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(on ? ink.selection : ink.text.opacity(hovered ? 0.04 : 0), in: shape)
            .overlay { shape.strokeBorder(on ? ink.accent : ink.line2, style: StrokeStyle(lineWidth: 1.5, dash: [4, 3])) }
            .contentShape(shape)
    }
}

/// Own sizes' line between app `divider` and the next: an accent handle that drags the two apps' percents, as the
/// mockup's; VoiceOver adjusts it 5 % a step.
private struct SizeDivider: View {
    @Environment(\.ink) private var ink
    nonisolated static let space = "workspacePreview"
    @Binding var draft: WorkspacePresetDraft
    let divider: Int
    /// The placed apps' tiles in the preview's space, half a gap past its edges.
    let tiles: [CGRect]
    let height: CGFloat

    var body: some View {
        let x = tiles[divider].maxX
        let width = (tiles.last?.maxX ?? 0) - (tiles.first?.minX ?? 0)
        let (left, right) = (draft.apps[divider], draft.apps[divider + 1])
        Capsule().fill(ink.accent).frame(width: 6, height: 44)
            .overlay { Capsule().strokeBorder(ink.sidebar, lineWidth: 2).padding(-2) }
            .shadow(color: .black.opacity(0.35), radius: 3, y: 2)
            .frame(width: 14, height: max(44, height - 12))
            .contentShape(.rect)
            .pointerStyle(.columnResize)
            .gesture(DragGesture(minimumDistance: 0, coordinateSpace: .named(Self.space)).onChanged { drag in
                guard width > 0 else { return }
                let share = (drag.location.x - tiles[divider].minX) / width * CGFloat(draft.total)
                draft.resize(divider: divider, to: Int(share.rounded()))
            })
            .position(x: x, y: height / 2)
            .accessibilityElement()
            .accessibilityLabel("Size of \(left.name) and \(right.name)")
            .accessibilityValue("\(left.percent) % and \(right.percent) %")
            .accessibilityAdjustableAction { direction in
                switch direction {
                case .increment: draft.resize(divider: divider, to: left.percent + 5)
                case .decrement: draft.resize(divider: divider, to: left.percent - 5)
                @unknown default: break
                }
            }
    }
}

/// The app picker hung off a spot (mockup E): a search field, then Apps and Web apps (a web app shows its site), filtered
/// as you type; Up and Down move the pick, Return takes it, Esc closes.
struct AppPicker: View {
    @Environment(\.ink) private var ink
    /// What the query finds, best first: apps, then web apps.
    struct Matches {
        let apps: [WorkspaceEditor.AppChoice], web: [WorkspaceEditor.AppChoice]

        init(_ choices: [WorkspaceEditor.AppChoice], query: String) {
            let ranked = FuzzyRanker.rank(choices, query: query, title: \.name)
            (apps, web) = (ranked.filter { $0.host == nil }, ranked.filter { $0.host != nil })
        }
    }

    let matches: Matches
    /// The picker's whole height: height(for:), or less where the popup has no more room, the list scrolling.
    let height: CGFloat
    /// Apps already on the workspace, marked "here"; picking one trades spots with it.
    let placed: Set<String>
    @Binding var query: String
    /// The row under the mouse.
    @Binding var hover: Int?
    let pick: (WorkspaceEditor.AppChoice) -> Void
    let close: () -> Void
    @State private var highlighted = 0
    @FocusState private var focused: Bool

    static let width: CGFloat = 262
    private static let rowHeight: CGFloat = 32, field: CGFloat = 37, longest: CGFloat = 300
    /// A group's heading: the first sits closer to the field.
    private static func heading(first: Bool) -> CGFloat { first ? 24 : 30 }

    /// The picker's height for these matches: the field, then the list up to 300 pt.
    static func height(for matches: Matches) -> CGFloat {
        let (apps, web) = (matches.apps, matches.web)
        guard !apps.isEmpty || !web.isEmpty else { return field + 52 }
        let headings = (apps.isEmpty ? 0 : heading(first: true)) + (web.isEmpty ? 0 : heading(first: apps.isEmpty))
        return field + min(longest, CGFloat(apps.count + web.count) * rowHeight + headings + 10)
    }

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: ink.radius(14), style: .continuous)
        let (apps, web) = (matches.apps, matches.web)
        let rows = apps + web
        VStack(spacing: 0) {
            HStack(spacing: 7) {
                Image(systemName: "magnifyingglass").font(ink.ui(12)).foregroundStyle(ink.muted).accessibilityHidden(true)
                TextField("", text: $query, prompt: Text("Search apps").foregroundStyle(ink.muted))
                    .textFieldStyle(.plain).font(ink.ui(13)).focused($focused)
                    .accessibilityLabel("Search apps")
                    .onSubmit { if rows.indices.contains(highlighted) { pick(rows[highlighted]) } }
                    .onExitCommand(perform: close)
                    .onKeyPress(.downArrow) { highlighted = min(highlighted + 1, rows.count - 1); return .handled }
                    .onKeyPress(.upArrow) { highlighted = max(highlighted - 1, 0); return .handled }
            }
            .padding(.horizontal, 10).frame(height: Self.field - 1)
            ink.line.frame(height: 1)
            if rows.isEmpty {
                Text("No app called “\(query)”").font(ink.ui(12)).foregroundStyle(ink.muted).lineLimit(1)
                    .frame(maxWidth: .infinity).frame(height: 52)
            } else {
                ScrollViewReader { scroll in
                    ScrollView(.vertical) {
                        VStack(alignment: .leading, spacing: 0) {
                            if !apps.isEmpty {
                                group("Apps", first: true)
                                ForEach(apps.indices, id: \.self) { i in row(apps[i], index: i) }
                            }
                            if !web.isEmpty {
                                group("Web apps", first: apps.isEmpty)
                                ForEach(web.indices, id: \.self) { i in row(web[i], index: apps.count + i) }
                            }
                        }
                        .padding(.horizontal, 5).padding(.top, 4).padding(.bottom, 6)
                    }
                    .scrollIndicators(.never)
                    .frame(height: height - Self.field)
                    .onChange(of: highlighted) { scroll.scrollTo(highlighted) }
                }
            }
        }
        .frame(width: Self.width)
        .background(ink.background, in: shape)
        .clipShape(shape)
        .overlay { shape.strokeBorder(ink.line2) }
        .shadow(color: .black.opacity(0.45), radius: 20, y: 18)
        .shadow(color: .black.opacity(0.25), radius: 3, y: 2)
        // The field is in the window only after this pass; set now, the focus is dropped and keys stay with the
        // sidebar's search.
        .onAppear { Task { @MainActor in focused = true } }
        .onChange(of: query) { highlighted = 0 }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Pick an app")
    }

    private func group(_ title: String, first: Bool) -> some View {
        Text(title).font(ink.ui(11, .semibold)).foregroundStyle(ink.muted)
            .padding(.horizontal, 8).padding(.bottom, 4)
            .frame(height: Self.heading(first: first), alignment: .bottomLeading)
            .accessibilityAddTraits(.isHeader)
    }

    private func row(_ choice: WorkspaceEditor.AppChoice, index: Int) -> some View {
        let selected = index == highlighted
        let kind = choice.host ?? (placed.contains(choice.bundle) ? "here" : nil)
        return Button { pick(choice) } label: {
            HStack(spacing: 10) {
                AppLabel(name: choice.name, spacing: 10) {
                    AppGlyph(bundles: [choice.bundle], symbol: choice.host == nil ? "app.dashed" : "globe", colour: choice.host == nil ? .neutral : .accent, size: 20)
                } title: {
                    Text(choice.name).font(.system(size: 13, weight: selected ? .semibold : .regular)).lineLimit(1).truncationMode(.tail)
                }
                Spacer(minLength: 6)
                if let kind { Text(kind).font(ink.ui(12)).foregroundStyle(ink.rowQuiet(selected)).lineLimit(1) }
            }
            .foregroundStyle(selected ? ink.onAccent : ink.text)
            .padding(.horizontal, 8)
            .frame(maxWidth: .infinity, minHeight: Self.rowHeight, maxHeight: Self.rowHeight, alignment: .leading)
            .background {
                if selected { KitRowBackground(selected: true) }
                else if hover == index { RoundedRectangle(cornerRadius: ink.radius(10)).fill(ink.text.opacity(0.06)) }
            }
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .onHover { inside in hover = inside ? index : (hover == index ? nil : hover) }
        .id(index)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}
