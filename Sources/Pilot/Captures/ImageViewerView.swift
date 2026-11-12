import AppKit
import PilotCore
import SwiftUI

/// The image viewer in the capture editor's look (B, Sven Q805): the sunken ground under everything; along the top the
/// picture's name and place in its folder at the left, the actions at the right (Mark up, Copy text, Copy, Show in
/// Finder, Move to Trash, Close); the picture centred in the room; along the bottom the previous and next pill, the line
/// a press leaves (with Undo after a Trash) and the View pill (zoom and the picture's size).
struct ImageViewerView: View {
    @Environment(\.style) private var style
    let model: ImageViewerModel

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: style.radii.pop, style: .continuous)
        VStack(spacing: 0) {
            ImageViewerTopBar(model: model).frame(height: EditorLayout.bar(style))
            Color.clear.frame(height: 1)
            ImageViewerCanvas(model: model)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .overlay(alignment: .bottom) { hint }
            Color.clear.frame(height: 1)
            ImageViewerFooter(model: model).padding(.horizontal, 12).frame(height: EditorLayout.foot(style))
        }
        // Solid, never Glass: nothing behind the window shows round a picture (Q161).
        .background { style.color(\.canvas) }
        .clipShape(shape)
        .overlay {
            if style.kind == .toybox { shape.strokeBorder(style.color(\.outline), lineWidth: 2) }
            else { shape.strokeBorder(style.color(\.line2)) }
        }
    }

    @ViewBuilder private var hint: some View {
        if let text = model.hint {
            let undo: (() -> Void)? = model.undo ? { model.undoTrash() } : nil
            EditorHint(text: text, undo: undo).padding(.bottom, 18)
        }
    }
}

/// The top row: the name pill, the drag room, the actions pill.
struct ImageViewerTopBar: View {
    @Environment(\.style) private var style
    let model: ImageViewerModel

    var body: some View {
        HStack(spacing: 0) {
            HStack(spacing: 8) {
                Text(verbatim: model.file.lastPathComponent).styleText(\.strong).foregroundStyle(style.color(\.text)).lineLimit(1).truncationMode(.middle)
                if model.files.count > 1 {
                    Text(verbatim: "\(model.index + 1) of \(model.files.count)").font(Font(EditorFooter.mono(style, 10.5)))
                        .foregroundStyle(style.color(\.text3)).monospacedDigit().fixedSize()
                }
            }
            .padding(.horizontal, 10).frame(height: EditorTopBar.cap(style).height + 8).frame(maxWidth: 420, alignment: .leading)
            .editorPill(fixed: false).fixedSize()
            WindowDragArea().frame(minWidth: 16, maxWidth: .infinity, maxHeight: .infinity)
            actions
        }
        .padding(.horizontal, 12)
    }

    private var actions: some View {
        HStack(spacing: EditorTopBar.gap(style)) {
            Button(action: model.markUp) { ActionCap(symbol: "pencil.tip.crop.circle", label: "Mark up") }
                .buttonStyle(.plain).help("Mark up in the capture editor  ⇧⌘A")
            Button { model.copyText() } label: { ActionCap(symbol: "text.viewfinder", label: "Copy text", lit: model.busy) }
                .buttonStyle(.plain).help("Read the text in the picture and copy it")
            Button(action: model.copy) { ActionCap(symbol: "doc.on.doc", label: "Copy") }.buttonStyle(.plain).help("Copy  ⌘C")
            Button(action: model.reveal) { ActionCap(symbol: "folder", label: "Show in Finder") }.buttonStyle(.plain).help("Show in Finder")
            Button(action: model.trash) { ActionCap(symbol: "trash", label: "Move to Trash") }.buttonStyle(.plain).help("Move to Trash  ⌘⌫")
            EditorRule().padding(.horizontal, 4)
            Button(action: model.close) { ActionCap(symbol: "xmark", label: "Close") }.buttonStyle(.plain).help("Close  Space · Esc")
        }
        .padding(4).editorPill()
    }
}

/// The picture on its room at the model's zoom, a hairline round it as round a capture; a double-click is actual size, or
/// the fit again; a drag moves a zoomed picture.
struct ImageViewerCanvas: View {
    @Environment(\.style) private var style
    let model: ImageViewerModel
    @State private var dragged: CGSize = .zero

    var body: some View {
        let size = model.size, zoom = model.zoom, origin = model.origin
        let shown = CGSize(width: size.width * zoom, height: size.height * zoom)
        // A plain image moved and sized by the zoom: a pan or pinch changes its frame, never redraws the picture.
        Color.clear
            .overlay(alignment: .topLeading) {
                if let image = model.image {
                    Image(decorative: image, scale: 1).resizable().interpolation(.high)
                        .frame(width: shown.width, height: shown.height)
                        .overlay { Rectangle().strokeBorder(Color(hex: style.dark ? 0xFFFFFF : 0x000000, opacity: 0.1)) }
                        .offset(x: origin.x, y: origin.y)
                }
            }
        .clipped()
        .overlay {
            if let problem = model.problem {
                Text(problem).styleText(\.strong).foregroundStyle(style.color(\.text2))
            }
        }
        .contentShape(Rectangle())
        .onTapGesture(count: 2) { at in model.toggleZoom(about: at) }
        .gesture(DragGesture(minimumDistance: 2).onChanged { g in
            model.pan(by: CGSize(width: g.translation.width - dragged.width, height: g.translation.height - dragged.height))
            dragged = g.translation
        }.onEnded { _ in dragged = .zero })
        .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { model.setRoom($0) }
        .accessibilityLabel(model.file.lastPathComponent)
    }
}

/// The bottom row: previous and next at the left, the View pill at the right.
struct ImageViewerFooter: View {
    @Environment(\.style) private var style
    let model: ImageViewerModel

    var body: some View {
        HStack(spacing: 12) {
            HStack(spacing: EditorTopBar.gap(style)) {
                Button { model.step(-1) } label: { ActionCap(symbol: "chevron.left", label: "Previous picture") }
                    .buttonStyle(.plain).help("Previous picture  ←")
                Button { model.step(1) } label: { ActionCap(symbol: "chevron.right", label: "Next picture") }
                    .buttonStyle(.plain).help("Next picture  →")
            }
            .padding(4).editorPill().disabled(!model.canStep)
            Spacer(minLength: 0)
            HStack(spacing: 6) {
                ZoomControl(model: model, font: Font(EditorFooter.mono(style, 10.5)))
                Text(verbatim: "\(Int(model.pixels.width)) × \(Int(model.pixels.height))").font(Font(EditorFooter.mono(style, 10.5)))
                    .foregroundStyle(style.color(\.text3)).monospacedDigit().lineLimit(1).fixedSize()
                    .padding(.horizontal, 7).chipFace(style)
                    .accessibilityLabel("Picture size \(Int(model.pixels.width)) by \(Int(model.pixels.height)) pixels")
            }
            .padding(4).editorPill()
        }
    }
}
