import AppKit
import PilotCore
import SwiftUI

/// What shows while Pilot dictates (Q239, Sven 2026-10-17): a small dark pill at
/// the bottom centre of the screen, ✕ to cancel, the microphone's live waveform, ✓ to finish; above it a toast naming the
/// microphone as a take starts, and after a cancel one offering its words back. Mode lights' microphone light still
/// follows Pilot's listening. The panel never becomes key, so the app Sven speaks to keeps the keyboard and the paste.
/// With Dictation › While you speak on Words, the pill is wider and shows the words so far, the newest in view, beside a
/// smaller waveform; a pass's new words come in one by one, the ones it kept staying put. Dictation › Show it in puts the
/// waveform in Pilot's top bar instead of the pill, or in both (DictationBarItem); the toasts stay at the foot of the screen.
@Observable @MainActor
final class DictationOverlay: DictationShowing {
    static let shared = DictationOverlay(setup: {
        let dictation = PilotDictation.shared
        return Setup(showIn: dictation.showIn, barSide: dictation.barSide, colour: dictation.waveColour, topBarShows: Engine.shared?.topBar.isOn ?? false)
    })

    /// Where a take shows and the waveform's colour, read as each take starts (Sven, 2026-11-01).
    struct Setup: Equatable {
        var showIn = PilotDictation.ShowIn.pill
        /// Where in the top bar: Dictation › Position.
        var barSide = TopBarSide.left
        /// nil is Plain: white on the pill, the bar's own ink in the bar.
        var colour: ColourChoice?
        /// Pilot's top bar is on; off, a take meant for it shows in the pill.
        var topBarShows = false

        var inBar: Bool { showIn != .pill && topBarShows }
        var inPill: Bool { showIn != .topBar || !topBarShows }

        /// The waveform's colour: Plain draws `plain` (the pill's white, the bar's ink), Theme the theme's signal colour,
        /// Custom the one picked. A take and Voice's preview both draw it.
        @MainActor func waveColour(plain: Color) -> Color {
            colour.map { Color(Paint($0.resolved(Look.shared.theme.accent))) } ?? plain
        }
    }

    enum Phase: Equatable { case hidden, listening, writing }
    enum Toast: Equatable {
        /// "Using <microphone>", as a take starts.
        case microphone(String)
        /// A cancelled take's words, which Undo types.
        case recover(String)
    }

    /// The bars the waveform draws, newest on the right; the words pill draws the last `wordsBars`.
    static let bars = 18, wordsBars = 8
    /// The top bar's waveform: the last 12 readings, so it takes little of the bar.
    static let topBarBars = 12
    static let microphoneSeconds: TimeInterval = 2, recoverSeconds: TimeInterval = 6

    private(set) var phase = Phase.hidden
    private(set) var levels = [Double](repeating: 0, count: bars)
    private(set) var toast: Toast?
    /// This take's pill shows words, and the words so far.
    private(set) var showsWords = false
    /// Every word of the latest words so far, and how many of them show yet.
    private(set) var spoken: [SpokenWord] = []
    private(set) var revealed = 0
    /// This take's: the pill, the top bar, and the waveform's colour.
    private(set) var setup = Setup()
    /// The pill, or the top bar, shows this take. The bars read only `inBar`, the setup first: with Show it in on the pill
    /// alone they never read the phase, so a take never redraws them.
    var inPill: Bool { phase != .hidden && setup.inPill }
    var inBar: Bool { setup.inBar && phase != .hidden }
    var words: String { spoken.map(\.text).joined(separator: " ") }
    /// The words that show yet.
    var shown: [SpokenWord] { Array(spoken.prefix(revealed)) }

    @ObservationIgnored private(set) var cancel: @MainActor () -> Void = {}
    @ObservationIgnored private(set) var finish: @MainActor () -> Void = {}
    @ObservationIgnored private var recover: @MainActor (String) -> Void = { _ in }
    @ObservationIgnored private let after: Watch.After
    @ObservationIgnored private var toastTimer: Watch?
    @ObservationIgnored private var revealTimer: Watch?
    @ObservationIgnored private var lastWordID = 0
    @ObservationIgnored private let now: () -> Date
    /// When the last words so far came, and the usual time between two: what the next pass's words are spread over.
    @ObservationIgnored private var lastPass: Date?
    @ObservationIgnored private var passGap: TimeInterval?
    /// False in the renders: the model changes, no panel opens.
    @ObservationIgnored private let shows: Bool
    @ObservationIgnored private let readSetup: @MainActor () -> Setup
    @ObservationIgnored private var panel: NSPanel?
    /// The bottom centre the panel grows up from, picked as it opens.
    @ObservationIgnored private var anchor = CGPoint.zero

    init(after: @escaping Watch.After = Watch.after, now: @escaping () -> Date = Date.init, shows: Bool = true,
         setup: @escaping @MainActor () -> Setup = { Setup() }) {
        self.after = after
        self.now = now
        self.shows = shows
        readSetup = setup
    }

    func bind(cancel: @escaping @MainActor () -> Void, finish: @escaping @MainActor () -> Void, recover: @escaping @MainActor (String) -> Void) {
        self.cancel = cancel; self.finish = finish; self.recover = recover
    }

    func started(microphone: String?, words: Bool) {
        let read = readSetup()
        if read != setup { setup = read }
        phase = .listening
        levels = Array(repeating: 0, count: Self.bars)
        showsWords = words
        clearWords()
        // A cancelled take's words still on offer stay: the next take never takes Undo away.
        if let microphone, !isRecovering { say(.microphone(microphone), for: Self.microphoneSeconds) }
        refresh()
    }

    private var isRecovering: Bool { if case .recover = toast { true } else { false } }

    func levels(_ new: [Double]) {
        guard phase == .listening else { return }
        levels = Array((levels + new).suffix(Self.bars))
    }

    /// The model's latest words so far: a word the last pass had at the same place keeps it and is not drawn again, a
    /// changed one already in view swaps in place, and the words past those in view come in one by one. Never hidden
    /// again to come in anew: that retyped the whole pill each pass (Sven, 2026-10-19: "it lags a lot and sometimes
    /// repeats").
    func words(_ new: String) {
        guard phase != .hidden, showsWords else { return }
        let time = now()
        if let lastPass {
            let gap = time.timeIntervalSince(lastPass)
            passGap = passGap.map { 0.7 * $0 + 0.3 * gap } ?? gap
        }
        lastPass = time
        let tokens = new.split(whereSeparator: \.isWhitespace).map(String.init)
        spoken = tokens.enumerated().map { i, text in
            if i < spoken.count, spoken[i].text == text { return spoken[i] }
            lastWordID += 1
            return SpokenWord(id: lastWordID, text: text)
        }
        revealed = min(revealed, spoken.count)
        revealNext()
    }

    /// Shows the next word still hidden, then the one after a beat later: a pass's new words spread over most of the time
    /// until the next pass is due, so they flow rather than land in a lump and wait. Whisper turbo takes about 2 s a pass
    /// whatever the take's length (it always reads a 30 s window), Parakeet a tenth of that.
    private func revealNext() {
        guard revealTimer == nil, revealed < spoken.count else { return }
        withAnimation(.easeOut(duration: 0.18)) { revealed += 1 }
        let waiting = spoken.count - revealed
        guard waiting > 0 else { return }
        revealTimer = after(Self.revealStep(waiting: waiting, passGap: passGap)) { [weak self] in
            self?.revealTimer = nil
            self?.revealNext()
        }
    }

    /// Before a second pass, the words take half a second in all.
    static func revealStep(waiting: Int, passGap: TimeInterval?) -> TimeInterval {
        max(0.03, min(0.25, 0.7 * (passGap ?? 0.65) / Double(waiting)))
    }

    private func clearWords() {
        revealTimer?.cancel()
        revealTimer = nil
        spoken = []
        revealed = 0
        lastPass = nil
        passGap = nil
    }

    func writing() {
        guard phase != .hidden else { return }
        phase = .writing
        // The take is over: what the model has heard shows at once.
        revealTimer?.cancel()
        revealTimer = nil
        revealed = spoken.count
    }

    func ended() {
        phase = .hidden
        clearWords()
        if case .microphone = toast { closeToast() }
        refresh()
    }

    func recoverable(_ text: String) {
        say(.recover(text), for: Self.recoverSeconds)
        refresh()
    }

    /// The toast's Undo: the words go back in, and the toast closes; closed any other way, they are gone.
    func undo() {
        guard case .recover(let text) = toast else { return }
        closeToast()
        recover(text)
    }

    func closeToast() {
        toastTimer?.cancel()
        toastTimer = nil
        toast = nil
        refresh()
    }

    private func say(_ toast: Toast, for seconds: TimeInterval) {
        toastTimer?.cancel()
        self.toast = toast
        toastTimer = after(seconds) { [weak self] in
            guard let self, self.toast == toast else { return }
            withAnimation(.easeOut(duration: 0.3)) { self.toast = nil }
            refresh()
        }
    }

    // MARK: The panel

    /// Open while there is a pill or a toast to show, closed otherwise: a take shown in the top bar alone opens it for
    /// its toasts only.
    private func refresh() {
        guard shows else { return }
        if !inPill && toast == nil {
            panel?.orderOut(nil)
            panel = nil
            return
        }
        guard panel == nil else { return }
        let host = NSHostingView(rootView: DictationOverlayView(overlay: self)
            .onGeometryChange(for: CGSize.self, of: \.size) { [weak self] in self?.refit($0) }
            .pilotTheme())
        host.frame.size = host.fittingSize
        // Borderless, so it never becomes key: ✓ leaves the keyboard with the app the words go to (Recorder's capsule).
        let panel = NSPanel(contentRect: host.frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.level = HUD.level
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.contentView = host
        let screen = (Screens.focusedScreen ?? NSScreen.main)?.visibleFrame ?? .zero
        anchor = CGPoint(x: screen.midX, y: screen.minY + 10)
        self.panel = panel
        refit(host.frame.size)
        panel.orderFrontRegardless()
    }

    /// The panel at its content's size, growing up from the bottom centre, so the pill stays put as a toast comes and goes.
    private func refit(_ size: CGSize) {
        guard let panel, size.width > 0, size.height > 0 else { return }
        panel.setFrame(CGRect(x: (anchor.x - size.width / 2).rounded(), y: anchor.y, width: size.width.rounded(.up), height: size.height.rounded(.up)),
                       display: true)
    }
}

/// One word of the words so far, under an id it keeps while the model keeps it, so SwiftUI draws it once.
struct SpokenWord: Identifiable, Equatable {
    let id: Int
    let text: String
}

/// The toast over the pill, both bottom-aligned in the panel; a soft shadow needs the margin round them.
struct DictationOverlayView: View {
    let overlay: DictationOverlay

    var body: some View {
        VStack(spacing: 8) {
            switch overlay.toast {
            case .microphone(let name)?: DictationToast { Text("Using \(name)").lineLimit(1) }
            case .recover?: DictationRecoverToast(overlay: overlay)
            case nil: EmptyView()
            }
            if overlay.inPill {
                if overlay.showsWords { DictationWordsPill(overlay: overlay) } else { DictationPill(overlay: overlay) }
            }
        }
        .padding(12)
        .fixedSize()
    }
}

/// ✕, the waveform, ✓: dark whatever Pilot's style, so it reads on any wallpaper or window.
struct DictationPill: View {
    let overlay: DictationOverlay

    var body: some View {
        let writing = overlay.phase == .writing
        HStack(spacing: 8) {
            Button { overlay.cancel() } label: { DictationCircle(symbol: "xmark", light: false) }
                .accessibilityLabel("Cancel dictation")
            DictationLiveWave(overlay: overlay, bars: DictationOverlay.bars).opacity(writing ? 0.35 : 1)
            Button { overlay.finish() } label: { DictationCircle(symbol: "checkmark", light: true) }
                .disabled(writing).opacity(writing ? 0.35 : 1)
                .accessibilityLabel("Finish dictation")
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 6)
        .frame(height: 30)
        .dictationSurface(Capsule())
    }
}

/// The pill at Words (Sven, 2026-10-17: "the current that we have, just make it bigger and show the text"): ✕, the words
/// so far, a small waveform, ✓. The words wrap in full and a two-line window shows their last lines, the older ones
/// fading off the top (SwiftUI's head truncation on two lines cut the second line's middle instead). Each word is a view of
/// its own (Sven on Build 62: "streaming text rather than text appearing in chunks"), so a new one rises in and the rest
/// stay still. A fixed size, so the panel never moves as the words grow.
struct DictationWordsPill: View {
    @Environment(\.ink) private var ink
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let overlay: DictationOverlay

    static let width: CGFloat = 380, height: CGFloat = 48
    /// Two lines of 13 pt words.
    static let lines: CGFloat = 32

    var body: some View {
        let writing = overlay.phase == .writing
        let shown = overlay.shown
        HStack(spacing: 10) {
            Button { overlay.cancel() } label: { DictationCircle(symbol: "xmark", light: false) }
                .accessibilityLabel("Cancel dictation")
            Group {
                if shown.isEmpty { Text("Listening…").foregroundStyle(.white.opacity(0.5)) }
                else {
                    // A view per word: a new one fades and rises in, the ones before it stay as they were.
                    Flow(spacing: 3.5, lineSpacing: 0) {
                        ForEach(shown) { Text($0.text).transition(reduceMotion ? .opacity : .opacity.combined(with: .offset(y: 5))) }
                    }
                    .foregroundStyle(.white.opacity(writing ? 0.6 : 1))
                    .accessibilityElement(children: .combine)
                }
            }
            .font(ink.ui(13, .medium)).fixedSize(horizontal: false, vertical: true)
            // Up to two lines tall: one line sits centred, more show their last two.
            .frame(maxWidth: .infinity, maxHeight: Self.lines, alignment: .bottomLeading)
            .fixedSize(horizontal: false, vertical: true)
            .clipped()
            .mask(LinearGradient(stops: [.init(color: .clear, location: 0), .init(color: .black, location: 0.25)], startPoint: .top, endPoint: .bottom))
            DictationLiveWave(overlay: overlay, bars: DictationOverlay.wordsBars).opacity(writing ? 0.35 : 1)
            Button { overlay.finish() } label: { DictationCircle(symbol: "checkmark", light: true) }
                .disabled(writing).opacity(writing ? 0.35 : 1)
                .accessibilityLabel("Finish dictation")
        }
        .buttonStyle(.plain)
        .padding(.leading, 9).padding(.trailing, 11)
        .frame(width: Self.width, height: Self.height)
        .dictationSurface(Capsule())
    }
}

/// A waveform of the last `bars` readings, reading the levels itself: ten readings a second redraw it alone, never the
/// words or the bar around it. Its size is fixed, so a reading never lays out what holds it.
struct DictationLiveWave: View {
    let overlay: DictationOverlay
    let bars: Int
    /// Plain's colour: the pill's white, the bar's ink.
    var plain = DictationWave.white

    var body: some View {
        DictationWave(levels: Array(overlay.levels.suffix(bars)), colour: overlay.waveColour(plain: plain))
            .frame(width: CGFloat(bars) * 4.5 - 2, height: 18)
    }
}

/// The take in Pilot's top bar (Dictation › Show it in), just after Pilot's mark: the waveform, and at Words the newest
/// words on one line beside it while the bar has room (it folds to the waveform alone first). A click finishes the take as
/// the pill's ✓ does; Esc still cancels it.
struct DictationBarItem: View {
    @Environment(\.style) private var style
    let overlay: DictationOverlay

    static let wordsWidth: CGFloat = 170

    var body: some View {
        let writing = overlay.phase == .writing
        Button { overlay.finish() } label: {
            HStack(spacing: 0) {
                DictationLiveWave(overlay: overlay, bars: DictationOverlay.topBarBars, plain: BarMetrics.glyphInk(style))
                if overlay.showsWords {
                    // The words while the bar has room, else nothing: one waveform either way.
                    ViewThatFits(in: .horizontal) {
                        DictationBarWords(overlay: overlay).frame(width: Self.wordsWidth, alignment: .leading).padding(.leading, 8)
                        Color.clear.frame(width: 0)
                    }
                }
            }
            .opacity(writing ? 0.35 : 1)
            .padding(.horizontal, 4)
            .frame(maxHeight: .infinity)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(writing)
        .help("Dictating: click to finish, Esc cancels")
        .accessibilityLabel("Finish dictation")
        .toyIsland(.pilot)
    }
}

/// The top bar's words: one line, the newest in view, the oldest cut at the front.
struct DictationBarWords: View {
    @Environment(\.style) private var style
    let overlay: DictationOverlay

    var body: some View {
        let shown = overlay.shown.map(\.text).joined(separator: " ")
        Text(shown.isEmpty ? "Listening…" : shown)
            .foregroundStyle(shown.isEmpty ? style.color(\.text3) : style.color(\.text))
            .lineLimit(1).truncationMode(.head)
            // Each word that comes in is a reveal step under an animation: unanimated here, or the bar redraws at the
            // display's rate while Sven speaks.
            .transaction { $0.animation = nil }
    }
}

/// The pill's round buttons: ✕ quiet, ✓ white.
struct DictationCircle: View {
    let symbol: String
    let light: Bool

    var body: some View {
        Image(systemName: symbol).font(.system(size: 8, weight: .heavy)).foregroundStyle(light ? .black : .white)
            .frame(width: 18, height: 18).background(Circle().fill(.white.opacity(light ? 1 : 0.2)))
    }
}

extension DictationOverlay {
    /// The waveform's colour this take: Plain draws `plain` (the pill's white, the bar's ink), Theme the theme's signal
    /// colour, Custom the one picked.
    func waveColour(plain: Color) -> Color { setup.waveColour(plain: plain) }
}

/// The microphone's last readings as bars of dots: a dot each while it is quiet.
struct DictationWave: View {
    static let white = Color.white.opacity(0.92)
    let levels: [Double]
    let colour: Color

    var body: some View {
        HStack(spacing: 2) {
            ForEach(levels.indices, id: \.self) { i in
                Capsule().fill(colour).frame(width: 2.5, height: 2.5 + 13 * levels[i])
            }
        }
        // Unanimated: ten readings a second already move, and an animation would redraw at the display's rate.
        .frame(height: 18)
        .accessibilityHidden(true)
    }
}

/// A dark toast, one line of white words.
struct DictationToast<Content: View>: View {
    @Environment(\.ink) private var ink
    @ViewBuilder let content: Content

    var body: some View {
        content
            .font(ink.ui(13, .medium)).foregroundStyle(.white)
            .padding(.horizontal, 14).frame(height: 32)
            .dictationSurface(RoundedRectangle(cornerRadius: 16, style: .continuous))
    }
}

/// After a cancel: the words can come back with Undo, typed into the app in front.
struct DictationRecoverToast: View {
    @Environment(\.ink) private var ink
    let overlay: DictationOverlay

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.yellow).font(.system(size: 12))
                Text("You can recover your cancelled transcript").font(ink.ui(13, .semibold)).foregroundStyle(.white)
                Spacer(minLength: 12)
                Button { overlay.closeToast() } label: {
                    Image(systemName: "xmark").font(.system(size: 9, weight: .bold)).foregroundStyle(.white.opacity(0.8))
                        .frame(width: 22, height: 22).overlay(Circle().strokeBorder(.white.opacity(0.35), lineWidth: 1))
                }
                .accessibilityLabel("Close")
            }
            Text("Undo types what you said where you are typing now.").font(ink.ui(12)).foregroundStyle(.white.opacity(0.6))
            HStack {
                Spacer()
                Button { overlay.undo() } label: {
                    Text("Undo").font(ink.ui(13, .semibold)).foregroundStyle(.black)
                        .padding(.horizontal, 12).frame(height: 26).background(Capsule().fill(.white.opacity(0.92)))
                }
            }
        }
        .buttonStyle(.plain)
        .padding(14)
        .frame(width: 380)
        .dictationSurface(RoundedRectangle(cornerRadius: 16, style: .continuous))
    }
}

extension View {
    /// The overlay's dark face: near-black, a hairline edge, a soft shadow drawn with the shape alone, so what changes
    /// inside never redraws it.
    func dictationSurface(_ shape: some InsettableShape) -> some View {
        background(shape.fill(.black.opacity(0.88)).shadow(color: .black.opacity(0.3), radius: 6, y: 2))
            .overlay(shape.strokeBorder(.white.opacity(0.12), lineWidth: 1))
    }
}
