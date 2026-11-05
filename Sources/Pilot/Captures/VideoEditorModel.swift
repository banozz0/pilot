import AVFoundation
import Observation
import OSLog
import PilotCore

/// One video editor's state (P71; A, Sven, Q806): the recording, its edit with undo and redo, the preview's player and
/// playhead, the timeline's pictures, the inspector's tab, the picked zoom or blur, crop mode and the export. Everything here goes when the editor closes (`close`): the player
/// lets its item go, the tasks stop, the pictures are dropped.
@Observable @MainActor
final class VideoEditorModel {
    let url: URL
    @ObservationIgnored let asset: AVURLAsset
    @ObservationIgnored let player = AVPlayer()

    private(set) var loaded = false
    private(set) var failed: String?
    /// The recording's frame, pixels.
    private(set) var size: CGSize = .zero
    private(set) var edit = VideoEdit(duration: 0)
    private(set) var pointer: CursorTrack?
    /// The timeline's pictures, evenly through the recording.
    private(set) var strip: [CGImage] = []
    /// A frame of the recording: the Blurred tiles' picture and a capture fill's.
    private(set) var poster: CGImage?
    /// The recording's time under the playhead, seconds.
    private(set) var playhead: Double = 0
    private(set) var playing = false
    /// The preview's canvas, pixels: what the player draws, for its place on the stage.
    private(set) var canvas: CGSize = CGSize(width: 16, height: 9)
    /// What is picked on the lanes, one at a time: a zoom opens the inspector's Zoom tab, a blur (R8) the Clip tab and
    /// its box on the stage.
    private(set) var picked: Pick? {
        didSet {
            guard let picked, picked != oldValue else { return }
            switch picked {
            case .zoom: tab = .zoom
            case .blur: tab = .clip
            }
        }
    }
    enum Pick: Equatable { case zoom(UUID), blur(UUID) }
    /// The picked zoom.
    var selected: UUID? {
        get { if case .zoom(let id) = picked { id } else { nil } }
        set { if let newValue { picked = .zoom(newValue) } else if selected != nil { picked = nil } }
    }
    /// The picked blur.
    var pickedBlurID: UUID? {
        get { if case .blur(let id) = picked { id } else { nil } }
        set { if let newValue { picked = .blur(newValue) } else if pickedBlurID != nil { picked = nil } }
    }
    /// The part under the playhead, kept apart from the playhead so playback redraws the Part group only on a new part.
    private(set) var partIndex = 0
    /// R7: where the pointer stood still or left the frame, read from its track once.
    private(set) var stillSpans: [ClosedRange<Double>] = []
    /// The inspector's tab (A): Clip, Zoom, Backdrop or Export.
    var tab: InspectorTab = .clip
    private(set) var cropping = false
    /// The crop being dragged, a fraction of the frame from its top left.
    private(set) var cropDraft = VideoEdit.wholeFrame
    /// Whether the inspector shows the backdrop (B's key and the films' word for it); off goes back to Clip.
    var panelOpen: Bool {
        get { tab == .backdrop }
        set { tab = newValue ? .backdrop : (tab == .backdrop ? .clip : tab) }
    }
    var format: VideoFormat = .h264
    var exportSize: VideoSize = .full
    /// The export's progress, 0 to 1, while one runs; its format, for the bar's "Exporting MP4".
    private(set) var progress: Double?
    private(set) var exportingFormat: VideoFormat?
    private(set) var hint: String?

    @ObservationIgnored var closeEditor: () -> Void = {}
    /// Tells how an export ended, with Show for the file; HUD's tip in the app.
    @ObservationIgnored var tell: (String, URL?) -> Void = { _, _ in }
    @ObservationIgnored private var undoStack: [VideoEdit] = []
    @ObservationIgnored private var redoStack: [VideoEdit] = []
    @ObservationIgnored private var gesture = false
    @ObservationIgnored private var ticker: Any?
    @ObservationIgnored private var planning: Task<Void, Never>?
    @ObservationIgnored private var exporting: Task<Void, Never>?
    @ObservationIgnored private var saying: Task<Void, Never>?
    @ObservationIgnored private var discardArmed = false
    @ObservationIgnored private let context = VideoPlan.context()
    /// A picture fill's picture for the preview, kept while the fill and its blur stay.
    @ObservationIgnored private var picture: (fill: Backdrop.Fill, blur: Backdrop.Blur, image: CGImage?)?
    /// The preview's canvas at most this many pixels on its longer side: the export draws full size.
    static let previewLongest: CGFloat = 1600
    static let stripCount = 24

    enum InspectorTab: String, CaseIterable { case clip, zoom, backdrop, export }

    init(url: URL) {
        self.url = url
        asset = AVURLAsset(url: url, options: [AVURLAssetPreferPreciseDurationAndTimingKey: true])
    }

    // MARK: Loading and closing

    /// Reads the recording's size and length, its pointer track, the zooms its clicks suggest, then the preview and the
    /// timeline's pictures. `pointerFolder` is where Recorder keeps the tracks.
    func load(pointerFolder: URL) async {
        do {
            guard let track = try await asset.loadTracks(withMediaType: .video).first else { failed = "This file has no picture."; return }
            let natural = try await track.load(.naturalSize)
            let duration = try await asset.load(.duration).seconds
            guard natural.width > 0, natural.height > 0, duration.isFinite, duration > 0 else { failed = "This recording is empty."; return }
            let url = self.url
            // A copy Pilot already drew the pointer into (Q821) has no track of its own: its name would find the recording's.
            let pointer = await Task.detached(priority: .userInitiated) {
                RecordingHandout.marked(url) ? nil : CursorTrack.load(for: url, in: pointerFolder)
            }.value
            size = natural
            self.pointer = pointer
            edit = VideoEdit(duration: duration, zooms: ZoomSegment.auto(from: pointer?.clicks ?? [], duration: duration))
            // A new recording's own pointer settings (Show clicks turns Click ring on); off for an older one.
            edit.pointer = pointer?.look ?? PointerLook()
            // R12: the look picked for every video, over the recording's own pointer settings.
            if let look = BackdropLibrary.shared.everyRecording { edit.apply(look) }
            stillSpans = pointer?.stillParts(duration: duration) ?? []
            let item = AVPlayerItem(asset: asset)
            item.audioTimePitchAlgorithm = .spectral
            player.replaceCurrentItem(with: item)
            player.actionAtItemEnd = .pause
            loaded = true
            refresh()
            VideoEditor.log.notice("video editor: \(Int(natural.width))×\(Int(natural.height)), \(RecordingClock.label(duration), privacy: .public), \(pointer?.clicks.count ?? 0) clicks, \(self.edit.zooms.count) zooms")
            await loadPictures(duration: duration)
        } catch {
            failed = "The recording could not be read: \(error.localizedDescription)"
            VideoEditor.log.error("video editor: \(String(describing: error), privacy: .public)")
        }
    }

    /// The timeline's small pictures and the poster, read by AVFoundation off the main thread.
    private func loadPictures(duration: Double) async {
        let small = AVAssetImageGenerator(asset: asset)
        small.maximumSize = CGSize(width: 160, height: 160)
        small.appliesPreferredTrackTransform = true
        let times = (0..<Self.stripCount).map { CMTime(seconds: duration * (Double($0) + 0.5) / Double(Self.stripCount), preferredTimescale: 600) }
        var pictures: [CGImage] = []
        for await result in small.images(for: times) {
            if let image = try? result.image { pictures.append(image) }
            if Task.isCancelled || !loaded { return }
        }
        strip = pictures
        let big = AVAssetImageGenerator(asset: asset)
        big.maximumSize = CGSize(width: 1600, height: 1600)
        big.appliesPreferredTrackTransform = true
        poster = try? await big.image(at: CMTime(seconds: min(0.5, duration / 2), preferredTimescale: 600)).image
        if edit.backdrop?.fill == .capture { refresh() }
    }

    /// Lets everything go: the export stops (its file removed), the player its item, the pictures.
    func close() {
        exporting?.cancel()
        exporting = nil
        planning?.cancel()
        planning = nil
        pause()
        player.replaceCurrentItem(with: nil)
        loaded = false
        strip = []
        poster = nil
        picture = nil
        undoStack = []
        redoStack = []
    }

    // MARK: The preview

    /// The preview's composition made again for the edit (or the whole frame while cropping), off the main thread; a
    /// newer change cancels an older one, so a slider's moves coalesce.
    private func refresh(live: Bool = false) {
        guard loaded else { return }
        planning?.cancel()
        let shown = cropping ? VideoEdit(duration: edit.duration) : edit
        let size = self.size, pointer = self.pointer, asset = self.asset, context = self.context
        let ring = CursorEffectColours.of(Look.shared.themeID)
        let full = VideoLayout(source: size, edit: shown).canvas
        let out = min(1, Self.previewLongest / max(full.width, full.height, 1))
        planning = Task { @MainActor in
            // A drag's moves wait a beat, so only the one it rests on is drawn.
            if live { try? await Task.sleep(for: .milliseconds(60)) }
            guard !Task.isCancelled else { return }
            let picture = await previewPicture(shown.backdrop)
            guard !Task.isCancelled else { return }
            let plan = await Task.detached(priority: .userInitiated) {
                VideoPlan(edit: shown, pointer: pointer, source: size, out: out, exported: false, picture: picture?.value, fine: false, ring: ring)
            }.value
            guard !Task.isCancelled, let composition = try? await VideoPlan.composition(plan, over: asset, context: context),
                  !Task.isCancelled, let item = player.currentItem else { return }
            item.videoComposition = composition
            canvas = plan.layout.canvas
            if !playing { show(playhead) }
        }
    }

    /// The picture fill's picture at the preview's size, read and blurred once while the fill and its blur stay.
    private func previewPicture(_ backdrop: Backdrop?) async -> Unchecked<CGImage>? {
        guard let backdrop, backdrop.fill.picture else { return nil }
        if let picture, picture.fill == backdrop.fill, picture.blur == backdrop.shownBlur { return picture.image.map(Unchecked.init) }
        let image = await Self.picture(backdrop, poster: poster, side: Int(Self.previewLongest))
        picture = (backdrop.fill, backdrop.shownBlur, image?.value)
        return image
    }

    /// A picture fill's picture at most `side` pixels a side, the recording's poster standing for a capture fill.
    nonisolated static func picture(_ backdrop: Backdrop, poster: CGImage?, side: Int) async -> Unchecked<CGImage>? {
        let poster = poster.map(Unchecked.init)
        return await Task.detached(priority: .userInitiated) { () -> Unchecked<CGImage>? in
            guard let capture = poster?.value ?? (backdrop.fill == .capture ? nil : blank) else { return nil }
            return MarkupRenderer.backdropPicture(backdrop, capture: capture, side: side).map(Unchecked.init)
        }.value
    }

    /// A one-pixel stand-in for a capture fill before the poster is read.
    nonisolated private static var blank: CGImage? {
        CGContext(data: nil, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                  bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue)?.makeImage()
    }

    // MARK: Playing

    /// The export's length and the playhead's place in it, seconds.
    var length: Double { edit.length }
    var outputTime: Double { max(0, min(edit.length, edit.output(at: playhead))) }

    func togglePlay() { playing ? pause() : play() }

    /// Plays the kept parts, each at its speed, from the first when the playhead is past the last; cut parts are skipped.
    func play() {
        guard loaded, let item = player.currentItem else { return }
        let pieces = edit.pieces
        guard let first = pieces.first, let last = pieces.last else { return hint("Nothing is kept: every part is cut") }
        guard let go = edit.playing(from: playhead >= last.end - 0.05 ? first.start : playhead) else { return }
        if go.time != playhead { show(go.time) }
        item.forwardPlaybackEndTime = CMTime(seconds: last.end, preferredTimescale: 600)
        player.rate = Float(go.rate)
        playing = true
        ticker = player.addPeriodicTimeObserver(forInterval: CMTime(value: 1, timescale: 30), queue: .main) { [weak self] time in
            MainActor.assumeIsolated { self?.tick(time.seconds) }
        }
    }

    func pause() {
        player.pause()
        playing = false
        if let ticker { player.removeTimeObserver(ticker) }
        ticker = nil
    }

    /// Playback's step: past a cut it jumps to the next kept part, and each part plays at its own rate.
    private func tick(_ t: Double) {
        guard playing, t.isFinite else { return }
        playhead = t
        syncPart()
        guard player.rate != 0, let go = edit.playing(from: t) else { return pause() }
        if go.time > t + 0.02 {
            playhead = go.time
            syncPart()
            player.seek(to: CMTime(seconds: go.time, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
        }
        if player.rate != Float(go.rate) { player.rate = Float(go.rate) }
    }

    /// The playhead to the recording's `t`, the preview showing that frame; `exact` false while scrubbing.
    func show(_ t: Double, exact: Bool = true) {
        playhead = min(max(0, t), edit.duration)
        syncPart()
        let tolerance = exact ? CMTime.zero : CMTime(value: 1, timescale: 20)
        player.seek(to: CMTime(seconds: playhead, preferredTimescale: 600), toleranceBefore: tolerance, toleranceAfter: tolerance)
    }

    func scrub(to t: Double, done: Bool) {
        if playing { pause() }
        show(t, exact: done)
    }

    // MARK: Changes

    /// One change, one undo step; in a drag (`live`) only its first move takes a step. Any change drops what redo held.
    private func change(live: Bool = false, _ body: (inout VideoEdit) -> Void) {
        var next = edit
        body(&next)
        guard next != edit else { return }
        if !live || !gesture { undoStack.append(edit) }
        redoStack = []
        if undoStack.count > 100 { undoStack.removeFirst() }
        gesture = live
        apply(next, live: live)
        discardArmed = false
    }

    /// `next` becomes the edit; the preview is drawn again when what it shows changed.
    private func apply(_ next: VideoEdit, live: Bool = false) {
        let redraw = next.crop != edit.crop || next.backdrop != edit.backdrop || next.zooms != edit.zooms || next.blurs != edit.blurs
            || next.pointer != edit.pointer || next.shape != edit.shape || next.motionBlur != edit.motionBlur
        if playing, let go = next.playing(from: playhead), player.rate != Float(go.rate) { player.rate = Float(go.rate) }
        edit = next
        syncPart()
        if redraw { refresh(live: live) }
    }

    /// A drag let go: the next change is a new undo step.
    func settle() { gesture = false }

    var canUndo: Bool { !undoStack.isEmpty }
    var canRedo: Bool { !redoStack.isEmpty }

    func undo() {
        guard let last = undoStack.popLast() else { return }
        redoStack.append(edit)
        restore(last)
    }

    /// R11: ⇧⌘Z brings back the edit the last undo took away.
    func redo() {
        guard let next = redoStack.popLast() else { return }
        undoStack.append(edit)
        restore(next)
    }

    private func restore(_ next: VideoEdit) {
        gesture = false
        apply(next)
        if let selected, zoom(selected) == nil { self.selected = nil }
        if let pickedBlurID, blur(pickedBlurID) == nil { self.pickedBlurID = nil }
    }

    func trim(in a: Double? = nil, out b: Double? = nil, live: Bool = false) {
        change(live: live) { $0.trim(in: a, out: b) }
        if a != nil { show(edit.trimIn, exact: !live) } else if b != nil { show(edit.trimOut, exact: !live) }
    }

    /// I and O: the trim's start or end at the playhead.
    func trimAtPlayhead(start: Bool) { start ? trim(in: playhead) : trim(out: playhead) }

    func setSpeed(_ speed: Double) { change { $0.speed = speed } }

    // MARK: Parts (R5, R6, R7)

    /// The part under the playhead, its place among them from one, and how many there are.
    var currentPart: (part: ClipPart, index: Int, count: Int) {
        let i = min(partIndex, edit.parts.count - 1)
        return (edit.parts[i], i + 1, edit.parts.count)
    }

    private func syncPart() {
        let i = edit.part(at: playhead)
        if i != partIndex { partIndex = i }
    }

    /// S: the part under the playhead split there.
    func split() {
        var next = edit
        guard next.split(at: playhead) else { return hint("Too close to a split to split again") }
        change { $0 = next }
    }

    /// X: the part under the playhead cut out of the export, or kept again.
    func toggleCut() {
        let i = partIndex
        change { $0.setCut(i, !$0.parts[i].cut) }
    }

    /// The part under the playhead at its own speed, or the clip's (nil).
    func setPartSpeed(_ speed: Double?) {
        let i = partIndex
        change { $0.setSpeed(ofPart: i, speed) }
    }

    /// R7's suggestions inside the trim and not yet cut.
    var stillParts: [ClosedRange<Double>] {
        stillSpans.filter { span in
            span.upperBound > edit.trimIn && span.lowerBound < edit.trimOut && !edit.isCut((span.lowerBound + span.upperBound) / 2)
        }
    }

    /// R7: every suggested still part cut, one undo step.
    func cutStillParts() {
        let spans = stillParts
        guard !spans.isEmpty else { return }
        change { $0.cut(spans) }
        hint("Cut \(spans.count) still part\(spans.count == 1 ? "" : "s")")
    }

    /// R1–R4 (T29): how the export draws the pointer, one undo step a change.
    func setPointer(_ body: (inout PointerLook) -> Void) { change { body(&$0.pointer) } }

    func setBackdrop(_ backdrop: Backdrop?) { change { $0.backdrop = backdrop } }
    /// R9: a shape's frame is the shape; the backdrop's own ratio waits, unused, for Auto.
    func setShape(_ shape: VideoShape) { change { $0.shape = shape } }
    func setMotionBlur(_ on: Bool) { change { $0.motionBlur = on } }
    /// R12: a saved look on this recording, one undo step.
    func applyPreset(_ preset: VideoPreset) { change { $0.apply(preset) } }
    func previewBackdrop(_ backdrop: Backdrop) { change(live: true) { $0.backdrop = backdrop } }

    // MARK: Zooms

    /// A two-second zoom at `t` (or as much as fits between the zooms round it), picked; nothing when `t` is inside one,
    /// "No room" when the gap is shorter than a zoom can be.
    func addZoom(at t: Double) {
        guard !edit.zooms.contains(where: { t >= $0.start && t < $0.end }) else { return }
        let previous = edit.zooms.filter { $0.end <= t }.map(\.end).max() ?? 0
        let next = edit.zooms.filter { $0.start > t }.map(\.start).min() ?? edit.duration
        guard next - previous >= ZoomSegment.shortest else { return hint("No room for a zoom here") }
        let start = max(previous, min(t, next - ZoomSegment.shortest))
        let end = min(next, start + 2)
        guard end - start >= ZoomSegment.shortest else { return hint("No room for a zoom here") }
        let zoom = ZoomSegment(start: start, end: end)
        change { $0.zooms = ($0.zooms + [zoom]).sorted { $0.start < $1.start } }
        selected = zoom.id
    }

    /// The zoom moved to start at `start`, between its neighbours, its length kept.
    func moveZoom(_ id: UUID, to start: Double, live: Bool = true) {
        guard let (i, z) = zoom(id) else { return }
        let (lo, hi) = room(around: i)
        let a = min(max(lo, start), hi - z.length)
        change(live: live) { $0.zooms[i].start = a; $0.zooms[i].end = a + z.length }
    }

    /// One edge of the zoom moved, between its neighbours, never shorter than `ZoomSegment.shortest`.
    func stretchZoom(_ id: UUID, start: Double? = nil, end: Double? = nil, live: Bool = true) {
        guard let (i, z) = zoom(id) else { return }
        let (lo, hi) = room(around: i)
        change(live: live) {
            if let start { $0.zooms[i].start = min(max(lo, start), z.end - ZoomSegment.shortest) }
            if let end { $0.zooms[i].end = max(min(hi, end), z.start + ZoomSegment.shortest) }
        }
    }

    func setLevel(_ level: Double) {
        guard let id = selected, let (i, _) = zoom(id) else { return }
        change { $0.zooms[i].level = min(ZoomSegment.levels.upperBound, max(ZoomSegment.levels.lowerBound, level)) }
    }

    /// The picked zoom's focus: a place on the cropped frame, or nil to follow the pointer.
    func setFocus(_ focus: CGPoint?) {
        guard let id = selected, let (i, _) = zoom(id) else { return }
        change { $0.zooms[i].focus = focus }
    }

    /// ⌫: the picked zoom or blur deleted.
    func deleteSelected() {
        switch picked {
        case .zoom(let id): change { $0.zooms.removeAll { $0.id == id } }
        case .blur(let id): change { $0.blurs.removeAll { $0.id == id } }
        case nil: return
        }
        picked = nil
    }

    private func zoom(_ id: UUID) -> (Int, ZoomSegment)? {
        edit.zooms.firstIndex { $0.id == id }.map { ($0, edit.zooms[$0]) }
    }

    /// The room the zoom at `i` has: from the end of the one before to the start of the one after.
    private func room(around i: Int) -> (Double, Double) {
        let sorted = edit.zooms
        let lo = i > 0 ? sorted[i - 1].end : 0
        let hi = i + 1 < sorted.count ? sorted[i + 1].start : edit.duration
        return (lo, hi)
    }

    // MARK: Blurs (R8)

    /// A two-second blur at `t` over the middle of the frame, picked, its box on the stage to move over what to hide.
    func addBlur(at t: Double) {
        let start = min(max(0, t), max(0, edit.duration - BlurSpan.shortest))
        let blur = BlurSpan(start: start, end: min(edit.duration, start + 2))
        change { $0.blurs = ($0.blurs + [blur]).sorted { $0.start < $1.start } }
        pickedBlurID = blur.id
    }

    var pickedBlur: (blur: BlurSpan, index: Int, count: Int)? {
        guard let id = pickedBlurID, let (i, b) = blur(id) else { return nil }
        return (b, i + 1, edit.blurs.count)
    }

    /// The blur moved to start at `start`, inside the recording, its length kept.
    func moveBlur(_ id: UUID, to start: Double, live: Bool = true) {
        guard let (i, b) = blur(id) else { return }
        let a = min(max(0, start), edit.duration - b.length)
        change(live: live) { $0.blurs[i].start = a; $0.blurs[i].end = a + b.length }
    }

    /// One edge of the blur moved, inside the recording, never shorter than `BlurSpan.shortest`.
    func stretchBlur(_ id: UUID, start: Double? = nil, end: Double? = nil, live: Bool = true) {
        guard let (i, b) = blur(id) else { return }
        let duration = edit.duration
        change(live: live) {
            if let start { $0.blurs[i].start = min(max(0, start), b.end - BlurSpan.shortest) }
            if let end { $0.blurs[i].end = max(min(duration, end), b.start + BlurSpan.shortest) }
        }
    }

    /// The picked blur's area, a fraction of the whole frame; a drag's moves share one undo step.
    func setBlurArea(_ area: CGRect) {
        guard let id = pickedBlurID, let (i, _) = blur(id) else { return }
        change(live: true) { $0.blurs[i].area = BlurSpan.fitted(area) }
    }

    private func blur(_ id: UUID) -> (Int, BlurSpan)? {
        edit.blurs.firstIndex { $0.id == id }.map { ($0, edit.blurs[$0]) }
    }

    /// Where a part of the whole frame (`area`, a fraction of it) shows on the preview at the playhead, as a fraction of
    /// the canvas: through the crop, the camera's zoom and the backdrop's spot. `scale` is how much a fraction of the
    /// frame grows on the canvas, each way, for drags back the other way.
    func shown(_ area: CGRect) -> (rect: CGRect, scale: CGSize) {
        let layout = VideoLayout(source: size, edit: edit)
        let spot = CGRect(x: layout.spot.minX / max(layout.canvas.width, 1), y: layout.spot.minY / max(layout.canvas.height, 1),
                          width: layout.spot.width / max(layout.canvas.width, 1), height: layout.spot.height / max(layout.canvas.height, 1))
        let view = edit.camera(at: playhead, cursor: pointer, window: layout.window)
        let crop = edit.crop ?? VideoEdit.wholeFrame
        func place(_ p: CGPoint) -> CGPoint {
            let c = edit.inCrop(p)
            return CGPoint(x: spot.minX + (c.x - view.minX) / view.width * spot.width, y: spot.minY + (c.y - view.minY) / view.height * spot.height)
        }
        let a = place(CGPoint(x: area.minX, y: area.minY)), b = place(CGPoint(x: area.maxX, y: area.maxY))
        let scale = CGSize(width: spot.width / max(view.width * crop.width, 0.0001), height: spot.height / max(view.height * crop.height, 0.0001))
        return (CGRect(x: a.x, y: a.y, width: b.x - a.x, height: b.y - a.y), scale)
    }

    // MARK: Crop

    func startCrop() {
        guard loaded, !cropping else { return }
        pause()
        cropDraft = edit.crop ?? VideoEdit.wholeFrame
        cropping = true
        refresh()
    }

    func dragCrop(_ r: CGRect) { cropDraft = VideoEdit.fitted(r) ?? VideoEdit.wholeFrame }

    /// Done keeps the crop, Cancel the one before; either way back to the edit.
    func finishCrop(keep: Bool) {
        guard cropping else { return }
        cropping = false
        if keep { change { $0.crop = VideoEdit.fitted(cropDraft) } }
        refresh()
    }

    func wholeFrame() { cropDraft = VideoEdit.wholeFrame }

    /// The Clip tab's Whole frame: the crop gone, one undo step.
    func uncrop() { change { $0.crop = nil } }

    // MARK: Export

    /// The export's size in pixels at the picked size.
    var exportPixels: CGSize { exportSize.pixels(VideoLayout(source: size, edit: edit).canvas, format: format, shape: edit.shape) }

    /// Writes the edit beside the recording, off the main thread, its progress in the bar; Cancel or closing stops it.
    func export() {
        guard loaded, progress == nil, !cropping else { return }
        guard edit.length > 0 else { return hint("Nothing is kept: every part is cut") }
        pause()
        let target = VideoExport.destination(for: url, format: format)
        let asset = self.asset, edit = self.edit, pointer = self.pointer, format = self.format, size = self.exportSize, poster = self.poster
        let full = VideoLayout(source: self.size, edit: edit).canvas
        progress = 0
        exportingFormat = format
        exporting = Task { @MainActor [weak self] in
            let clock = ContinuousClock(), began = clock.now
            do {
                var picture: Unchecked<CGImage>?
                if let backdrop = edit.backdrop { picture = await Self.picture(backdrop, poster: poster, side: Int(max(full.width, full.height))) }
                try await VideoExport.run(asset, edit: edit, pointer: pointer, picture: picture?.value, format: format, size: size, to: target) { p in
                    Task { @MainActor in if self?.exporting != nil { self?.progress = p } }
                }
                let took = (clock.now - began) / .seconds(1)
                let bytes = (try? target.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
                VideoEditor.log.notice("video export: \(target.lastPathComponent, privacy: .public), \(RecordingClock.label(edit.length), privacy: .public), \(bytes) bytes in \(took, format: .fixed(precision: 2)) s")
                self?.exported(target, bytes: bytes)
            } catch is CancellationError {
                self?.ended("Export cancelled")
            } catch {
                VideoEditor.log.error("video export: \(String(describing: error), privacy: .public)")
                self?.ended(Task.isCancelled ? "Export cancelled" : error.localizedDescription)
            }
        }
    }

    func cancelExport() { exporting?.cancel() }

    private func exported(_ file: URL, bytes: Int) {
        ended("Exported \(file.lastPathComponent)")
        tell("Exported \(file.lastPathComponent) · \(ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file))", file)
    }

    private func ended(_ why: String) {
        exporting = nil
        progress = nil
        exportingFormat = nil
        hint(why)
    }

    // MARK: Keys and words

    enum Key: Equatable { case space, escape, enter, delete, char(String, command: Bool, shift: Bool = false) }

    /// The editor's keys wherever the pointer is: Space plays, I and O trim at the playhead, S splits the part there and X
    /// cuts or keeps it, Z adds a zoom there, C crops, B shows the backdrop, ⌘Z undoes, ⇧⌘Z redoes, ⌫ deletes the picked
    /// zoom or blur, ⌘E exports, Return ends a crop, Escape ends a crop, cancels an export, drops the picked zoom or blur,
    /// then closes (twice when there are edits). True when the key was one.
    func key(_ key: Key) -> Bool {
        switch key {
        case .space: togglePlay()
        case .enter: if cropping { finishCrop(keep: true) } else { return false }
        case .delete: deleteSelected()
        case .escape:
            if cropping { finishCrop(keep: false) }
            else if progress != nil { cancelExport() }
            else if picked != nil { picked = nil }
            else if canUndo, !discardArmed { discardArmed = true; hint("Press Escape again to close without exporting") }
            else { closeEditor() }
        case .char(let c, let command, let shift):
            switch (c.lowercased(), command, shift) {
            case ("z", true, true): redo()
            case ("z", true, false): undo()
            case ("e", true, false): export()
            case ("w", true, false): closeEditor()
            case ("i", false, false): trimAtPlayhead(start: true)
            case ("o", false, false): trimAtPlayhead(start: false)
            case ("z", false, false): addZoom(at: playhead)
            case ("s", false, false): split()
            case ("x", false, false): toggleCut()
            case ("c", false, false): cropping ? finishCrop(keep: true) : startCrop()
            case ("b", false, false): panelOpen.toggle()
            default: return false
            }
        }
        return true
    }

    /// The picked zoom, its place among them from one, and how many there are.
    var pickedZoom: (zoom: ZoomSegment, index: Int, count: Int)? {
        guard let id = selected, let i = edit.zooms.firstIndex(where: { $0.id == id }) else { return nil }
        return (edit.zooms[i], i + 1, edit.zooms.count)
    }

    /// The first of the recording's clicks inside `zoom`: the click it was made from, when it was.
    func click(in zoom: ZoomSegment) -> Double? {
        pointer?.clicks.first { $0.t >= zoom.start && $0.t <= zoom.end }?.t
    }

    #if DEBUG
    /// The bar as an export of `format` at `progress` shows it, for the renders; nothing is written.
    func showExporting(_ progress: Double, format: VideoFormat) {
        self.progress = progress
        exportingFormat = format
    }
    #endif

    /// A short line over the preview for two seconds.
    func hint(_ text: String) {
        hint = text
        saying?.cancel()
        saying = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(2.5))
            if !Task.isCancelled { self?.hint = nil }
        }
    }
}
