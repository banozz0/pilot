import AppKit
import ImageIO
import Observation
import OSLog
import PilotCore
import SwiftUI

private let nowLog = Logger(subsystem: "dev.banozz.pilot", category: "now-playing")

/// The Now playing widget's data (`"data": {"nowPlaying": true}`, Sven Q726, Q727): what the Mac plays, as Control
/// Centre's Now Playing knows it (Music, Spotify, a browser tab, any app), its cover and its controls, drawn by Pilot.
/// pilot-media's `watch` (Helpers/pilot-media) reads it: one child for every placement that shows, started with the first
/// and stopped with the last, printing what plays each time MediaRemote says it changed, and its artwork when that
/// changes, kept here once as a thumbnail. Between reads the progress line runs on here; a read is asked at the track's
/// end and every minute besides, from the running child, should a change go untold. Its controls are MediaRemote's
/// commands sent by that child, never a key (ADR 0001): Pilot's media.* actions post the keyboard's media keys. The
/// Widgets page's preview reads once (`info`) and starts nothing.
@Observable @MainActor
final class NowPlaying {
    static let shared = NowPlaying()

    struct Track: Equatable {
        var title: String, artist = "", album = "", app = "", playing = false
        var duration: Double?, elapsed = 0.0
        /// When `elapsed` was read: the progress runs on from it while playing.
        var at = Date()
        /// Its artwork's id, nil without artwork.
        var art: String?

        /// How far in at `now`, never past its end.
        func position(at now: Date) -> Double {
            let run = playing ? elapsed + now.timeIntervalSince(at) : elapsed
            return duration.map { min(run, $0) } ?? run
        }
    }

    enum Command: String { case toggle, next, previous }

    /// What plays, nil when nothing has played (or nothing could be read).
    var track: Track?
    /// Why nothing can be read: no helper in this build.
    var problem: String?
    /// The one artwork kept, by its id: the track's while the ids match.
    private var cover: (id: String, image: NSImage)?

    /// The track's artwork, nil until it came or without one.
    var art: NSImage? { cover.flatMap { $0.id == track?.art ? $0.image : nil } }

    @ObservationIgnored private var session: ChildProcess.Session?
    @ObservationIgnored private var watchers = 0
    @ObservationIgnored private var ask: Task<Void, Never>?
    @ObservationIgnored private var restarts = 0
    /// Each child's number: a line or an end from one stopped since is dropped, so a stopped child's late end never ends
    /// the one started after it.
    @ObservationIgnored private var generation = 0

    init(track: Track? = nil, art: NSImage? = nil, problem: String? = nil) {
        self.track = track
        self.problem = problem
        if let art, let id = track?.art { cover = (id, art) }
    }

    /// A thumbnail's longest side in pixels: a Square tile's cover on a Retina screen.
    nonisolated static let largest = 480

    // MARK: Reading

    /// Holds the watch while the calling feed runs: the first starts the child, the last one cancelled stops it.
    func watch() async {
        watchers += 1
        if watchers == 1 { start() }
        defer {
            watchers -= 1
            if watchers == 0 { stop() }
        }
        while !Task.isCancelled { try? await Task.sleep(for: .seconds(3600)) }
    }

    private func start() {
        guard Self.helper else { return problem = "Now playing reads through Pilot.app's media helper, missing in this build" }
        generation += 1
        let mine = generation
        let lines: @Sendable (String) -> Void = { text in
            guard let line = Self.parse(text) else { return }
            Task { @MainActor in if NowPlaying.shared.generation == mine { NowPlaying.shared.take(line) } }
        }
        do {
            let child = try ChildProcess.Session("/usr/bin/perl", [BundledMediaControl.script, BundledMediaControl.library, "watch"], lines: lines) { status, said in
                Task { @MainActor in if NowPlaying.shared.generation == mine { NowPlaying.shared.ended(status, said) } }
            }
            session = child
            nowLog.notice("watch started, pid \(child.pid)")
        } catch {
            nowLog.error("watch did not start: \(String(describing: error), privacy: .public)")
        }
    }

    private func stop() {
        ask?.cancel()
        ask = nil
        session?.closeInput()
        session?.stop()
        session = nil
        generation += 1
        restarts = 0
        nowLog.notice("watch stopped")
    }

    /// The child ended while a placement shows: started again after 10 s, three times at most until a line comes.
    private func ended(_ status: Int32, _ said: String) {
        guard session != nil else { return }
        nowLog.error("watch ended (\(status)): \(said, privacy: .public)")
        session = nil
        guard watchers > 0, restarts < 3 else { return }
        restarts += 1
        Task {
            try? await Task.sleep(for: .seconds(10))
            if watchers > 0, session == nil { start() }
        }
    }

    /// A control from a tile: what plays changes here at once, then as the child reads it 0.4 s after.
    func send(_ command: Command) {
        guard track != nil, let session else { return }
        if command == .toggle, var now = track {
            (now.elapsed, now.at, now.playing) = (now.position(at: .now), .now, !now.playing)
            track = now
        }
        session.send(Data((command.rawValue + "\n").utf8))
    }

    /// The Widgets page's look: the watch's while one runs, else one read of its own, nothing started.
    static func preview() async -> NowPlaying {
        if shared.session != nil || !helper { return shared }
        let said = (try? await ChildProcess.run("/usr/bin/perl", [BundledMediaControl.script, BundledMediaControl.library, "info"],
                                                timeout: .seconds(3), limit: 8 << 20)) ?? ""
        let shown = NowPlaying()
        for line in said.split(separator: "\n").compactMap({ parse(String($0)) }) { shown.take(line) }
        return shown
    }

    private static var helper: Bool {
        FileManager.default.fileExists(atPath: BundledMediaControl.library) && FileManager.default.fileExists(atPath: BundledMediaControl.script)
    }

    // MARK: Lines

    /// One line of pilot-media's, read on the child's reading thread: a state, or an artwork made a thumbnail there.
    enum Line: Sendable {
        case state(Said)
        case art(String, CGImage)
    }

    struct Said: Decodable, Sendable {
        var kind: String
        var title, artist, album, app, art, data: String?
        var playing: Bool?
        var duration, elapsed: Double?
    }

    nonisolated static func parse(_ text: String) -> Line? {
        guard let said = try? JSONDecoder().decode(Said.self, from: Data(text.utf8)) else { return nil }
        if said.kind == "art" {
            guard let id = said.art, let data = said.data.flatMap({ Data(base64Encoded: $0) }), let image = thumbnail(data) else { return nil }
            return .art(id, image)
        }
        return said.kind == "state" ? .state(said) : nil
    }

    /// The artwork scaled to `largest` pixels at most, decoded once.
    nonisolated static func thumbnail(_ data: Data) -> CGImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        let options: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceThumbnailMaxPixelSize: largest,
                                        kCGImageSourceCreateThumbnailWithTransform: true, kCGImageSourceShouldCacheImmediately: true]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }

    func take(_ line: Line) {
        switch line {
        case .art(let id, let image):
            cover = (id, NSImage(cgImage: image, size: NSSize(width: image.width, height: image.height)))
        case .state(let said):
            restarts = 0
            problem = nil
            guard let title = said.title, !title.isEmpty else { track = nil; return later() }
            track = Track(title: title, artist: said.artist ?? "", album: said.album ?? "", app: said.app ?? "", playing: said.playing ?? false,
                          duration: said.duration.flatMap { $0 > 0 ? $0 : nil }, elapsed: said.elapsed ?? 0, at: .now, art: said.art)
            later()
        }
    }

    /// The next read asked of the child: at the track's end while it plays, else in a minute.
    private func later() {
        ask?.cancel()
        guard session != nil else { return }
        var wait = 60.0
        if let track, track.playing, let duration = track.duration { wait = min(max(duration - track.position(at: .now), 0) + 0.5, wait) }
        ask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(wait))
            guard !Task.isCancelled else { return }
            self?.session?.send(Data("read\n".utf8))
        }
    }

    /// "1:12", "1:02:09".
    static func clock(_ seconds: Double) -> String {
        let s = max(Int(seconds.rounded(.down)), 0)
        return s >= 3600 ? String(format: "%d:%02d:%02d", s / 3600, s / 60 % 60, s % 60) : String(format: "%d:%02d", s / 60, s % 60)
    }
}

// MARK: - The tile

/// The widget's tile, a layout for each class (Sven, Q727): a Square is the cover filling the tile, the track and the
/// controls over it, its progress a line along the foot (design A); Wide and Large put the cover beside the track, the
/// controls and a timed progress bar under it (B); a Strip is one line, a small cover, the track, play or pause and next,
/// its progress along the bottom edge (C). Nothing playing is the kit's empty state, with no Play: a press then would
/// start a player.
struct NowPlayingPanel: View {
    let player: NowPlaying
    let title: String
    let kit: DeskKit
    let size: Widget.SizeClass

    var body: some View {
        Group {
            if let track = player.track {
                switch size {
                case .square: square(track)
                case .strip: strip(track)
                case .wide, .large: beside(track, large: size == .large)
                }
            } else {
                switch size {
                case .square: emptySquare
                case .strip: panel(strip: true) { stripRow(nil) }
                case .wide, .large: beside(nil, large: size == .large)
                }
            }
        }
        .environment(\.deskKit, kit)
    }

    private var aside: String { player.problem ?? "Play something in any app" }

    /// The kit's panel: the veil inside its hairline edge.
    private func panel<Content: View>(strip: Bool = false, @ViewBuilder _ content: () -> Content) -> some View {
        content()
            .padding(.vertical, strip ? 8 : 12).padding(.horizontal, strip ? 10 : 14)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(kit.veil)
            .overlay(RoundedRectangle(cornerRadius: DeskKit.radius, style: .continuous).strokeBorder(kit.edge, lineWidth: 1))
    }

    // MARK: Square (A)

    private func square(_ track: NowPlaying.Track) -> some View {
        ZStack(alignment: .bottomLeading) {
            // Without a cover its note sits above the words.
            NowPlayingCover(art: player.art, glyph: 40, lift: true)
            LinearGradient(stops: [.init(color: .black.opacity(0), location: 0.3), .init(color: .black.opacity(0.78), location: 1)],
                           startPoint: .top, endPoint: .bottom)
            VStack(alignment: .leading, spacing: 2) {
                Text(track.title).font(kit.sans(14, .semibold)).foregroundStyle(.white)
                if !track.artist.isEmpty { Text(track.artist).font(kit.sans(10.5)).foregroundStyle(.white.opacity(0.72)) }
                HStack(spacing: 6) {
                    NowPlayingControls(player: player, playing: track.playing, side: 28, onCover: true)
                    Spacer(minLength: 0)
                    NowPlayingTime(track: track) { at, _ in Text(at).font(kit.mono(10)).monospacedDigit().foregroundStyle(.white.opacity(0.7)) }
                }
                .padding(.top, 6)
            }
            .lineLimit(1)
            .padding(.horizontal, 14).padding(.bottom, 16)
            NowPlayingLine(track: track, fill: kit.dark ? kit.accent : .white, track2: .white.opacity(0.25), height: 2)
                .padding(.horizontal, 14).padding(.bottom, 9)
        }
        .overlay(alignment: .topLeading) {
            if !track.app.isEmpty || !track.playing {
                Text((track.playing ? track.app : "Paused").uppercased()).font(kit.mono(9)).tracking(0.9).foregroundStyle(.white.opacity(0.75))
                    .lineLimit(1).padding(.horizontal, 6).padding(.vertical, 2)
                    .background(.black.opacity(0.35), in: RoundedRectangle(cornerRadius: 5, style: .continuous))
                    .padding(12)
            }
        }
        .accessibilityElement(children: .contain)
    }

    private var emptySquare: some View {
        panel {
            VStack(alignment: .leading, spacing: 10) {
                DeskKitHead(title: title, meta: nil)
                VStack(spacing: 6) {
                    Image(systemName: "music.note").font(.system(size: 22, weight: .light)).foregroundStyle(kit.text3).accessibilityHidden(true)
                    Text("Nothing playing").font(kit.sans(12.5, .medium)).foregroundStyle(kit.text2)
                    Text(aside).font(kit.sans(10.5)).foregroundStyle(kit.text3).multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .accessibilityElement(children: .combine)
            }
        }
    }

    // MARK: Wide and Large (B)

    private func beside(_ track: NowPlaying.Track?, large: Bool) -> some View {
        panel {
            GeometryReader { box in
                let side = large ? min(box.size.width * 0.42, box.size.height * 0.55, 150) : min(max(box.size.height, 56), box.size.width * 0.4, 150)
                if large {
                    VStack(alignment: .leading, spacing: 12) {
                        HStack(alignment: .top, spacing: 12) {
                            cover(side)
                            VStack(alignment: .leading, spacing: 2) {
                                DeskKitHead(title: title, meta: meta(track))
                                words(track, large: true).padding(.top, 6)
                            }
                        }
                        Spacer(minLength: 0)
                        progress(track)
                        NowPlayingControls(player: player, playing: track?.playing ?? false, side: 34, off: track == nil)
                            .frame(maxWidth: .infinity)
                    }
                } else {
                    HStack(alignment: .top, spacing: 12) {
                        cover(side)
                        VStack(alignment: .leading, spacing: 2) {
                            DeskKitHead(title: title, meta: meta(track))
                            words(track, large: false).padding(.top, 6)
                            Spacer(minLength: 4)
                            HStack(spacing: 8) {
                                NowPlayingControls(player: player, playing: track?.playing ?? false, side: 26, off: track == nil).padding(.leading, -6)
                                progress(track)
                            }
                        }
                    }
                }
            }
        }
    }

    private func cover(_ side: CGFloat) -> some View {
        NowPlayingCover(art: player.track == nil ? nil : player.art, glyph: side * 0.27)
            .frame(width: side, height: side)
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(kit.edge, lineWidth: 1))
    }

    /// The head's meta: the app playing, or Paused.
    private func meta(_ track: NowPlaying.Track?) -> String? {
        guard let track else { return nil }
        return track.playing ? (track.app.isEmpty ? nil : track.app) : "Paused"
    }

    @ViewBuilder private func words(_ track: NowPlaying.Track?, large: Bool) -> some View {
        Text(track?.title ?? "Nothing playing").font(kit.sans(large ? 15 : 14, .semibold)).foregroundStyle(track == nil ? kit.text3 : kit.text)
            .lineLimit(large ? 2 : 1)
        Text(track.map { $0.artist } ?? aside).font(kit.sans(large ? 11.5 : 10.5)).foregroundStyle(large && track != nil ? kit.text2 : kit.text3).lineLimit(1)
        if large, let album = track?.album, !album.isEmpty { Text(album).font(kit.sans(10.5)).foregroundStyle(kit.text3).lineLimit(1) }
    }

    /// The time in, the bar, the time left; a dash and an empty bar with nothing playing.
    private func progress(_ track: NowPlaying.Track?) -> some View {
        HStack(spacing: 6) {
            if let track {
                NowPlayingTime(track: track) { at, left in
                    HStack(spacing: 6) {
                        Text(at)
                        NowPlayingLine(track: track, fill: kit.accent, track2: kit.track, height: 4)
                        if let left { Text(left) }
                    }
                }
            } else {
                Capsule().fill(kit.track).frame(height: 4)
                Text("–")
            }
        }
        .font(kit.mono(9.5)).monospacedDigit().foregroundStyle(kit.text3).lineLimit(1)
    }

    // MARK: Strip (C)

    private func strip(_ track: NowPlaying.Track) -> some View {
        panel(strip: true) { stripRow(track) }
            .overlay(alignment: .bottom) {
                NowPlayingLine(track: track, fill: kit.accent, track2: .clear, height: 2).padding(.horizontal, 14).padding(.bottom, 1)
            }
    }

    private func stripRow(_ track: NowPlaying.Track?) -> some View {
        GeometryReader { box in
            HStack(spacing: 10) {
                cover(min(max(box.size.height, 24), 48))
                VStack(alignment: .leading, spacing: 1) {
                    Text(track?.title ?? "Nothing playing").font(kit.sans(13, .semibold)).foregroundStyle(track == nil ? kit.text3 : kit.text)
                    if let track {
                        NowPlayingTime(track: track) { at, _ in
                            Text([track.artist, at].filter { !$0.isEmpty }.joined(separator: " · "))
                        }
                        .font(kit.sans(10)).foregroundStyle(kit.text3)
                    } else {
                        Text(aside).font(kit.sans(10)).foregroundStyle(kit.text3)
                    }
                }
                .lineLimit(1)
                Spacer(minLength: 0)
                if let track { NowPlayingControls(player: player, playing: track.playing, side: 26, back: false) }
            }
            .frame(maxHeight: .infinity)
        }
    }
}

/// The cover, filling its frame; without one, the kit's track ground with a note on it.
private struct NowPlayingCover: View {
    @Environment(\.deskKit) private var kit
    let art: NSImage?
    let glyph: CGFloat
    /// Its note in the top half, clear of words drawn over the foot.
    var lift = false

    var body: some View {
        if let art {
            Color.clear.overlay { Image(nsImage: art).resizable().interpolation(.high).aspectRatio(contentMode: .fill) }.clipped()
                .accessibilityHidden(true)
        } else {
            ZStack {
                kit.track
                Image(systemName: "music.note").font(.system(size: glyph, weight: .light)).foregroundStyle(kit.text3)
                    .frame(maxHeight: .infinity, alignment: lift ? .top : .center).padding(.top, lift ? 38 : 0)
            }
            .accessibilityHidden(true)
        }
    }
}

/// Previous, play or pause, next: play or pause a filled circle `side` across, the others its glyph alone. `back` false
/// leaves previous out (a Strip's); `off` shows them dimmed and dead (nothing playing).
private struct NowPlayingControls: View {
    @Environment(\.deskKit) private var kit
    let player: NowPlaying
    let playing: Bool
    var side: CGFloat = 26
    var onCover = false, back = true, off = false

    var body: some View {
        HStack(spacing: 4) {
            if back { button("backward.fill", "Previous track", .previous, main: false) }
            button(playing ? "pause.fill" : "play.fill", playing ? "Pause" : "Play", .toggle, main: true)
            button("forward.fill", "Next track", .next, main: false)
        }
        .disabled(off)
        .opacity(off ? 0.35 : 1)
    }

    private func button(_ symbol: String, _ label: String, _ command: NowPlaying.Command, main: Bool) -> some View {
        let glyph: Color = main ? (onCover ? Color(white: 0.07) : kit.dark ? .black : .white) : onCover ? .white.opacity(0.88) : kit.text2
        return Button { player.send(command) } label: {
            Image(systemName: symbol).font(.system(size: main ? side * 0.42 : 13, weight: .semibold)).foregroundStyle(glyph)
                .frame(width: main ? side : 26, height: main ? side : 26)
                .background { if main { Circle().fill(onCover ? .white.opacity(0.92) : kit.text) } }
                .contentShape(Circle())
        }
        .buttonStyle(NowPlayingPress())
        .accessibilityLabel(label)
        .help(label)
    }
}

/// Pressed in to 0.92, as the kit's tiles press.
private struct NowPlayingPress: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.scaleEffect(configuration.isPressed ? 0.92 : 1)
            .animation(.spring(duration: 0.2, bounce: 0), value: configuration.isPressed)
    }
}

/// The time in and the time left, ticking each second while it plays, still while it is paused: the one part of the tile
/// that redraws between reads.
private struct NowPlayingTime<Content: View>: View {
    let track: NowPlaying.Track
    @ViewBuilder let content: (String, String?) -> Content

    var body: some View {
        if track.playing {
            TimelineView(.periodic(from: track.at, by: 1)) { context in shown(context.date) }
        } else {
            shown(track.at)
        }
    }

    private func shown(_ now: Date) -> Content {
        let at = track.position(at: now)
        return content(NowPlaying.clock(at), track.duration.map { "−" + NowPlaying.clock($0 - at) })
    }
}

/// The progress line: its share filled, run on each second while it plays; empty with no length known.
private struct NowPlayingLine: View {
    let track: NowPlaying.Track
    let fill: Color, track2: Color
    let height: CGFloat

    var body: some View {
        if track.playing, track.duration != nil {
            TimelineView(.periodic(from: track.at, by: 1)) { context in bar(context.date) }
        } else {
            bar(track.at)
        }
    }

    private func bar(_ now: Date) -> some View {
        let share = track.duration.map { $0 > 0 ? min(max(track.position(at: now) / $0, 0), 1) : 0 } ?? 0
        return GeometryReader { box in
            Capsule().fill(track2).overlay(alignment: .leading) { Capsule().fill(fill).frame(width: box.size.width * share) }
        }
        .frame(height: height)
        .frame(minWidth: 20)
        .accessibilityHidden(true)
    }
}
