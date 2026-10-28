import AppKit
import PilotCore
import SwiftUI

/// The Status lights item: only the lit sources' coloured dots, in a row (Sven, Q205). The top bar hides it while none is
/// lit (TopBarSlotView); the Menu bar page's strip shows unlit dots instead, so it can still be found and dragged.
/// The whole item is one target: a 6 pt dot is too small to hit alone. A click opens the popover.
struct TopBarStatusLights: View {
    @Environment(\.inTopBar) private var inBar
    let lights: StatusLights
    let open: () -> Void

    var body: some View {
        let lit = lights.lights, tip = StatusDots.summary(lit)
        let dots = StatusDotsView(lights: lit).accessibilityLabel(tip)
        if inBar {
            Button(action: open) { dots.barTarget(tip) }.buttonStyle(.kitPress)
        } else {
            Button(action: open) { dots }.buttonStyle(.plain).help(tip)
        }
    }
}

/// The dots themselves, left to right as StatusDots places them; three unlit ones while nothing is lit.
struct StatusDotsView: View {
    @Environment(\.style) private var style
    let lights: [StatusLight]

    var body: some View {
        let box = StatusDots.box, shown = StatusDots.shown(lights)
        HStack(spacing: 0) {
            if shown.isEmpty {
                ForEach(0..<StatusDots.quiet, id: \.self) { _ in
                    Circle().strokeBorder(BarMetrics.glyphInk(style).opacity(0.5), lineWidth: 1).frame(width: StatusDots.dot, height: StatusDots.dot)
                        .frame(width: box, height: box)
                }
            } else {
                ForEach(shown) { StatusDot(colour: NSColor(StatusInk.colour($0)), motion: StatusInk.motion($0)).frame(width: box, height: box) }
            }
        }
    }
}

/// The lights' colours and motion (Q201, Q202): working blue, waiting amber, done green, failed red, privacy hot pink.
/// Calm at rest: working pulses, waiting breathes, nothing else moves.
@MainActor
enum StatusInk {
    static let privacy = Color(red: 1, green: 0x4F / 255, blue: 0xD8 / 255)

    static func colour(_ light: StatusLight) -> Color {
        if light.family == .privacy { return privacy }
        return switch light.state {
        case .working: Color(nsColor: .systemBlue)
        case .waiting: Theme.yellow
        case .done: Theme.green
        case .error: Theme.red
        case .watching: privacy
        }
    }

    static func motion(_ light: StatusLight) -> StatusDot.Motion {
        switch light.state {
        case .working: .pulse
        case .waiting: .breathe
        default: .still
        }
    }
}

/// One dot, drawn by its own view so its motion is a Core Animation animation the render server runs: Pilot draws
/// nothing per frame while a light pulses, and a still dot costs nothing. The dot sits in a larger box so its breath
/// stays inside the view (StatusDots.box). With Reduce motion on, every dot is still.
struct StatusDot: NSViewRepresentable {
    enum Motion {
        case still, pulse, breathe

        /// One way of the cycle: working's 2.4 s pulse, waiting's 3.2 s breath.
        var duration: CFTimeInterval { self == .pulse ? 1.2 : 1.6 }
    }
    let colour: NSColor
    let motion: Motion

    func makeNSView(context: Context) -> DotView { DotView(colour: colour, motion: motion) }

    func updateNSView(_ view: DotView, context: Context) {
        if view.colour != colour { view.colour = colour }
        if view.motion != motion { view.motion = motion }
    }

    final class DotView: NSView {
        var colour: NSColor { didSet { needsDisplay = true } }
        var motion: Motion { didSet { animate() } }

        init(colour: NSColor, motion: Motion) {
            self.colour = colour
            self.motion = motion
            super.init(frame: .zero)
            wantsLayer = true
        }

        @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

        override func draw(_ dirtyRect: NSRect) {
            let d = StatusDots.dot
            colour.setFill()
            NSBezierPath(ovalIn: NSRect(x: bounds.midX - d / 2, y: bounds.midY - d / 2, width: d, height: d)).fill()
        }

        override func viewDidMoveToWindow() { animate() }
        override func layout() { super.layout(); animate() }

        /// Working: opacity 1 to 0.38 and back every 2.4 s, every working dot in one phase. Waiting: a breath to 1.5
        /// times its size every 3.2 s. Each added once, in the window only.
        private func animate() {
            guard let layer else { return }
            let key = "status.motion"
            let reduce = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
            guard window != nil, motion != .still, !reduce else { layer.removeAnimation(forKey: key); return }
            if let running = layer.animation(forKey: key), running.duration == motion.duration { return }
            let animation: CABasicAnimation
            switch motion {
            case .pulse:
                animation = CABasicAnimation(keyPath: "opacity")
                animation.fromValue = 1
                animation.toValue = 0.38
            case .breathe, .still:
                // About the dot's centre: a layer-backed view's layer turns on its corner.
                let c = CGPoint(x: bounds.midX, y: bounds.midY), s: CGFloat = 1.5
                var grown = CATransform3DMakeTranslation(c.x, c.y, 0)
                grown = CATransform3DScale(grown, s, s, 1)
                grown = CATransform3DTranslate(grown, -c.x, -c.y, 0)
                animation = CABasicAnimation(keyPath: "transform")
                animation.fromValue = CATransform3DIdentity
                animation.toValue = grown
            }
            animation.duration = motion.duration
            animation.autoreverses = true
            animation.repeatCount = .infinity
            animation.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            // One phase for all: each starts on the clock's last whole cycle.
            let cycle = animation.duration * 2, now = CACurrentMediaTime()
            animation.beginTime = layer.convertTime((now / cycle).rounded(.down) * cycle, from: nil)
            animation.isRemovedOnCompletion = false
            layer.add(animation, forKey: key)
        }
    }
}

/// The popover (direction A's grouped list): one row per lit source with its context, by family, most urgent first;
/// a row's click goes where it comes from. Opening it shows the done and failed lights, so the dots let them go.
struct StatusPopover: View {
    @Environment(\.style) private var style
    let lights: StatusLights
    var close: () -> Void = {}
    /// The done and failed lights it opened with, kept while it is open.
    @State private var kept: Set<String> = []

    var body: some View {
        let ink = BarInk(style: style), all = lights.all(keeping: kept)
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Status").font(ink.title)
                Spacer()
                Text(all.isEmpty ? "all quiet" : "\(all.count) lit").font(ink.detail).foregroundStyle(ink.muted)
            }
            if all.isEmpty {
                Text("Nothing needs a glance: no agent, no microphone or camera, no download or build.").foregroundStyle(ink.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }
            ForEach(StatusDots.groups(all), id: \.family) { group in
                VStack(alignment: .leading, spacing: 2) {
                    HStack {
                        Text(group.family.title.uppercased()).font(.system(size: 10, weight: .semibold)).tracking(0.6)
                        Spacer()
                        Text("\(group.lights.count)").font(ink.mono(10))
                    }
                    .foregroundStyle(ink.muted).padding(.horizontal, 6)
                    ForEach(group.lights) { light in
                        StatusRow(light: light) {
                            lights.open(light)
                            close()
                        }
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .onAppear { kept = lights.opened() }
        .barPopover(width: 320)
    }
}

/// One lit source: its dot, who and where from, privacy's eye, its context, and where a click goes.
struct StatusRow: View {
    @Environment(\.style) private var style
    let light: StatusLight
    let go: () -> Void
    @State private var hovered = false

    var body: some View {
        let ink = BarInk(style: style), colour = StatusInk.colour(light)
        Button(action: go) {
            HStack(alignment: .firstTextBaseline, spacing: 9) {
                Circle().fill(colour).frame(width: 7, height: 7).alignmentGuide(.firstTextBaseline) { $0[.bottom] - 1 }
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 5) {
                        if light.family == .privacy { Image(systemName: "eye.fill").font(.system(size: 10)).foregroundStyle(colour) }
                        Text(light.title).lineLimit(1).truncationMode(.tail).foregroundStyle(ink.text)
                        Text("· \(light.source)").lineLimit(1).foregroundStyle(ink.muted).layoutPriority(-1)
                        Spacer(minLength: 6)
                        Text(hovered ? light.go.map { $0 + " ›" } ?? light.state.word : light.state.word).font(ink.detail)
                            .foregroundStyle(light.state == .waiting ? colour : ink.muted).lineLimit(1)
                    }
                    if let detail = light.detail {
                        Text(detail).font(ink.detail).foregroundStyle(ink.text2).lineLimit(2).fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            .padding(.horizontal, 6).padding(.vertical, 6)
            .background(RoundedRectangle(cornerRadius: 7).fill(hovered ? ink.selected : .clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 }
        .accessibilityLabel("\(light.title), \(light.source), \(light.state.word)")
    }
}
