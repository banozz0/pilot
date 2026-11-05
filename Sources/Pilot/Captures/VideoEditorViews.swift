import AppKit
import AVFoundation
import PilotCore
import SwiftUI

// The video editor's views in A (Sven, Q806; editors-round-2's record mocks and its 12 parity rows): along the top the
// recording's name, length and size, then Undo, Redo, Show in Finder and Export, or an export's progress and Cancel; the
// preview on the sunken ground with the transport under it, and the inspector at the right with its four tabs (Clip, Zoom,
// Backdrop, Export); the timeline's lanes (the clip with its trim, parts and cuts, the zooms, the blurs) along the bottom. Instrument's language:
// eyebrow capitals, hairline rules, mono numbers, the accent only for what is picked (the trim, the picked zoom, the tab),
// no shadows; on Look's Glass the panel draws no fill or ring of its own. The chrome's caps and rules are the capture
// editor's (EditorChrome).

struct VideoEditorView: View {
    @Environment(\.style) private var style
    let model: VideoEditorModel
    /// Glass is behind the editor (its window's MaterialBackdrop): no fill or ring over it.
    var glass = false
    /// A frame to show in place of the player, for the renders: AVPlayerLayer draws nothing into a view snapshot.
    var still: CGImage?

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: style.radii.pop, style: .continuous)
        VStack(spacing: 0) {
            VideoTopBar(model: model).padding(.horizontal, 12).frame(height: EditorLayout.bar(style))
            rule
            HStack(spacing: 0) {
                VStack(spacing: 0) {
                    VideoStage(model: model, still: still)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .overlay(alignment: .bottom) { if let hint = model.hint { EditorHint(text: hint).padding(.bottom, 14) } }
                    if model.cropping { VideoCropStrip(model: model).padding(.horizontal, 20).frame(height: 44) }
                    rule
                    VideoTransport(model: model).padding(.horizontal, 12).frame(height: 40)
                }
                .background(style.color(\.sunken))
                style.color(\.line).frame(width: 1)
                VideoInspector(model: model).frame(width: VideoInspector.width).frame(maxHeight: .infinity, alignment: .top)
            }
            rule
            VideoTimeline(model: model).frame(height: VideoTimeline.height)
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

/// Close, the recording's name with its length and size; at the right Undo, Redo, Show in Finder and Export, or while an
/// export runs its progress and Cancel. The empty room drags the window.
struct VideoTopBar: View {
    @Environment(\.style) private var style
    let model: VideoEditorModel

    var body: some View {
        HStack(spacing: EditorTopBar.gap(style)) {
            Button(action: model.closeEditor) { ActionCap(symbol: "xmark", label: "Close") }
                .buttonStyle(.plain).help("Close the editor  ⌘W")
            Text(model.url.lastPathComponent).styleText(\.strong).foregroundStyle(style.color(\.text))
                .lineLimit(1).truncationMode(.middle).frame(maxWidth: 300, alignment: .leading).fixedSize()
                .padding(.leading, 4)
            if model.loaded {
                MonoChip(text: "\(RecordingClock.label(model.edit.duration)) · \(Int(model.size.width)) × \(Int(model.size.height))", size: 10.5)
            }
            WindowDragArea().frame(minWidth: 16, maxWidth: .infinity, maxHeight: .infinity)
            if let format = model.exportingFormat {
                ExportProgress(model: model, format: format)
            } else {
                Button(action: model.undo) { ActionCap(symbol: "arrow.uturn.backward", label: "Undo") }
                    .buttonStyle(.plain).help("Undo  ⌘Z").disabled(!model.canUndo)
                Button(action: model.redo) { ActionCap(symbol: "arrow.uturn.forward", label: "Redo") }
                    .buttonStyle(.plain).help("Redo  ⇧⌘Z").disabled(!model.canRedo)
                Button { NSWorkspace.shared.activateFileViewerSelecting([model.url]) } label: { ActionCap(symbol: "folder", label: "Show in Finder") }
                    .buttonStyle(.plain).help("Show the recording in Finder")
                EditorRule().padding(.horizontal, 4)
                ExportButton(model: model)
            }
        }
    }

}

/// Export, the one primary: the edit beside the recording (⌘E).
struct ExportButton: View {
    @Environment(\.style) private var style
    let model: VideoEditorModel

    var body: some View {
        Group {
            if style.kind == .toybox { Button("Export  ⌘E", action: model.export).buttonStyle(ToyFaceStyle(primary: true)) }
            else { Button("Export  ⌘E", action: model.export).buttonStyle(InstrumentButtonStyle(kind: .primary)) }
        }
        .disabled(!model.loaded || model.cropping || model.length <= 0)
        .help("Export beside the recording, as the Export tab says  ⌘E")
    }
}

/// An export under way: "Exporting MP4", its bar and per cent, and Cancel (Esc), in the top bar so the editor stays open
/// to look round while it runs.
/// A view of its own, so the run's many progress updates redraw it and nothing else.
struct ExportProgress: View {
    @Environment(\.style) private var style
    let model: VideoEditorModel
    let format: VideoFormat

    var body: some View {
        let progress = model.progress ?? 0
        HStack(spacing: 8) {
            Text("Exporting \(format.title)").styleText(\.small).foregroundStyle(style.color(\.text2)).fixedSize()
            ProgressView(value: progress).progressViewStyle(.linear).tint(style.color(\.accent)).frame(width: 150)
            Text(verbatim: "\(Int((progress * 100).rounded())) %").font(style.font(\.mono, size: 10.5)).foregroundStyle(style.color(\.text)).monospacedDigit()
                .frame(width: 38, alignment: .trailing)
            if style.kind == .toybox { Button("Cancel", action: model.cancelExport).buttonStyle(ToyFaceStyle(ghost: true)) }
            else { Button("Cancel", action: model.cancelExport).buttonStyle(InstrumentButtonStyle(kind: .ghost)) }
        }
        .fixedSize()
        .help("Cancel stops the export  Esc")
    }
}

/// The preview: the player drawing the edit at its canvas's shape, fitted to the stage; while cropping, the whole frame
/// with the crop's frame over it.
struct VideoStage: View {
    @Environment(\.style) private var style
    let model: VideoEditorModel
    /// The renders' frame in place of the player (VideoEditorView.still).
    var still: CGImage?
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
                    else if let picked = model.pickedBlur {
                        // Kept to the picture: a zoom can carry part of the area off it.
                        BlurBox(model: model, blur: picked.blur, frame: fit)
                            .mask(alignment: .topLeading) { Rectangle().frame(width: fit.width, height: fit.height).offset(x: fit.minX, y: fit.minY) }
                    }
                }
            }
            .frame(width: geo.size.width, height: geo.size.height, alignment: .topLeading)
            .contentShape(.rect)
            .onTapGesture { if !model.cropping { model.togglePlay() } }
        }
    }

    @ViewBuilder private var picture: some View {
        if let still { Image(decorative: still, scale: 1).resizable() } else { PlayerSurface(player: model.player) }
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

/// The picked blur's area (R8) where it shows on the preview: a dashed frame with a handle at each corner. A drag inside
/// moves it over what to hide, a corner's drag resizes it; drags go back through the zoom and crop to the whole frame.
struct BlurBox: View {
    let model: VideoEditorModel
    let blur: BlurSpan
    /// The picture's place on the stage.
    let frame: CGRect
    @State private var origin: CGRect?

    var body: some View {
        let shown = model.shown(blur.area)
        let box = CGRect(x: frame.minX + shown.rect.minX * frame.width, y: frame.minY + shown.rect.minY * frame.height,
                         width: shown.rect.width * frame.width, height: shown.rect.height * frame.height)
        // Stage points to fractions of the whole frame.
        let per = CGSize(width: 1 / max(frame.width * shown.scale.width, 1), height: 1 / max(frame.height * shown.scale.height, 1))
        ZStack(alignment: .topLeading) {
            Rectangle().strokeBorder(.white, style: StrokeStyle(lineWidth: 1.5, dash: [5, 3]))
                .background(Rectangle().strokeBorder(.black.opacity(0.4), lineWidth: 3))
                .overlay(alignment: .topLeading) {
                    Label("Blur", systemImage: "eye.slash").font(.system(size: 10, weight: .semibold)).foregroundStyle(.white)
                        .padding(.horizontal, 5).padding(.vertical, 2).background(.black.opacity(0.55), in: .rect(cornerRadius: 3))
                        .offset(y: -20).fixedSize()
                }
                .frame(width: box.width, height: box.height).offset(x: box.minX, y: box.minY)
                .allowsHitTesting(false)
            Color.clear.contentShape(.rect).frame(width: box.width, height: box.height).offset(x: box.minX, y: box.minY)
                .gesture(drag(per) { o, d in o.offsetBy(dx: d.width, dy: d.height) })
                .pointerStyle(.grabIdle)
                .help("Drag over what to hide · drag a corner to size it")
            ForEach(0..<4, id: \.self) { corner in
                let left = corner % 2 == 0, top = corner < 2
                RoundedRectangle(cornerRadius: 2).fill(.white)
                    .overlay { RoundedRectangle(cornerRadius: 2).strokeBorder(.black.opacity(0.45), lineWidth: 0.5) }
                    .frame(width: 10, height: 10)
                    .contentShape(.rect.inset(by: -6))
                    .offset(x: (left ? box.minX : box.maxX) - 5, y: (top ? box.minY : box.maxY) - 5)
                    .gesture(drag(per) { o, d in
                        let x0 = left ? o.minX + d.width : o.minX, x1 = left ? o.maxX : o.maxX + d.width
                        let y0 = top ? o.minY + d.height : o.minY, y1 = top ? o.maxY : o.maxY + d.height
                        return CGRect(x: min(x0, x1), y: min(y0, y1), width: abs(x1 - x0), height: abs(y1 - y0))
                    })
                    .pointerStyle(.frameResize(position: top ? (left ? .topLeading : .topTrailing) : (left ? .bottomLeading : .bottomTrailing)))
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Blurred area")
    }

    /// A drag from the area where it began: `apply` takes that area and the drag, both in fractions of the whole frame.
    private func drag(_ per: CGSize, _ apply: @escaping (CGRect, CGSize) -> CGRect) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { g in
                let o = origin ?? blur.area
                origin = o
                model.setBlurArea(apply(o, CGSize(width: g.translation.width * per.width, height: g.translation.height * per.height)))
            }
            .onEnded { _ in origin = nil; model.settle() }
    }
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

/// Play, where the playhead is in the export and the length kept, and the editor's keys (the crop's while cropping).
struct VideoTransport: View {
    @Environment(\.style) private var style
    let model: VideoEditorModel

    var body: some View {
        HStack(spacing: 12) {
            Button(action: model.togglePlay) { ActionCap(symbol: model.playing ? "pause.fill" : "play.fill", label: model.playing ? "Pause" : "Play") }
                .buttonStyle(.plain).help(model.playing ? "Pause  Space" : "Play the kept part  Space").disabled(!model.loaded || model.cropping)
            HStack(spacing: 0) {
                Text(Self.time(model.outputTime)).foregroundStyle(style.color(\.text))
                Text(" / " + Self.time(model.length) + " kept").foregroundStyle(style.color(\.text3))
            }
            .font(style.font(\.mono, size: 11.5)).monospacedDigit().fixedSize()
            Spacer(minLength: 8)
            Text(model.cropping ? "Drag the frame or a corner · Return keeps it · Esc" : "Space plays · I and O trim · S splits · X cuts · Z zooms · C crops")
                .styleText(\.caption).foregroundStyle(style.color(\.text3)).lineLimit(1)
        }
    }

    /// A speed or a zoom's level: "½×", "1.5×", "2×".
    static func times(_ v: Double) -> String { v == 0.5 ? "½×" : (v == v.rounded() ? String(Int(v)) : String(v)) + "×" }

    /// "0:03.2": minutes, seconds and a tenth.
    static func time(_ t: Double) -> String {
        let tenths = Int((max(0, t) * 10).rounded(.down))
        return String(format: "%d:%02d.%d", tenths / 600, tenths / 10 % 60, tenths % 10)
    }
}

/// Under the preview while cropping: what the frame is, Whole frame, then Cancel (Esc) and Done (Return).
struct VideoCropStrip: View {
    @Environment(\.style) private var style
    let model: VideoEditorModel

    var body: some View {
        HStack(spacing: 10) {
            Text("The part of the frame to keep").styleText(\.caption).foregroundStyle(style.color(\.text3)).fixedSize()
            Button("Whole frame", action: model.wholeFrame).buttonStyle(.pilot)
            Spacer(minLength: 8)
            ToolButtons(primary: "Done", run: { model.finishCrop(keep: true) }, cancel: { model.finishCrop(keep: false) })
                .help("Done keeps the crop  ↩ · Cancel  Esc")
        }
    }
}

/// The nine places a zoom can hold on, as a small grid; the picked one in the accent.
struct FocusPicker: View {
    @Environment(\.style) private var style
    let focus: CGPoint?
    let set: (CGPoint?) -> Void
    static let spots: [CGFloat] = [0.2, 0.5, 0.8]

    var body: some View {
        Grid(horizontalSpacing: 3, verticalSpacing: 3) {
            ForEach(Self.spots, id: \.self) { y in
                GridRow {
                    ForEach(Self.spots, id: \.self) { x in
                        let lit = focus.map { abs($0.x - x) < 0.01 && abs($0.y - y) < 0.01 } ?? false
                        Button { set(CGPoint(x: x, y: y)) } label: {
                            RoundedRectangle(cornerRadius: 2).fill(style.color(lit ? \.accent : \.line2)).frame(width: 16, height: 11)
                        }
                        .buttonStyle(.plain).help("Hold on the \(Self.name(x, y))")
                        .accessibilityLabel("Focus \(Self.name(x, y))").accessibilityAddTraits(lit ? .isSelected : [])
                    }
                }
            }
        }
        .padding(6)
        .instrumentRaised(true)
    }

    static func name(_ x: CGFloat, _ y: CGFloat) -> String {
        let row = y < 0.4 ? "top" : y > 0.6 ? "bottom" : "middle", column = x < 0.4 ? "left" : x > 0.6 ? "right" : "centre"
        return row == "middle" && column == "centre" ? "middle" : "\(row) \(column)"
    }
}

/// The timeline: a ruler in seconds, the Clip lane (the recording's pictures with the part kept framed in the accent
/// between two handles and the rest shaded; its splits, cut parts hatched, a part's own speed, the suggested still parts
/// under it), the Zoom lane and the Blur lane under it, each named at the left, and the playhead through them all. A drag
/// on the ruler or the pictures scrubs; a click on the zoom or blur track's empty room adds one there; a block's body
/// drags it, its edges stretch it.
struct VideoTimeline: View {
    @Environment(\.style) private var style
    let model: VideoEditorModel
    @State private var origin: (start: Double, end: Double)?

    static let inset: CGFloat = 14
    /// The lanes' names' column at the left.
    static let lead: CGFloat = 84
    static let ruler: CGFloat = 20
    static let strip: CGFloat = 46
    static let zooms: CGFloat = 26
    static let gap: CGFloat = 8
    static let height: CGFloat = 10 + ruler + strip + gap + zooms + gap + zooms + 12

    var body: some View {
        GeometryReader { geo in
            let width = max(1, geo.size.width - Self.lead - Self.inset)
            let duration = max(model.edit.duration, 0.01)
            let x: (Double) -> CGFloat = { Self.lead + CGFloat($0 / duration) * width }
            let t: (CGFloat) -> Double = { min(duration, max(0, Double(($0 - Self.lead) / width) * duration)) }
            let top: CGFloat = 10, stripY = top + Self.ruler, zoomY = stripY + Self.strip + Self.gap, blurY = zoomY + Self.zooms + Self.gap
            ZStack(alignment: .topLeading) {
                lane("Clip", symbol: "film", y: stripY, height: Self.strip)
                lane("Zoom", symbol: "plus.magnifyingglass", y: zoomY, height: Self.zooms)
                lane("Blur", symbol: "eye.slash", y: blurY, height: Self.zooms)
                ruler(x: x, width: width, duration: duration).frame(height: Self.ruler).offset(y: top)
                    .contentShape(.rect).gesture(scrub(t))
                strip(width: width).frame(width: width, height: Self.strip).offset(x: Self.lead, y: stripY)
                    .contentShape(.rect).gesture(scrub(t))
                parts(x: x, y: stripY)
                trim(x: x, t: t, y: stripY)
                zoomTrack(x: x, t: t, width: width, y: zoomY)
                blurTrack(x: x, t: t, width: width, y: blurY)
                Playhead(model: model, lead: Self.lead, width: width, top: top, bottom: blurY + Self.zooms)
            }
            .coordinateSpace(.named("timeline"))
            .disabled(!model.loaded || model.cropping)
            .opacity(model.cropping ? 0.5 : 1)
        }
    }

    /// A lane's name and symbol in the left column, beside its row.
    private func lane(_ name: String, symbol: String, y: CGFloat, height: CGFloat) -> some View {
        HStack(spacing: 6) {
            Image(systemName: symbol).font(.system(size: 11, weight: style.kind == .toybox ? .bold : .regular))
            Text(name.uppercased()).styleText(\.eyebrow)
        }
        .foregroundStyle(style.color(\.text3))
        .frame(width: Self.lead - 12, height: height, alignment: .leading)
        .offset(x: Self.inset, y: y)
        .allowsHitTesting(false)
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

    /// The clip's parts over its pictures: a rule at each split, a cut part hatched and dimmed with scissors, a part's own
    /// speed on a chip, and the suggested still parts (R7) as dashes along the strip's foot.
    private func parts(x: @escaping (Double) -> CGFloat, y: CGFloat) -> some View {
        let parts = model.edit.parts
        return ZStack(alignment: .topLeading) {
            ForEach(Array(parts.enumerated()), id: \.offset) { i, part in
                let a = x(part.start), w = max(1, x(part.end) - a)
                if part.cut {
                    ZStack {
                        Rectangle().fill(.black.opacity(0.62))
                        Hatch().stroke(.white.opacity(0.22), lineWidth: 1)
                        if w > 24 { Image(systemName: "scissors").font(.system(size: 11, weight: .semibold)).foregroundStyle(.white.opacity(0.85)) }
                    }
                    .frame(width: w, height: Self.strip).clipped().offset(x: a, y: y)
                } else if let speed = part.speed, w > 26 {
                    Text(VideoTransport.times(speed)).font(style.font(\.mono, size: 10)).foregroundStyle(style.color(\.onAccent))
                        .padding(.horizontal, 5).padding(.vertical, 1)
                        .background(style.color(\.accent), in: .rect(cornerRadius: 3)).fixedSize()
                        .offset(x: a + 5, y: y + 5)
                }
                if i > 0 {
                    Rectangle().fill(style.color(\.text)).frame(width: 2, height: Self.strip + 6).offset(x: a - 1, y: y - 3)
                }
            }
            ForEach(Array(model.stillParts.enumerated()), id: \.offset) { _, span in
                // White dashes on a dark band: they read on any picture, light or dark.
                Rectangle().fill(.black.opacity(0.6))
                    .overlay { Hatch(vertical: true).stroke(.white, lineWidth: 3) }
                    .frame(width: max(2, x(span.upperBound) - x(span.lowerBound)), height: 4).clipped()
                    .offset(x: x(span.lowerBound), y: y + Self.strip - 5)
            }
        }
        .allowsHitTesting(false)
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
                .frame(width: width, height: Self.zooms).offset(x: Self.lead, y: y)
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
                Text(VideoTransport.times(zoom.level)).font(style.font(\.mono, size: 10))
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
        .overlay(alignment: .leading) { edge(t) { model.selected = zoom.id; model.stretchZoom(zoom.id, start: $0) } }
        .overlay(alignment: .trailing) { edge(t) { model.selected = zoom.id; model.stretchZoom(zoom.id, end: $0) } }
        .help("Drag to move · drag an edge to stretch · ⌫ deletes")
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Zoom \(VideoTransport.times(zoom.level)) from \(VideoTransport.time(zoom.start)) to \(VideoTransport.time(zoom.end))")
        .accessibilityAddTraits(picked ? .isSelected : [])
    }

    // MARK: Blurs

    /// The Blur lane (R8): a click in its empty room adds a blur there; each blur a block, moved and stretched like a zoom.
    private func blurTrack(x: @escaping (Double) -> CGFloat, t: @escaping (CGFloat) -> Double, width: CGFloat, y: CGFloat) -> some View {
        let shape = RoundedRectangle(cornerRadius: style.radii.control, style: .continuous)
        let perPoint = model.edit.duration / Double(max(1, x(model.edit.duration) - x(0)))
        return ZStack(alignment: .topLeading) {
            shape.fill(style.color(\.raised).opacity(0.6))
                .overlay { shape.strokeBorder(style.color(\.line), style: StrokeStyle(lineWidth: 1, dash: [3, 3])) }
                .overlay(alignment: .leading) {
                    if model.edit.blurs.isEmpty {
                        Text("Click to blur a part of the screen for a time").styleText(\.caption).foregroundStyle(style.color(\.text3)).padding(.leading, 10)
                    }
                }
                .frame(width: width, height: Self.zooms).offset(x: Self.lead, y: y)
                .contentShape(.rect)
                .onTapGesture(coordinateSpace: .named("timeline")) { p in model.addBlur(at: t(p.x)) }
                .help("Click to blur a part of the screen from here")
            ForEach(model.edit.blurs) { blur in
                let picked = model.pickedBlurID == blur.id, w = max(10, x(blur.end) - x(blur.start))
                ZStack {
                    shape.fill(style.color(picked ? \.accent : \.raised))
                    shape.strokeBorder(style.color(picked ? \.accent : \.line2))
                    Image(systemName: "eye.slash").font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(style.color(picked ? \.onAccent : \.text2)).opacity(w > 24 ? 1 : 0)
                }
                .frame(width: w, height: Self.zooms)
                .contentShape(.rect)
                .gesture(DragGesture(minimumDistance: 2)
                    .onChanged { g in
                        let o = origin ?? (blur.start, blur.end)
                        origin = o
                        model.pickedBlurID = blur.id
                        model.moveBlur(blur.id, to: o.start + Double(g.translation.width) * perPoint)
                    }
                    .onEnded { _ in origin = nil; model.settle() })
                .simultaneousGesture(TapGesture().onEnded { model.pickedBlurID = blur.id; model.show(blur.start + min(0.5, blur.length / 2)) })
                .overlay(alignment: .leading) { edge(t) { model.pickedBlurID = blur.id; model.stretchBlur(blur.id, start: $0) } }
                .overlay(alignment: .trailing) { edge(t) { model.pickedBlurID = blur.id; model.stretchBlur(blur.id, end: $0) } }
                .help("Drag to move · drag an edge to stretch · ⌫ deletes")
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("Blur from \(VideoTransport.time(blur.start)) to \(VideoTransport.time(blur.end))")
                .accessibilityAddTraits(picked ? .isSelected : [])
                .offset(x: x(blur.start), y: y)
            }
        }
    }

    /// A block's edge on a lane: its drag hands `stretch` the time under the pointer.
    private func edge(_ t: @escaping (CGFloat) -> Double, stretch: @escaping (Double) -> Void) -> some View {
        Color.clear.frame(width: 7).contentShape(.rect).pointerStyle(.columnResize)
            .gesture(DragGesture(minimumDistance: 0, coordinateSpace: .named("timeline"))
                .onChanged { stretch(t($0.location.x)) }
                .onEnded { _ in model.settle() })
    }
}

/// A's inspector (Sven, Q806): four tabs. Clip holds the trim's times, the speed, the pointer and the crop; Zoom the picked zoom's
/// level and focus; Backdrop the capture editor's backdrop panel; Export the format, the size and Export.
struct VideoInspector: View {
    @Environment(\.style) private var style
    let model: VideoEditorModel
    static let width: CGFloat = 288
    static let inset: CGFloat = 16

    var body: some View {
        VStack(spacing: 0) {
            ToolSegments(options: VideoEditorModel.InspectorTab.allCases.map { ($0, Self.title($0)) }, label: "Inspector",
                         selection: Binding(get: { model.tab }, set: { model.tab = $0 }))
                .frame(maxWidth: .infinity).frame(height: 48)
            style.color(\.line).frame(height: 1)
            switch model.tab {
            case .clip: scroll { VideoClipTab(model: model) }
            case .zoom: scroll { VideoZoomTab(model: model) }
            case .backdrop:
                BackdropPanel(backdrop: model.edit.backdrop, set: model.setBackdrop, live: model.previewBackdrop, subject: model.poster,
                              video: BackdropPanel.VideoLookControls(look: model.edit.look, apply: model.applyPreset, setShape: model.setShape))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .onDisappear(perform: model.settle)
            case .export: scroll { VideoExportTab(model: model) }
            }
        }
        .disabled(!model.loaded)
    }

    private func scroll(@ViewBuilder _ content: () -> some View) -> some View {
        ScrollView(.vertical) { content().frame(maxWidth: .infinity, alignment: .leading) }.scrollIndicators(.never)
    }

    static func title(_ tab: VideoEditorModel.InspectorTab) -> String {
        switch tab {
        case .clip: "Clip"
        case .zoom: "Zoom"
        case .backdrop: "Backdrop"
        case .export: "Export"
        }
    }
}

/// One of the inspector's groups: its eyebrow, then its rows, a hairline under it.
struct InspectorGroup<Content: View>: View {
    @Environment(\.style) private var style
    let title: String
    var rule = true
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title.uppercased()).styleText(\.eyebrow).foregroundStyle(style.color(\.text3)).lineLimit(1).accessibilityAddTraits(.isHeader)
            content
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, VideoInspector.inset).padding(.vertical, 14)
        .overlay(alignment: .bottom) { if rule { style.color(\.line).frame(height: 1) } }
    }
}

/// A row of the inspector: its name at the left, its value at the right.
struct InspectorRow<Value: View>: View {
    @Environment(\.style) private var style
    let name: String
    @ViewBuilder let value: Value

    var body: some View {
        HStack(spacing: 8) {
            Text(name).styleText(\.body).foregroundStyle(style.color(\.text2)).lineLimit(1)
            Spacer(minLength: 8)
            value
        }
    }
}

/// The style's segments at the inspector's width, from its leading edge: Toybox's drawn at 85 %, as ToolSegments draws
/// them, but measured at that size, so six speeds never push the column wider than the inspector.
struct InspectorSegments<Value: Hashable>: View {
    @Environment(\.style) private var style
    let options: [(value: Value, title: String)]
    let label: String
    @Binding var selection: Value

    var body: some View {
        if style.kind == .toybox {
            ToySegments(selection: $selection, options: options, label: label).fixedSize()
                .scaleEffect(0.85, anchor: .leading)
                .frame(width: VideoInspector.width - 2 * VideoInspector.inset, height: 34, alignment: .leading)
        } else {
            InstrumentSegments(options: options, selection: $selection, height: 22).fixedSize()
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

/// Mono words on the chip face: the recording's length and size, the export's pixels, a picked value.
struct MonoChip: View {
    @Environment(\.style) private var style
    let text: String
    var size: CGFloat = 11
    var colour: KeyPath<StyleColors, Paint> = \.text2

    var body: some View {
        Text(verbatim: text).font(style.font(\.mono, size: size)).foregroundStyle(style.color(colour)).monospacedDigit().lineLimit(1).fixedSize()
            .padding(.horizontal, 8).padding(.vertical, 3).chipFace(style)
    }
}

/// A time with its key on the chip face (the trim's "0:01.0  I"); a click sets it at the playhead.
struct TimeChip: View {
    @Environment(\.style) private var style
    let time: Double
    let key: String
    let help: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Text(VideoTransport.time(time)).foregroundStyle(style.color(\.text))
                Text(key).foregroundStyle(style.color(\.text3))
            }
            .font(style.font(\.mono, size: 11)).monospacedDigit().fixedSize()
            .padding(.horizontal, 8).padding(.vertical, 4).chipFace(style)
        }
        .buttonStyle(.plain).help(help)
    }
}

/// Clip: the picked blur when there is one; where the export starts and ends; the part under the playhead (split, cut,
/// its own speed) with the still parts to cut; the whole clip's speed with the length it keeps, the pointer Pilot draws,
/// the crop's kept size with Crop (C), and the export's format and size, a click away on the Export tab.
struct VideoClipTab: View {
    @Environment(\.style) private var style
    let model: VideoEditorModel

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let (blur, index, count) = model.pickedBlur {
                InspectorGroup(title: "Blur \(index) of \(count) · \(VideoTransport.time(blur.start)) – \(VideoTransport.time(blur.end))") {
                    Text("Drag the box on the preview over what to hide, and the block on the Blur lane to time it.")
                        .styleText(\.caption).foregroundStyle(style.color(\.text3)).fixedSize(horizontal: false, vertical: true)
                    Button(action: model.deleteSelected) { Label("Delete blur  ⌫", systemImage: "trash") }
                        .buttonStyle(.pilot).help("Delete this blur  ⌫")
                }
            }
            InspectorGroup(title: "Trim") {
                InspectorRow(name: "Starts") {
                    TimeChip(time: model.edit.trimIn, key: "I", help: "Start the export at the playhead  I") { model.trimAtPlayhead(start: true) }
                }
                InspectorRow(name: "Ends") {
                    TimeChip(time: model.edit.trimOut, key: "O", help: "End the export at the playhead  O") { model.trimAtPlayhead(start: false) }
                }
            }
            VideoPartGroup(model: model)
            InspectorGroup(title: "Speed") {
                InspectorSegments(options: VideoEdit.speeds.map { ($0, VideoTransport.times($0)) }, label: "Speed",
                             selection: Binding(get: { model.edit.speed }, set: model.setSpeed))
                Text("Every part without its own. Kept: \(VideoTransport.time(model.length))").styleText(\.caption).foregroundStyle(style.color(\.text3))
            }
            VideoPointerGroup(model: model)
            InspectorGroup(title: "Crop") {
                HStack(spacing: 8) {
                    Text(verbatim: cropText).font(style.font(\.mono, size: 11)).foregroundStyle(style.color(\.text)).monospacedDigit()
                        .lineLimit(1).minimumScaleFactor(0.8)
                    Spacer(minLength: 8)
                    Button { model.cropping ? model.finishCrop(keep: true) : model.startCrop() } label: {
                        ActionCap(symbol: "crop", label: "Crop", lit: model.cropping, key: "C")
                    }
                    .buttonStyle(.plain).help(model.cropping ? "Keep this crop  C" : "Crop the frame  C")
                }
                if model.edit.crop != nil, !model.cropping {
                    Button("Whole frame", action: model.uncrop).buttonStyle(.pilot)
                        .help("Undo the crop: the whole frame again")
                }
            }
            InspectorGroup(title: "Export · next tab", rule: false) {
                Button { model.tab = .export } label: {
                    VStack(spacing: 8) {
                        InspectorRow(name: "Format") { MonoChip(text: model.format.title, colour: \.text) }
                        InspectorRow(name: "Size") { MonoChip(text: model.exportSize.title, colour: \.text) }
                    }
                    .contentShape(.rect)
                }
                .buttonStyle(.plain).help("Set them on the Export tab")
            }
        }
    }

    /// "2000 × 1330 of 2560 × 1600", or the whole frame's size.
    private var cropText: String {
        let size = model.size
        guard let crop = model.cropping ? model.cropDraft : model.edit.crop, crop != VideoEdit.wholeFrame else {
            return "Whole frame · \(Int(size.width)) × \(Int(size.height))"
        }
        return "\(Int((crop.width * size.width).rounded())) × \(Int((crop.height * size.height).rounded())) of \(Int(size.width)) × \(Int(size.height))"
    }
}

/// The part under the playhead (R5, R6): Split (S), Cut or Keep (X), its own speed or the clip's; then R7's still parts
/// with one button to cut them all.
struct VideoPartGroup: View {
    @Environment(\.style) private var style
    let model: VideoEditorModel

    var body: some View {
        let (part, index, count) = model.currentPart
        InspectorGroup(title: "Part \(index) of \(count) · \(VideoTransport.time(part.start)) – \(VideoTransport.time(part.end))") {
            HStack(spacing: 8) {
                Button(action: model.split) { Label("Split  S", systemImage: "scissors") }
                    .buttonStyle(.pilot).help("Split the part at the playhead  S")
                Button(action: model.toggleCut) { Label(part.cut ? "Keep  X" : "Cut  X", systemImage: part.cut ? "arrow.uturn.backward" : "minus.circle") }
                    .buttonStyle(.pilot).help(part.cut ? "Keep this part in the export  X" : "Cut this part out of the export  X")
            }
            if part.cut {
                Text("Cut: the export goes straight past it.").styleText(\.caption).foregroundStyle(style.color(\.text3))
            } else {
                InspectorSegments(options: [(0.0, "Clip")] + ClipPart.speeds.map { ($0, VideoTransport.times($0)) }, label: "Part speed",
                                  selection: Binding(get: { part.speed ?? 0 }, set: { model.setPartSpeed($0 == 0 ? nil : $0) }))
                Text(part.speed == nil ? "At the clip's speed, \(VideoTransport.times(model.edit.speed))." : "Its own speed: only this part.")
                    .styleText(\.caption).foregroundStyle(style.color(\.text3))
            }
            let still = model.stillParts
            if !still.isEmpty {
                InspectorRow(name: "\(still.count) still part\(still.count == 1 ? "" : "s") · \(VideoTransport.time(still.reduce(0) { $0 + $1.upperBound - $1.lowerBound }))") {
                    Button("Cut them", action: model.cutStillParts).buttonStyle(.pilot)
                        .help("Cut where the pointer stood still or left the frame, as dashed under the clip")
                }
            } else if model.pointer != nil {
                Text("No still parts left to cut.").styleText(\.caption).foregroundStyle(style.color(\.text3))
            }
        }
    }
}

/// The pointer Pilot draws (T29): Smooth (R1), its size (R2) and Hide when still (R3) on a recording that kept the pointer
/// out of its picture; Click ring (R4) on any recording with clicks on its track. An older recording has its pointer in
/// its picture: R1–R3 show off, and say why.
struct VideoPointerGroup: View {
    @Environment(\.style) private var style
    let model: VideoEditorModel

    var body: some View {
        let look = model.edit.pointer, drawn = model.pointer?.drawn == true, clicks = !(model.pointer?.clicks.isEmpty ?? true)
        InspectorGroup(title: "Pointer") {
            Group {
                Toggle("Smooth", isOn: Binding(get: { drawn && look.smooth }, set: { on in model.setPointer { $0.smooth = on } }))
                    .toggleStyle(.pilotSwitchRow(info: "Shaky movement comes out steady; it still lands on every click."))
                Text("SIZE").styleText(\.eyebrow).foregroundStyle(style.color(\.text3))
                InspectorSegments(options: PointerLook.sizes.map { ($0, VideoTransport.times($0)) }, label: "Pointer size",
                                  selection: Binding(get: { drawn ? look.size : 1 }, set: { size in model.setPointer { $0.size = size } }))
                Toggle("Hide when still", isOn: Binding(get: { drawn && look.hideStill }, set: { on in model.setPointer { $0.hideStill = on } }))
                    .toggleStyle(.pilotSwitchRow(info: "The pointer fades once it stops, and is back just before it moves."))
            }
            .disabled(!drawn)
            Toggle("Click ring", isOn: Binding(get: { clicks && look.clickRing }, set: { on in model.setPointer { $0.clickRing = on } }))
                .toggleStyle(.pilotSwitchRow(info: "A ring in your theme's halo colour on every click."))
                .disabled(!clicks)
            if !drawn {
                Text(model.pointer == nil ? "This recording has no pointer track, so Pilot can't draw its pointer."
                     : "This recording has its pointer in the picture. New recordings let Pilot draw it: smooth, bigger, hidden when still.")
                    .styleText(\.caption).foregroundStyle(style.color(\.text3)).fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

/// Zoom: the picked zoom's place and times, its level, and its focus (follow the pointer, or hold one of nine places);
/// with none picked, how to pick or add one; then motion blur for every zoom (R10).
struct VideoZoomTab: View {
    @Environment(\.style) private var style
    let model: VideoEditorModel
    static let levels: [Double] = [1.5, 2, 2.5, 3]

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            picked
            InspectorGroup(title: "Every zoom", rule: false) {
                Toggle("Motion blur", isOn: Binding(get: { model.edit.motionBlur }, set: model.setMotionBlur))
                    .toggleStyle(.pilotSwitchRow(info: "Fast zooms and a moving frame come out soft, as a camera blurs them."))
            }
        }
    }

    @ViewBuilder private var picked: some View {
        if let (zoom, index, count) = model.pickedZoom {
            VStack(alignment: .leading, spacing: 0) {
                InspectorGroup(title: "Zoom \(index) of \(count) · \(VideoTransport.time(zoom.start)) – \(VideoTransport.time(zoom.end))") {
                    Text("LEVEL").styleText(\.eyebrow).foregroundStyle(style.color(\.text3))
                    InspectorSegments(options: Self.levels.map { ($0, VideoTransport.times($0)) }, label: "Zoom level",
                                 selection: Binding(get: { Self.levels.min { abs($0 - zoom.level) < abs($1 - zoom.level) } ?? 2 }, set: model.setLevel))
                    Text("FOCUS").styleText(\.eyebrow).foregroundStyle(style.color(\.text3)).padding(.top, 4)
                    InspectorSegments(options: [(false, "Follow the pointer"), (true, "Hold one place")], label: "Focus",
                                 selection: Binding(get: { zoom.focus != nil }, set: { hold in
                                     model.setFocus(hold ? (zoom.focus ?? CGPoint(x: 0.5, y: 0.5)) : nil)
                                 }))
                    if zoom.focus != nil {
                        FocusPicker(focus: zoom.focus, set: model.setFocus)
                    } else if model.pointer == nil {
                        Text("This recording has no pointer to follow: the zoom holds the middle.").styleText(\.caption).foregroundStyle(style.color(\.text3))
                    }
                    Text(about(zoom)).styleText(\.caption).foregroundStyle(style.color(\.text3)).fixedSize(horizontal: false, vertical: true)
                    Button(action: model.deleteSelected) {
                        Label("Delete zoom  ⌫", systemImage: "trash")
                    }
                    .buttonStyle(.pilot).help("Delete this zoom  ⌫")
                }
            }
        } else {
            InspectorGroup(title: model.edit.zooms.isEmpty ? "No zooms" : "\(model.edit.zooms.count) zoom\(model.edit.zooms.count == 1 ? "" : "s")") {
                Text("Pick a zoom on the zoom lane to set it. Click the lane's empty room, or press Z, to add one at the playhead.")
                    .styleText(\.caption).foregroundStyle(style.color(\.text3)).fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func about(_ zoom: ZoomSegment) -> String {
        let made = model.click(in: zoom).map { "Made from your click at \(VideoTransport.time($0)). " } ?? ""
        return made + "Drag it on the lane to move it, drag an edge to stretch it."
    }
}

/// Export: MP4, HEVC or GIF; the shape (R9, also on the Backdrop tab); full size, 1080p or 720p; the file's pixels and
/// length; Export, or the run's progress.
struct VideoExportTab: View {
    @Environment(\.style) private var style
    let model: VideoEditorModel

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            InspectorGroup(title: "Format") {
                InspectorSegments(options: VideoFormat.allCases.map { ($0, $0.title) }, label: "Format", selection: Binding(get: { model.format }, set: { model.format = $0 }))
            }
            InspectorGroup(title: "Shape") {
                InspectorSegments(options: VideoShape.allCases.map { ($0, $0.title) }, label: "Shape", selection: Binding(get: { model.edit.shape }, set: model.setShape))
            }
            InspectorGroup(title: "Size") {
                InspectorSegments(options: VideoSize.allCases.map { ($0, $0.title) }, label: "Size", selection: Binding(get: { model.exportSize }, set: { model.exportSize = $0 }))
                let px = model.exportPixels
                MonoChip(text: model.loaded ? "\(Int(px.width)) × \(Int(px.height)) · \(VideoTransport.time(model.length))\(model.format == .gif ? " · \(VideoFormat.gifFPS) fps" : "")" : "—")
            }
            InspectorGroup(title: "File", rule: false) {
                Text("Saved beside the recording as “\(model.url.deletingPathExtension().lastPathComponent) edited.\(model.format.fileExtension)”; Show in the tip opens it.")
                    .styleText(\.caption).foregroundStyle(style.color(\.text3)).fixedSize(horizontal: false, vertical: true)
                if let format = model.exportingFormat {
                    Text("Exporting \(format.title): its progress and Cancel are in the bar.").styleText(\.caption)
                        .foregroundStyle(style.color(\.text2)).fixedSize(horizontal: false, vertical: true)
                } else {
                    ExportButton(model: model)
                }
            }
        }
    }
}

/// Diagonal lines 6 points apart across a rect (a cut part), or upright ones (a suggested still part).
struct Hatch: Shape {
    var vertical = false

    func path(in rect: CGRect) -> Path {
        var path = Path()
        var x = rect.minX - (vertical ? 0 : rect.height)
        while x < rect.maxX {
            path.move(to: CGPoint(x: x, y: rect.maxY))
            path.addLine(to: CGPoint(x: x + (vertical ? 0 : rect.height), y: rect.minY))
            x += 6
        }
        return path
    }
}

/// The playhead through the timeline: a view of its own, so playback's 30 moves a second redraw it and nothing else.
struct Playhead: View {
    @Environment(\.style) private var style
    let model: VideoEditorModel
    /// Where the timeline's zero is, from its left.
    let lead: CGFloat
    let width: CGFloat
    let top: CGFloat
    let bottom: CGFloat

    var body: some View {
        let x = lead + CGFloat(model.playhead / max(model.edit.duration, 0.01)) * width
        ZStack(alignment: .topLeading) {
            Rectangle().fill(style.color(\.text)).frame(width: 1.5, height: bottom - top).offset(x: x - 0.75, y: top)
            RoundedRectangle(cornerRadius: 2, style: .continuous).fill(style.color(\.text)).frame(width: 9, height: 12).offset(x: x - 4.5, y: top)
        }
        .allowsHitTesting(false)
    }
}
