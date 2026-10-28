import AppKit
import PilotCore
import SwiftUI

/// Capture markup (P72, after Snapzy's): marks drawn straight on the frozen screen inside the area just picked, before
/// anything is saved. The editor's own model runs it (EditorModel, no window): its tools on their keys (2 arrow to
/// 0 step, the select tool and the editor-only ones left out), its six colours, ⌘Z, Return to save and Escape twice to
/// throw marks away; a bar under the area offers the same to the pointer. Points here are the display's; the model's
/// are the area's.
@MainActor
final class CaptureMarkup {
    enum Button: Equatable { case tool(MarkTool), colour(Int), undo, cancel, save }

    static let tools: [MarkTool] = [.arrow, .rect, .ellipse, .text, .pen, .highlighter, .blur, .box, .step]

    /// The area in the display's points, on whole pixels of the still.
    let area: CGRect
    let model: EditorModel
    /// The pointer went down on the area, so a drag draws; false for one that began on the bar or outside.
    private var drawing = false
    /// The bar's buttons where they were last drawn, and the bar.
    private(set) var buttons: [(frame: CGRect, button: Button)] = []
    private var barFrame: CGRect = .null
    /// The bar's symbols, drawn once each in either tint.
    private var symbols: [String: NSImage] = [:]

    /// What an event can change: the area and the bar, so a drag never redraws the whole display.
    var dirty: CGRect { area.union(barFrame).insetBy(dx: -4, dy: -4) }

    /// Nil for an area with no pixels.
    init?(grab: DisplayGrab, area: CGRect, accent: UInt32) {
        let pixels = CaptureSelection.pixels(area, scale: grab.scale, within: CGSize(width: grab.image.width, height: grab.image.height))
        guard !pixels.isEmpty, let cut = grab.image.cropping(to: pixels) else { return nil }
        let s = grab.scale
        self.area = CGRect(x: pixels.minX / s, y: pixels.minY / s, width: pixels.width / s, height: pixels.height / s)
        model = EditorModel(image: cut, scale: s, accent: accent, dark: true)
    }

    private func local(_ p: CGPoint) -> CGPoint { CGPoint(x: p.x - area.minX, y: p.y - area.minY) }

    // MARK: Pointer and keys

    func button(at p: CGPoint) -> Button? { buttons.first { $0.frame.contains(p) }?.button }

    func mouseDown(_ p: CGPoint, shift: Bool) {
        if let button = button(at: p) { return press(button) }
        drawing = area.contains(p)
        if drawing { model.begin(local(p), shift: shift) } else { model.commitText() }
    }

    func mouseDragged(_ p: CGPoint) { if drawing { model.drag(local(p)) } }

    func mouseUp(_ p: CGPoint) {
        guard drawing else { return }
        drawing = false
        model.end(local(p))
    }

    func press(_ button: Button) {
        switch button {
        case .tool(let tool): model.pick(tool)
        case .colour(let i): model.setColour(i)
        case .undo: model.undo()
        case .cancel: model.finish(.cancel)
        case .save: model.finish(.done)
        }
    }

    /// A key while marking up; true when it was the markup's. Text being typed takes every printable key, Delete its
    /// last character; otherwise the editor's keys, the select tool and the editor-only tools aside.
    func key(_ event: NSEvent) -> Bool {
        guard let key = EditorPanel.key(event) else { return false }
        if model.typing != nil {
            switch key {
            case .delete: if !model.typed.isEmpty { model.typed.removeLast() }
            case .char(let c, command: false, shift: _): model.typed += event.characters ?? c
            default: return model.key(key)
            }
            return true
        }
        if case .char(let c, command: false, shift: _) = key, let tool = MarkTool.picked(by: c), !Self.tools.contains(tool) { return true }
        return model.key(key)
    }

    // MARK: Drawing

    /// The marks, the area's ring and the bar, over the dimmed still the view has drawn.
    func draw(in bounds: CGRect, accent: NSColor) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        ctx.saveGState()
        ctx.clip(to: area)
        ctx.translateBy(x: area.minX, y: area.minY)
        MarkupRenderer.draw(shown(), in: ctx, image: model.image, scale: model.scale, size: model.size)
        ctx.restoreGState()
        accent.setStroke()
        let ring = NSBezierPath(rect: area.insetBy(dx: -0.5, dy: -0.5))
        ring.lineWidth = 1
        ring.stroke()
        bar(in: bounds, accent: accent)
    }

    /// The marks as they look now: the one being typed with its words so far and a caret, and the one being drawn.
    func shown() -> [Mark] {
        var marks = model.document.marks.map { mark in
            guard mark.id == model.typing, case .text(_, let at, let pill) = mark.kind else { return mark }
            var m = mark
            m.kind = .text(model.typed + "▏", at: at, pill: pill)
            return m
        }
        if let draft = model.draft { marks.append(draft) }
        return marks
    }

     /// The bar: the tools, the six colours, Undo, Cancel and Save, under the area, above it when there is no room, else
    /// inside its foot; always clear of the hint line at the display's foot.
    private func bar(in bounds: CGRect, accent: NSColor) {
        let gap: CGFloat = 4, pad: CGFloat = 6, cap: CGFloat = 28
        let words: [(Button, String)] = [(.undo, "Undo"), (.cancel, "Esc"), (.save, "Save ⏎")]
        let attrs = Self.word
        let wordSizes = words.map { ($0.1 as NSString).size(withAttributes: attrs) }
        let wordWidths = wordSizes.map { $0.width + 16 }
        let palette = model.palette
        let width = pad * 2 + CGFloat(Self.tools.count) * (cap + gap) + 8 + CGFloat(palette.count) * (cap - 6 + gap) + 8
            + wordWidths.reduce(0) { $0 + $1 + gap } - gap
        let height = cap + pad * 2
        let floor = bounds.maxY - 60
        var y = area.maxY + 8
        if y + height > floor { y = area.minY - 8 - height }
        if y < bounds.minY + 8 { y = min(area.maxY, floor) - 8 - height }
        let x = min(max(area.midX - width / 2, bounds.minX + 8), bounds.maxX - width - 8)
        let frame = CGRect(x: x, y: y, width: width, height: height)
        barFrame = frame
        NSColor(white: 0.1, alpha: 0.92).setFill()
        NSBezierPath(roundedRect: frame, xRadius: height / 2, yRadius: height / 2).fill()
        NSColor.white.withAlphaComponent(0.14).setStroke()
        NSBezierPath(roundedRect: frame.insetBy(dx: 0.5, dy: 0.5), xRadius: height / 2, yRadius: height / 2).stroke()
        buttons = []
        var cx = frame.minX + pad + 4
        let cy = frame.minY + pad
        for tool in Self.tools {
            let r = CGRect(x: cx, y: cy, width: cap, height: cap)
            let picked = model.tool == tool
            if picked {
                accent.withAlphaComponent(0.3).setFill()
                NSBezierPath(roundedRect: r, xRadius: 7, yRadius: 7).fill()
            }
            symbol(ToolCap.symbol(tool), in: r, tint: picked ? accent : NSColor.white.withAlphaComponent(0.85))
            (tool.key as NSString).draw(at: CGPoint(x: r.maxX - 7, y: r.maxY - 11), withAttributes: Self.keyCap)
            buttons.append((r, .tool(tool)))
            cx += cap + gap
        }
        cx += 8
        let current = model.colourIndex(of: model.tool)
        for (i, rgb) in palette.enumerated() {
            let r = CGRect(x: cx, y: cy + 3, width: cap - 6, height: cap - 6)
            NSColor(Color(hex: rgb)).setFill()
            NSBezierPath(ovalIn: r.insetBy(dx: 3, dy: 3)).fill()
            if i == current {
                NSColor.white.setStroke()
                let ring = NSBezierPath(ovalIn: r.insetBy(dx: 0.75, dy: 0.75))
                ring.lineWidth = 1.5
                ring.stroke()
            }
            buttons.append((r, .colour(i)))
            cx += cap - 6 + gap
        }
        cx += 8
        for (((button, word), w), size) in zip(zip(words, wordWidths), wordSizes) {
            let r = CGRect(x: cx, y: cy, width: w, height: cap)
            if button == .save {
                accent.setFill()
                NSBezierPath(roundedRect: r, xRadius: 7, yRadius: 7).fill()
            }
            (word as NSString).draw(at: CGPoint(x: r.midX - size.width / 2, y: r.midY - size.height / 2), withAttributes: attrs)
            buttons.append((r, button))
            cx += w + gap
        }
    }

    private static let word: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 12, weight: .semibold), .foregroundColor: NSColor.white]
    private static let keyCap: [NSAttributedString.Key: Any] = [.font: NSFont.monospacedSystemFont(ofSize: 7.5, weight: .bold),
                                                                .foregroundColor: NSColor.white.withAlphaComponent(0.5)]

    private func symbol(_ name: String, in r: CGRect, tint: NSColor) {
        let key = "\(name) \(tint.hash)"
        let made = symbols[key] ?? NSImage(systemSymbolName: name, accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 13, weight: .semibold).applying(.init(paletteColors: [tint])))
        guard let image = made else { return }
        symbols[key] = image
        let s = image.size
        image.draw(in: CGRect(x: r.midX - s.width / 2, y: r.midY - s.height / 2, width: s.width, height: s.height), from: .zero,
                   operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
    }
}
