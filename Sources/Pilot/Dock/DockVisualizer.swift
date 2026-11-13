import AppKit
import Observation
import PilotCore
import QuartzCore

/// The bars' window, behind a protocol so tests and the sandbox never draw on the screen.
@MainActor
protocol DockBarsPanels: AnyObject {
    func show(height: CGFloat)
    func hide()
    /// The bars as one path, y 0 at the screen's foot.
    func draw(_ path: CGPath)
}

/// The dock's visualizer (rice round, Sven 2026-11-13, Q220 A; off by default): while it is on and the dock shows, the
/// watch (DockAudioWatch) says when something plays; the gate open (DockAudioGate), the tap starts and a 60 fps frame
/// clock analyses both channels (DockSpectrum) and redraws the bars as one CAShapeLayer path, out from the pill to the
/// screen's edges. Closed, the tap and the clock stop and the bars settle into a flat line, which costs nothing (round
/// 1: 0.0 % while silent, about 1.2 % of an M4 at 60 fps). Silence for DockAudioGate.settle seconds: with the reader
/// saying a player plays (a gap between tracks), the clock stops and a check twice a second starts it at the next loud
/// sample; open on the device alone (the reader cannot read), the tap stops too and waits for the device's next start,
/// as the tap's own aggregate device keeps the output device running while it lasts.
@Observable @MainActor
final class DockVisualizer {
    static let fps = 60.0

    @ObservationIgnored var watch: any DockAudioWatch
    @ObservationIgnored var source: any DockAudioSource
    @ObservationIgnored var panels: any DockBarsPanels
    /// The screen's width the bars span; the main screen's.
    @ObservationIgnored var screenWidth: () -> CGFloat = { NSScreen.screens.first?.frame.width ?? 1440 }
    /// The rest pill's width, told by DockView as it changes.
    var pillWidth: CGFloat = 0 { didSet { if pillWidth != oldValue, !drawing { drawFlat() } } }
    /// The tallest bar, from the dock's size.
    var tallest: CGFloat = CGFloat(DockSize.medium.tallestBar)

    private(set) var on = false
    private(set) var deviceRunning = false
    private(set) var playing: Bool?
    private(set) var tapping = false
    /// The frame clock runs: the bars move.
    private(set) var drawing = false
    private(set) var frames = 0
    private(set) var problem: String?
    /// Both channels' bars now, bass first, as last drawn; empty while flat.
    private(set) var left: [Float] = []
    private(set) var right: [Float] = []

    @ObservationIgnored private let ring = DockSampleRing()
    @ObservationIgnored private var spectra: (DockSpectrum, DockSpectrum)?
    @ObservationIgnored private var clock: DockFrameClock?
    @ObservationIgnored private var quiet = 0.0
    @ObservationIgnored private var wake: Timer?
    /// Settled on the device alone: the tap waits for the device to stop and start again.
    @ObservationIgnored private var waitingForStart = false

    init(watch: any DockAudioWatch = CoreAudioWatch(), source: any DockAudioSource = CoreAudioTapSource(), panels: any DockBarsPanels = DockBarsWindow()) {
        self.watch = watch
        self.source = source
        self.panels = panels
    }

    var open: Bool { DockAudioGate.open(deviceRunning: deviceRunning, playing: playing) }

    /// On: the flat line shows and the watch listens. Off: everything stops and the window goes.
    func set(_ on: Bool) {
        guard on != self.on else { return }
        self.on = on
        if on {
            panels.show(height: tallest)
            drawFlat()
            followTheme()
            watch.start { [weak self] running, playing in self?.heard(running, playing) }
        } else {
            watch.stop()
            close()
            panels.hide()
            deviceRunning = false
            playing = nil
            waitingForStart = false
        }
    }

    /// The flat line drawn again in the new accent when the theme changes (the moving bars take it on their next frame).
    private func followTheme() {
        guard on else { return }
        _ = withObservationTracking { Look.shared.theme.accent } onChange: { [weak self] in
            Task { @MainActor in
                guard let self, self.on else { return }
                if !self.drawing { self.drawFlat() }
                self.followTheme()
            }
        }
    }

    /// The switch's press: the source asks macOS for its permission now.
    func ask() async { await source.ask() }

    private func heard(_ running: Bool, _ playing: Bool?) {
        if !running || playing != nil { waitingForStart = false }
        deviceRunning = running
        self.playing = playing
        if open && !waitingForStart { listen() } else { close() }
    }

    /// The gate opened: the tap starts and the bars move.
    private func listen() {
        guard on, !tapping else { return }
        ring.clear()
        do { try source.start(into: ring) } catch {
            problem = String(describing: error)
            docklog.error("dock visualizer: \(String(describing: error), privacy: .public)")
            return
        }
        problem = nil
        tapping = true
        spectra = (DockSpectrum(sampleRate: Float(ring.rate)), DockSpectrum(sampleRate: Float(ring.rate)))
        run()
    }

    /// The gate closed: the tap and the clock stop, the bars lie flat.
    private func close() {
        if tapping { source.stop() }
        tapping = false
        halt()
        spectra = nil
        if on { drawFlat() }
    }

    private func run() {
        wake?.invalidate()
        wake = nil
        quiet = 0
        guard !drawing else { return }
        drawing = true
        clock = DockFrameClock(fps: Self.fps) { [weak self] dt in self?.tick(dt) }
    }

    private func halt() {
        clock?.stop()
        clock = nil
        drawing = false
        wake?.invalidate()
        wake = nil
    }

    /// One frame: both channels analysed, the bars drawn. Silence for `settle` seconds stops the clock (the tap goes on,
    /// as the gate is open); a check twice a second starts it again at the first loud sample.
    private func tick(_ dt: Double) {
        guard let spectra else { return }
        let samples = ring.read(spectra.0.size)
        left = spectra.0.step(samples.left[...], dt: Float(dt))
        right = spectra.1.step(samples.right[...], dt: Float(dt))
        frames += 1
        panels.draw(DockBarsPath.path(width: screenWidth(), pill: pillWidth, tallest: tallest, left: left, right: right))
        quiet = samples.peak < 0.0005 && (left + right).allSatisfy { $0 < 0.01 } ? quiet + dt : 0
        if quiet >= DockAudioGate.settle, playing == nil {
            // Open on the device alone: the tap itself keeps the device running, so it stops until the next start.
            waitingForStart = true
            close()
        } else if quiet >= DockAudioGate.settle {
            halt()
            drawFlat()
            wake = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { if let self, self.tapping, self.ring.read(1).peak >= 0.0005 { self.run() } }
            }
            // The idle listen coalesces with other wake-ups (story 142, P9).
            wake?.tolerance = 0.1
        }
    }

    private func drawFlat() {
        left = []
        right = []
        guard on else { return }
        panels.draw(DockBarsPath.path(width: screenWidth(), pill: pillWidth, tallest: tallest, left: nil, right: nil))
    }

    /// What `pilot dock visualizer` reads.
    var report: [String: JSONValue] {
        let n = DockBarsPath.perSide(width: screenWidth(), pill: pillWidth)
        func bars(_ levels: [Float]) -> JSONValue {
            .array((0..<min(n, 12)).map { k in .number((Double(DockSpectrum.sample(levels, at: Double(k) / Double(max(1, n - 1)))) * 100).rounded()) })
        }
        return [
            "on": .bool(on), "listensWith": .string(watch.name), "hearsWith": .string(source.name),
            "deviceRunning": .bool(deviceRunning), "player": .string(playing.map { $0 ? "playing" : "paused" } ?? "unknown"),
            "gate": .string(open ? "open" : "closed"), "tapping": .bool(tapping), "moving": .bool(drawing),
            "shows": .string(!on ? "nothing" : drawing ? "bars" : "flat line"), "frames": .number(Double(frames)),
            "waitsForDeviceStart": .bool(waitingForStart),
            "fps": .number(Self.fps), "barsPerSide": .number(Double(n)), "tallest": .number(Double(tallest)),
            "leftNearestPill": left.isEmpty ? .null : bars(left), "rightNearestPill": right.isEmpty ? .null : bars(right),
            "problem": problem.map(JSONValue.string) ?? .null,
        ]
    }
}

/// A frame clock at `fps`: the main screen's display link (macOS 14+), so frames land with the screen's; a timer where
/// there is no screen.
@MainActor
final class DockFrameClock: NSObject {
    private var link: CADisplayLink?
    private var timer: Timer?
    private var last: CFTimeInterval = 0
    private let tick: @MainActor (Double) -> Void
    private let fps: Double

    init(fps: Double, tick: @escaping @MainActor (Double) -> Void) {
        self.tick = tick
        self.fps = fps
        super.init()
        if let screen = NSScreen.screens.first {
            let link = screen.displayLink(target: self, selector: #selector(frame(_:)))
            link.preferredFrameRateRange = CAFrameRateRange(minimum: Float(fps), maximum: Float(fps), preferred: Float(fps))
            link.add(to: .main, forMode: .common)
            self.link = link
        } else {
            timer = Timer.scheduledTimer(withTimeInterval: 1 / fps, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.tick(1 / (self?.fps ?? 60)) }
            }
            timer?.tolerance = 0.1 / fps
        }
    }

    @objc private func frame(_ link: CADisplayLink) {
        let now = link.timestamp
        let dt = last == 0 ? 1 / fps : min(0.1, now - last)
        last = now
        tick(dt)
    }

    func stop() {
        link?.invalidate()
        link = nil
        timer?.invalidate()
        timer = nil
    }
}

/// The bars' window: the main screen's width at its foot, as tall as the tallest bar, under every window (one level
/// below the normal one), so the bars fill the strip the tiler keeps free and pass behind windows above it; never takes
/// a click. One CAShapeLayer in the theme's accent draws them; the render server fills its path.
@MainActor
final class DockBarsWindow: DockBarsPanels {
    private var panel: NSPanel?
    private let shape = CAShapeLayer()
    private var colour: UInt32?

    static let level = NSWindow.Level(rawValue: NSWindow.Level.normal.rawValue - 1)

    func show(height: CGFloat) {
        guard let screen = NSScreen.screens.first else { return }
        let frame = NSRect(x: screen.frame.minX, y: screen.frame.minY, width: screen.frame.width, height: height.rounded(.up))
        if panel == nil {
            let panel = NSPanel(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
            panel.title = "Pilot dock visualizer"
            panel.isOpaque = false
            panel.backgroundColor = .clear
            panel.hasShadow = false
            panel.ignoresMouseEvents = true
            panel.level = Self.level
            panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenNone]
            panel.isReleasedWhenClosed = false
            panel.hidesOnDeactivate = false
            let view = NSView(frame: NSRect(origin: .zero, size: frame.size))
            view.wantsLayer = true
            shape.frame = view.bounds
            shape.actions = ["path": NSNull(), "fillColor": NSNull(), "bounds": NSNull(), "position": NSNull()]
            view.layer?.addSublayer(shape)
            panel.contentView = view
            self.panel = panel
        }
        panel?.setFrame(frame, display: false)
        shape.frame = CGRect(origin: .zero, size: frame.size)
        panel?.orderFrontRegardless()
    }

    func hide() {
        panel?.orderOut(nil)
        panel = nil
        shape.removeFromSuperlayer()
        shape.path = nil
    }

    func draw(_ path: CGPath) {
        let accent = Look.shared.theme.accent
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        if accent != colour {
            colour = accent
            let c = DockTinter.rgb(accent)
            shape.fillColor = CGColor(srgbRed: c[0] / 255, green: c[1] / 255, blue: c[2] / 255, alpha: 1)
        }
        shape.path = path
        CATransaction.commit()
    }
}

/// The sandbox's bars: nothing on screen.
@MainActor
final class DockNoBars: DockBarsPanels {
    func show(height: CGFloat) {}
    func hide() {}
    func draw(_ path: CGPath) {}
}
