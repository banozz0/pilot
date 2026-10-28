import AppKit
import AVFoundation
import PilotCore
import SwiftUI

// The video editor's views (P71, after Snapzy's Studio): the capture editor's direction A carried over. The top bar holds
// the backdrop, crop and speed; the backdrop panel sits at the left; the preview is on the sunken ground with the
// transport under it; the timeline (ruler, the recording's pictures with the trim's handles, the zoom track) sits under
// that; the footer holds the export. Instrument's language: eyebrow capitals, hairline rules, mono numbers, the accent only
// for what is picked (the trim, the picked zoom), no shadows; on Look's Glass the panel draws no fill or ring of its own.

struct VideoEditorView: View {
    @Environment(\.style) private var style
    let model: VideoEditorModel
    /// Glass is behind the editor (its window's MaterialBackdrop): no fill or ring over it.
    var glass = false

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: style.radii.pop, style: .continuous)
        VStack(spacing: 0) {
            VideoTopBar(model: model).padding(.horizontal, 12).frame(height: EditorLayout.bar(style))
            rule
            HStack(spacing: 0) {
                if model.panelOpen {
                    BackdropPanel(backdrop: model.edit.backdrop, set: model.setBackdrop, live: model.previewBackdrop, subject: model.poster)
                        .frame(maxHeight: .infinity)
                        .onDisappear(perform: model.settle)
                    style.color(\.line).frame(width: 1)
                }
                VStack(spacing: 0) {
                    VideoStage(model: model)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .background(style.color(\.sunken))
                        .overlay(alignment: .bottom) { if let hint = model.hint { EditorHint(text: hint).padding(.bottom, 14) } }
                    rule
                    VideoTransport(model: model).padding(.horizontal, 12).frame(height: 40)
                }
            }
            rule
            VideoTimeline(model: model).frame(height: VideoTimeline.height)
            rule
            VideoFooter(model: model).padding(.horizontal, 12).frame(height: EditorLayout.foot(style))
        }
        .background { if !glass { shape.fill(style.color(\.panel)) } }
        .clipShape(shape)
        .overlay {
            if style.kind == .toybox { shape.strokeBorder(style.color(\.outline), lineWidth: 2) }
            else if !glass { shape.strokeBorder(style.color(\.line2)) }
        }
    }

    private var rule: some View { style.color(\.line).frame(height: 1) }
}

/// Backdrop and Crop, the speed, the recording's name, Undo and Show in Finder; the empty room drags the window.
struct VideoTopBar: View {
    @Environment(\.style) private var style
    let model: VideoEditorModel

    var body: some View {
        HStack(spacing: EditorTopBar.gap(style)) {
            Button { model.panelOpen.toggle() } label: { ActionCap(symbol: "photo.artframe", label: "Backdrop", lit: model.panelOpen) }
                .buttonStyle(.plain).help("Backdrop: gradients, wallpapers, padding, shadow, corners and ratio  B")
            Button { model.cropping ? model.finishCrop(keep: true) : model.startCrop() } label: {
                ActionCap(symbol: "crop", label: "Crop", lit: model.cropping)
            }
            .buttonStyle(.plain).help("Crop the frame  C").disabled(!model.loaded)
            divider
            Text("SPEED").styleText(\.eyebrow).foregroundStyle(style.color(\.text3)).fixedSize()
            ToolSegments(options: VideoEdit.speeds.map { ($0, Self.speed($0)) }, label: "Speed",
                         selection: Binding(get: { model.edit.speed }, set: model.setSpeed))
                .disabled(!model.loaded)
            WindowDragArea().frame(minWidth: 16, maxWidth: .infinity, maxHeight: .infinity)
            Text(model.url.deletingPathExtension().lastPathComponent).styleText(\.small).foregroundStyle(style.color(\.text2))
                .lineLimit(1).truncationMode(.middle).frame(maxWidth: 260, alignment: .trailing)
            divider
            Button(action: model.undo) { ActionCap(symbol: "arrow.uturn.backward", label: "Undo") }
                .buttonStyle(.plain).help("Undo  ⌘Z").disabled(!model.canUndo)
            Button { NSWorkspace.shared.activateFileViewerSelecting([model.url]) } label: { ActionCap(symbol: "folder", label: "Show in Finder") }
                .buttonStyle(.plain).help("Show the recording in Finder")
        }
    }

    private var divider: some View { style.color(\.line2).frame(width: 1, height: 16).padding(.horizontal, 4) }

    static func speed(_ v: Double) -> String { (v == v.rounded() ? String(Int(v)) : String(v)) + "×" }
}

/// The preview: the player drawing the edit at its canvas's shape, fitted to the stage; while cropping, the whole frame
/// with the crop's frame over it.
struct VideoStage: View {
    @Environment(\.style) private var style
    let model: VideoEditorModel
    static let margin: CGFloat = 20

    var body: some View {
        GeometryReader { geo in
            let room = CGRect(origin: .zero, size: geo.size).insetBy(dx: Self.margin, dy: Self.margin)
            let fit = MarkupRenderer.fit(model.canvas, in: room)
            ZStack(alignment: .topLeading) {
                if let failed = model.failed {
                    Text(failed).styleText(\.small).foregroundStyle(style.color(\.text2)).frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if !model.loaded {
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text("Reading the recording…").styleText(\.small).foregroundStyle(style.color(\.text3))
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    picture.frame(width: fit.width, height: fit.height).offset(x: fit.minX, y: fit.minY)
                        .overlay(alignment: .topLeading) {
                            // A hairline round the picture, so a see-through backdrop's edge shows.
                            Rectangle().strokeBorder(Color(hex: style.dark ? 0xFFFFFF : 0x000000, opacity: 0.1))
                                .frame(width: fit.width, height: fit.height).offset(x: fit.minX, y: fit.minY).allowsHitTesting(false)
                        }
                    if model.cropping { CropFrame(model: model, frame: fit) }
                }
            }
            .frame(width: geo.size.width, height: geo.size.height, alignment: .topLeading)
            .contentShape(.rect)
            .onTapGesture { if !model.cropping { model.togglePlay() } }
        }
    }

    @ViewBuilder private var picture: some View {
        PlayerSurface(player: model.player)
    }
}

extension MarkupRenderer {
    /// `size` fitted inside `room`, centred, its shape kept.
    static func fit(_ size: CGSize, in room: CGRect) -> CGRect {
        let k = min(room.width / max(size.width, 1), room.height / max(size.height, 1))
        let w = (size.width * k).rounded(), h = (size.height * k).rounded()
        return CGRect(x: (room.midX - w / 2).rounded(), y: (room.midY - h / 2).rounded(), width: w, height: h)
    }
}

/// The player's layer in a view: what AVFoundation draws the composition into.
struct PlayerSurface: NSViewRepresentable {
    let player: AVPlayer

    final class Surface: NSView {
        let layerOfPlayer = AVPlayerLayer()

        override init(frame: NSRect) {
            super.init(frame: frame)
            wantsLayer = true
            layerOfPlayer.videoGravity = .resizeAspect
            layerOfPlayer.backgroundColor = .clear
            layer = layerOfPlayer
        }

        @available(*, unavailable) required init?(coder: NSCoder) { fatalError("not from a nib") }
    }

    func makeNSView(context: Context) -> Surface {
        let view = Surface()
        view.layerOfPlayer.player = player
        return view
    }

    func updateNSView(_ view: Surface, context: Context) {
        if view.layerOfPlayer.player !== player { view.layerOfPlayer.player = player }
    }

    static func dismantleNSView(_ view: Surface, coordinator: ()) { view.layerOfPlayer.player = nil }
}

/// The crop's frame over the whole frame: the part outside shaded, a white frame with thirds, a handle at each corner. A
/// drag inside moves it, a corner's drag resizes it.
struct CropFrame: View {
    let model: VideoEditorModel
    /// The picture's place on the stage.
    let frame: CGRect
    @State private var origin: CGRect?

    var body: some View {
        let r = model.cropDraft
        let box = CGRect(x: frame.minX + r.minX * frame.width, y: frame.minY + r.minY * frame.height, width: r.width * frame.width, height: r.height * frame.height)
        ZStack(alignment: .topLeading) {
            Canvas { ctx, _ in
                var shade = Path(frame)
                shade.addRect(box)
                ctx.fill(shade, with: .color(.black.opacity(0.5)), style: FillStyle(eoFill: true))
                var thirds = Path()
                for k in 1...2 {
                    let x = box.minX + box.width * CGFloat(k) / 3, y = box.minY + box.height * CGFloat(k) / 3
                    thirds.move(to: CGPoint(x: x, y: box.minY)); thirds.addLine(to: CGPoint(x: x, y: box.maxY))
                    thirds.move(to: CGPoint(x: box.minX, y: y)); thirds.addLine(to: CGPoint(x: box.maxX, y: y))
                }
                ctx.stroke(thirds, with: .color(.white.opacity(0.35)), lineWidth: 0.5)
                ctx.stroke(Path(box), with: .color(.white), lineWidth: 1.5)
            }
            .allowsHitTesting(false)
            Color.clear.contentShape(.rect).frame(width: box.width, height: box.height).offset(x: box.minX, y: box.minY)
                .gesture(drag { o, d in o.offsetBy(dx: d.width, dy: d.height) })
                .pointerStyle(.grabIdle)
            ForEach(0..<4, id: \.self) { corner in
                let left = corner % 2 == 0, top = corner < 2
                RoundedRectangle(cornerRadius: 2).fill(.white)
                    .overlay { RoundedRectangle(cornerRadius: 2).strokeBorder(.black.opacity(0.45), lineWidth: 0.5) }
                    .frame(width: 12, height: 12)
                    .contentShape(.rect.inset(by: -6))
                    .offset(x: (left ? box.minX : box.maxX) - 6, y: (top ? box.minY : box.maxY) - 6)
                    .gesture(drag { o, d in
                        let x0 = left ? o.minX + d.width : o.minX, x1 = left ? o.maxX : o.maxX + d.width
                        let y0 = top ? o.minY + d.height : o.minY, y1 = top ? o.maxY : o.maxY + d.height
                        return CGRect(x: min(x0, x1), y: min(y0, y1), width: abs(x1 - x0), height: abs(y1 - y0))
                    })
                    .pointerStyle(.frameResize(position: top ? (left ? .topLeading : .topTrailing) : (left ? .bottomLeading : .bottomTrailing)))
            }
        }
    }

    /// A drag that moves the crop from where it began: `apply` takes that crop and the drag in fractions of the frame.
    private func drag(_ apply: @escaping (CGRect, CGSize) -> CGRect) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { g in
                let o = origin ?? model.cropDraft
                origin = o
                let d = CGSize(width: g.translation.width / max(frame.width, 1), height: g.translation.height / max(frame.height, 1))
                var next = apply(o, d)
                if next.size == o.size {
                    // A move keeps the crop's size, held inside the frame.
                    next.origin = CGPoint(x: min(max(0, next.minX), 1 - o.width), y: min(max(0, next.minY), 1 - o.height))
                }
                model.dragCrop(next)
            }
            .onEnded { _ in origin = nil }
    }
}

/// Play, the export's time, and the picked zoom's level and focus (or the keys when none is picked).
struct VideoTransport: View {
    @Environment(\.style) private var style
    let model: VideoEditorModel
    static let levels: [Double] = [1.5, 2, 2.5, 3]

    var body: some View {
        HStack(spacing: 12) {
            Button(action: model.togglePlay) { ActionCap(symbol: model.playing ? "pause.fill" : "play.fill", label: model.playing ? "Pause" : "Play") }
                .buttonStyle(.plain).help(model.playing ? "Pause  Space" : "Play the kept part  Space").disabled(!model.loaded || model.cropping)
            HStack(spacing: 0) {
                Text(Self.time(model.outputTime)).foregroundStyle(style.color(\.text))
                Text(" / " + Self.time(model.length)).foregroundStyle(style.color(\.text3))
            }
            .font(style.font(\.mono, size: 11.5)).monospacedDigit().fixedSize()
            Spacer(minLength: 8)
            if let zoom = model.selectedZoom, !model.cropping {
                inspector(zoom)
            } else {
                Text(model.cropping ? "Crop: drag the frame or a corner, then Done" : "Space plays · I and O trim · Z adds a zoom · click one to set it")
                    .styleText(\.caption).foregroundStyle(style.color(\.text3)).lineLimit(1)
            }
        }
    }

    private func inspector(_ zoom: ZoomSegment) -> some View {
        HStack(spacing: 10) {
            Text("ZOOM").styleText(\.eyebrow).foregroundStyle(style.color(\.text3)).fixedSize()
            ToolSegments(options: Self.levels.map { ($0, VideoTopBar.speed($0)) }, label: "Zoom level",
                         selection: Binding(get: { Self.levels.min { abs($0 - zoom.level) < abs($1 - zoom.level) } ?? 2 }, set: model.setLevel))
            Text("FOCUS").styleText(\.eyebrow).foregroundStyle(style.color(\.text3)).fixedSize().padding(.leading, 4)
            FocusPicker(focus: zoom.focus, follows: model.pointer != nil, set: model.setFocus)
            Button(action: model.deleteSelected) { ActionCap(symbol: "trash", label: "Delete the zoom") }
                .buttonStyle(.plain).help("Delete this zoom  ⌫")
        }
    }

    /// "0:03.2": minutes, seconds and a tenth.
    static func time(_ t: Double) -> String {
        let tenths = Int((max(0, t) * 10).rounded(.down))
        return String(format: "%d:%02d.%d", tenths / 600, tenths / 10 % 60, tenths % 10)
    }
}

/// Where a zoom looks: following the pointer, or one of nine places on the frame.
struct FocusPicker: View {
    @Environment(\.style) private var style
    let focus: CGPoint?
    /// Whether the recording has a pointer track to follow; without one, following it holds the middle.
    let follows: Bool
    let set: (CGPoint?) -> Void
    static let spots: [CGFloat] = [0.2, 0.5, 0.8]

    var body: some View {
        HStack(spacing: 6) {
            Button { set(nil) } label: {
                Image(systemName: "cursorarrow").font(.system(size: 11, weight: style.kind == .toybox ? .bold : .regular))
                    .foregroundStyle(style.color(focus == nil ? \.accentText : \.text2))
                    .frame(width: 26, height: 22)
                    .chipFace(style, lit: focus == nil)
            }
            .buttonStyle(.plain).help(follows ? "Follow the pointer" : "Follow the pointer (this recording has none: the middle)")
            .accessibilityLabel("Follow the pointer").accessibilityAddTraits(focus == nil ? .isSelected : [])
            Grid(horizontalSpacing: 2, verticalSpacing: 2) {
                ForEach(Self.spots, id: \.self) { y in
                    GridRow {
                        ForEach(Self.spots, id: \.self) { x in
                            let lit = focus.map { abs($0.x - x) < 0.01 && abs($0.y - y) < 0.01 } ?? false
                            Button { set(CGPoint(x: x, y: y)) } label: {
                                RoundedRectangle(cornerRadius: 1.5).fill(style.color(lit ? \.accent : \.line2)).frame(width: 7, height: 5)
                            }
                            .buttonStyle(.plain).accessibilityLabel("Focus \(Self.name(x, y))").accessibilityAddTraits(lit ? .isSelected : [])
                        }
                    }
                }
            }
            .padding(3)
            .chipFace(style)
            .help("Hold the zoom on one place")
        }
    }

    static func name(_ x: CGFloat, _ y: CGFloat) -> String {
        let row = y < 0.4 ? "top" : y > 0.6 ? "bottom" : "middle", column = x < 0.4 ? "left" : x > 0.6 ? "right" : "centre"
        return row == "middle" && column == "centre" ? "middle" : "\(row) \(column)"
    }
}

/// The timeline: a ruler in seconds, the recording's pictures with the part kept framed in the accent between two
/// handles and the rest shaded, the zoom track under it, and the playhead through all three. A drag on the ruler or the
/// pictures scrubs; a click on the zoom track's empty room adds a zoom there; a zoom's body drags it, its edges stretch it.
struct VideoTimeline: View {
    @Environment(\.style) private var style
    let model: VideoEditorModel
    @State private var origin: (start: Double, end: Double)?

    static let inset: CGFloat = 14
    static let ruler: CGFloat = 20
    static let strip: CGFloat = 46
    static let zooms: CGFloat = 26
    static let gap: CGFloat = 8
    static let height: CGFloat = 10 + ruler + strip + gap + zooms + 12

    var body: some View {
        GeometryReader { geo in
            let width = max(1, geo.size.width - 2 * Self.inset)
            let duration = max(model.edit.duration, 0.01)
            let x: (Double) -> CGFloat = { Self.inset + CGFloat($0 / duration) * width }
            let t: (CGFloat) -> Double = { min(duration, max(0, Double(($0 - Self.inset) / width) * duration)) }
            let top: CGFloat = 10, stripY = top + Self.ruler, zoomY = stripY + Self.strip + Self.gap
            ZStack(alignment: .topLeading) {
                ruler(x: x, width: width, duration: duration).frame(height: Self.ruler).offset(y: top)
                    .contentShape(.rect).gesture(scrub(t))
                strip(width: width).frame(width: width, height: Self.strip).offset(x: Self.inset, y: stripY)
                    .contentShape(.rect).gesture(scrub(t))
                trim(x: x, t: t, y: stripY)
                zoomTrack(x: x, t: t, width: width, y: zoomY)
                Playhead(model: model, inset: Self.inset, width: width, top: top, bottom: zoomY + Self.zooms)
            }
            .coordinateSpace(.named("timeline"))
            .disabled(!model.loaded || model.cropping)
            .opacity(model.cropping ? 0.5 : 1)
        }
    }

    private func scrub(_ t: @escaping (CGFloat) -> Double) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { model.scrub(to: t($0.location.x), done: false) }
            .onEnded { model.scrub(to: t($0.location.x), done: true) }
    }

    // MARK: Ruler

    private func ruler(x: @escaping (Double) -> CGFloat, width: CGFloat, duration: Double) -> some View {
        let step = Self.step(duration: duration, width: width)
        let marks = Array(stride(from: 0.0, through: duration + 0.0001, by: step))
        return ZStack(alignment: .topLeading) {
            ForEach(marks, id: \.self) { m in
                let at = x(m)
                Rectangle().fill(style.color(\.line2)).frame(width: 1, height: 5).offset(x: at, y: Self.ruler - 5)
                Text(Self.label(m, step: step)).font(style.font(\.mono, size: 9.5)).foregroundStyle(style.color(\.text3)).fixedSize()
                    .offset(x: at + 3, y: 1)
            }
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }

    /// The ruler's step: the first of a few round ones whose marks stand at least 64 points apart.
    static func step(duration: Double, width: CGFloat) -> Double {
        let steps: [Double] = [0.5, 1, 2, 5, 10, 15, 30, 60, 120, 300, 600]
        return steps.first { CGFloat($0 / max(duration, 0.01)) * width >= 64 } ?? 600
    }

    static func label(_ t: Double, step: Double) -> String {
        let s = Int(t)
        return step < 1 ? String(format: "%d:%02d.%d", s / 60, s % 60, Int((t * 10).rounded()) % 10) : String(format: "%d:%02d", s / 60, s % 60)
    }

    // MARK: Pictures and trim

    private func strip(width: CGFloat) -> some View {
        let shape = RoundedRectangle(cornerRadius: style.radii.control, style: .continuous)
        let pictures = model.strip
        return HStack(spacing: 0) {
            if pictures.isEmpty {
                style.color(\.raised)
            } else {
                // As many pictures as fit at the strip's height, picked evenly from the ones read.
                let side = Self.strip * CGFloat(model.size.width / max(model.size.height, 1))
                let count = max(1, min(pictures.count, Int((width / max(side, 1)).rounded(.up))))
                ForEach(0..<count, id: \.self) { i in
                    Image(decorative: pictures[min(pictures.count - 1, i * pictures.count / count)], scale: 1)
                        .resizable().aspectRatio(contentMode: .fill)
                        .frame(width: width / CGFloat(count), height: Self.strip).clipped()
                }
            }
        }
        .clipShape(shape)
        .overlay { shape.strokeBorder(style.color(\.line)) }
    }

    private func trim(x: @escaping (Double) -> CGFloat, t: @escaping (CGFloat) -> Double, y: CGFloat) -> some View {
        let a = x(model.edit.trimIn), b = x(model.edit.trimOut), left = x(0), right = x(model.edit.duration)
        let handle: CGFloat = 10
        return ZStack(alignment: .topLeading) {
            // The parts cut off, shaded.
            Rectangle().fill(.black.opacity(0.55)).frame(width: max(0, a - left), height: Self.strip).offset(x: left, y: y).allowsHitTesting(false)
            Rectangle().fill(.black.opacity(0.55)).frame(width: max(0, right - b), height: Self.strip).offset(x: b, y: y).allowsHitTesting(false)
            RoundedRectangle(cornerRadius: 4, style: .continuous).strokeBorder(style.color(\.accent), lineWidth: 2)
                .frame(width: max(2, b - a), height: Self.strip).offset(x: a, y: y).allowsHitTesting(false)
            trimHandle(start: true).frame(width: handle, height: Self.strip).offset(x: a - handle / 2, y: y)
                .gesture(DragGesture(minimumDistance: 0, coordinateSpace: .named("timeline"))
                    .onChanged { model.trim(in: t($0.location.x), live: true) }.onEnded { _ in model.settle() })
            trimHandle(start: false).frame(width: handle, height: Self.strip).offset(x: b - handle / 2, y: y)
                .gesture(DragGesture(minimumDistance: 0, coordinateSpace: .named("timeline"))
                    .onChanged { model.trim(out: t($0.location.x), live: true) }.onEnded { _ in model.settle() })
        }
    }

    private func trimHandle(start: Bool) -> some View {
        RoundedRectangle(cornerRadius: 3, style: .continuous).fill(style.color(\.accent))
            .overlay { Capsule().fill(style.color(\.onAccent).opacity(0.85)).frame(width: 2, height: 14) }
            .contentShape(.rect.inset(by: -4))
            .pointerStyle(.columnResize)
            .help(start ? "Where the export starts  I" : "Where the export ends  O")
            .accessibilityLabel(start ? "Trim start" : "Trim end")
    }

    // MARK: Zooms

    private func zoomTrack(x: @escaping (Double) -> CGFloat, t: @escaping (CGFloat) -> Double, width: CGFloat, y: CGFloat) -> some View {
        let shape = RoundedRectangle(cornerRadius: style.radii.control, style: .continuous)
        return ZStack(alignment: .topLeading) {
            shape.fill(style.color(\.raised).opacity(0.6))
                .overlay { shape.strokeBorder(style.color(\.line), style: StrokeStyle(lineWidth: 1, dash: [3, 3])) }
                .overlay(alignment: .leading) {
                    if model.edit.zooms.isEmpty {
                        Text("Click to add a zoom").styleText(\.caption).foregroundStyle(style.color(\.text3)).padding(.leading, 10)
                    }
                }
                .frame(width: width, height: Self.zooms).offset(x: Self.inset, y: y)
                .contentShape(.rect)
                .onTapGesture(coordinateSpace: .named("timeline")) { p in
                    model.selected = nil
                    model.addZoom(at: t(p.x))
                }
                .help("Click to add a zoom here  Z")
            ForEach(model.edit.zooms) { zoom in
                block(zoom, x: x, t: t).offset(x: x(zoom.start), y: y)
            }
        }
    }

    /// One zoom: its level on a block from its start to its end, the picked one in the accent; its body drags it and its
    /// edges stretch it.
    private func block(_ zoom: ZoomSegment, x: @escaping (Double) -> CGFloat, t: @escaping (CGFloat) -> Double) -> some View {
        let picked = model.selected == zoom.id, w = max(10, x(zoom.end) - x(zoom.start))
        let shape = RoundedRectangle(cornerRadius: style.radii.control, style: .continuous)
        let perPoint = model.edit.duration / Double(max(1, x(model.edit.duration) - x(0)))
        return ZStack {
            shape.fill(style.color(picked ? \.accent : \.accentSoft))
            shape.strokeBorder(style.color(picked ? \.accent : \.accentLine))
            HStack(spacing: 4) {
                Image(systemName: zoom.focus == nil ? "cursorarrow.motionlines" : "plus.magnifyingglass").font(.system(size: 9, weight: .semibold))
                Text(VideoTopBar.speed(zoom.level)).font(style.font(\.mono, size: 10))
            }
            .foregroundStyle(style.color(picked ? \.onAccent : \.accentText))
            .opacity(w > 46 ? 1 : 0)
        }
        .frame(width: w, height: Self.zooms)
        .contentShape(.rect)
        .gesture(DragGesture(minimumDistance: 2)
            .onChanged { g in
                let o = origin ?? (zoom.start, zoom.end)
                origin = o
                model.selected = zoom.id
                model.moveZoom(zoom.id, to: o.start + Double(g.translation.width) * perPoint)
            }
            .onEnded { _ in origin = nil; model.settle() })
        .simultaneousGesture(TapGesture().onEnded { model.selected = zoom.id; model.show(zoom.start + min(0.5, zoom.length / 2)) })
        .overlay(alignment: .leading) { edge(zoom, start: true, t: t) }
        .overlay(alignment: .trailing) { edge(zoom, start: false, t: t) }
        .help("Drag to move · drag an edge to stretch · ⌫ deletes")
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Zoom \(VideoTopBar.speed(zoom.level)) from \(VideoTransport.time(zoom.start)) to \(VideoTransport.time(zoom.end))")
        .accessibilityAddTraits(picked ? .isSelected : [])
    }

    private func edge(_ zoom: ZoomSegment, start: Bool, t: @escaping (CGFloat) -> Double) -> some View {
        Color.clear.frame(width: 7).contentShape(.rect).pointerStyle(.columnResize)
            .gesture(DragGesture(minimumDistance: 0, coordinateSpace: .named("timeline"))
                .onChanged { g in
                    model.selected = zoom.id
                    if start { model.stretchZoom(zoom.id, start: t(g.location.x)) } else { model.stretchZoom(zoom.id, end: t(g.location.x)) }
                }
                .onEnded { _ in model.settle() })
    }
}

/// The export's format and size, its pixels and length, then Export and Close; while it runs, its progress and Cancel.
/// While cropping, Whole frame, Cancel and Done.
struct VideoFooter: View {
    @Environment(\.style) private var style
    let model: VideoEditorModel

    var body: some View {
        HStack(spacing: 12) {
            if model.cropping { crop } else { export }
        }
    }

    @ViewBuilder private var crop: some View {
        Text("The part of the frame to keep").styleText(\.caption).foregroundStyle(style.color(\.text3)).fixedSize()
        Button("Whole frame", action: model.wholeFrame).buttonStyle(.pilot)
        Spacer(minLength: 8)
        ToolButtons(primary: "Done", run: { model.finishCrop(keep: true) }, cancel: { model.finishCrop(keep: false) })
    }

    @ViewBuilder private var export: some View {
        Text("FORMAT").styleText(\.eyebrow).foregroundStyle(style.color(\.text3)).fixedSize()
        ToolSegments(options: VideoFormat.allCases.map { ($0, $0.title) }, label: "Format", selection: Binding(get: { model.format }, set: { model.format = $0 }))
        Text("SIZE").styleText(\.eyebrow).foregroundStyle(style.color(\.text3)).fixedSize().padding(.leading, 4)
        ToolSegments(options: VideoSize.allCases.map { ($0, $0.title) }, label: "Size", selection: Binding(get: { model.exportSize }, set: { model.exportSize = $0 }))
        let px = model.exportPixels
        Text(verbatim: model.loaded ? "\(Int(px.width))×\(Int(px.height)) · \(VideoTransport.time(model.length))\(model.format == .gif ? " · \(VideoFormat.gifFPS) fps" : "")" : "—")
            .font(style.font(\.mono, size: 10.5)).foregroundStyle(style.color(\.text2)).monospacedDigit().lineLimit(1).fixedSize()
            .padding(.horizontal, 8).chipFace(style)
        Spacer(minLength: 8)
        if let progress = model.progress {
            HStack(spacing: 8) {
                Text("Exporting").styleText(\.small).foregroundStyle(style.color(\.text2)).fixedSize()
                ProgressView(value: progress).progressViewStyle(.linear).tint(style.color(\.accent)).frame(width: 140)
                Text(verbatim: "\(Int((progress * 100).rounded())) %").font(style.font(\.mono, size: 10.5)).foregroundStyle(style.color(\.text)).monospacedDigit()
                    .frame(width: 38, alignment: .trailing)
                if style.kind == .toybox { Button("Cancel", action: model.cancelExport).buttonStyle(ToyFaceStyle(ghost: true)) }
                else { Button("Cancel", action: model.cancelExport).buttonStyle(InstrumentButtonStyle(kind: .ghost)) }
            }
        } else {
            ToolButtons(primary: "Export", disabled: !model.loaded, cancelTitle: "Close", run: model.export, cancel: model.closeEditor)
                .help("Export beside the recording  ⌘E")
        }
    }
}

/// The playhead through the timeline: a view of its own, so playback's 30 moves a second redraw it and nothing else.
struct Playhead: View {
    @Environment(\.style) private var style
    let model: VideoEditorModel
    let inset: CGFloat
    let width: CGFloat
    let top: CGFloat
    let bottom: CGFloat

    var body: some View {
        let x = inset + CGFloat(model.playhead / max(model.edit.duration, 0.01)) * width
        ZStack(alignment: .topLeading) {
            Rectangle().fill(style.color(\.text)).frame(width: 1.5, height: bottom - top).offset(x: x - 0.75, y: top)
            RoundedRectangle(cornerRadius: 2, style: .continuous).fill(style.color(\.text)).frame(width: 9, height: 12).offset(x: x - 4.5, y: top)
        }
        .allowsHitTesting(false)
    }
}
