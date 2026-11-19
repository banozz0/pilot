import ImageScale
import PilotCore
import SwiftUI

// Resize's settings (Q246), one set of views for the capture editor's popover and Finder's panel:
// the editor's chrome parts (StyleTokens, Instrument's own), nothing new.

/// Width and height in pixels with the aspect lock between them, and the percent presets.
struct ResizeOptions: View {
    @Environment(\.style) private var style
    @Binding var target: ResizeTarget

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .bottom, spacing: 8) {
                PixelField(title: "Width", value: target.width) { target.setWidth($0) }
                Button { target.locked.toggle() } label: {
                    Image(systemName: target.locked ? "lock.fill" : "lock.open").font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(style.color(target.locked ? \.accentText : \.text3)).frame(width: 22, height: 28).contentShape(.rect)
                }
                .buttonStyle(.plain).help(target.locked ? "Aspect locked: the other side follows" : "Aspect unlocked")
                .accessibilityLabel("Lock aspect")
                PixelField(title: "Height", value: target.height) { target.setHeight($0) }
                Text("px").styleText(\.caption).foregroundStyle(style.color(\.text3)).frame(height: 28)
            }
            ToolSegments(options: [(0, "Custom")] + ResizeTarget.presets.map { ($0, "\($0)%") }, label: "Size",
                         selection: Binding(get: { target.percent ?? 0 }, set: { if $0 > 0 { target.setPercent($0) } }))
        }
    }
}

/// A side in pixels, titled above.
struct PixelField: View {
    @Environment(\.style) private var style
    let title: String
    let value: Int
    let set: (Int) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title).styleText(\.caption).foregroundStyle(style.color(\.text3))
            TextField(title, value: Binding(get: { value }, set: set), format: .number.grouping(.never))
                .pilotField().frame(width: 84).monospacedDigit()
        }
    }
}

/// Instrument's segments, as the editor's footer picks them.
struct ToolSegments<Value: Hashable>: View {
    let options: [(value: Value, title: String)]
    let label: String
    @Binding var selection: Value

    var body: some View {
        InstrumentSegments(options: options, selection: $selection, height: 22)
            .fixedSize()
    }
}

/// A primary and a ghost button in the style.
struct ToolButtons: View {
    let primary: String
    var disabled = false
    var cancelTitle = "Cancel"
    let run: () -> Void
    let cancel: () -> Void

    var body: some View {
        HStack(spacing: 6) {
            Button(cancelTitle, action: cancel).buttonStyle(InstrumentButtonStyle(kind: .ghost))
            Button(primary, action: run).buttonStyle(InstrumentButtonStyle(kind: .primary)).disabled(disabled)
        }
    }
}

/// The three panels' one shell (the editor's two popovers, Finder's card): title and subject, the settings, the buttons
/// at the foot.
struct ToolPanel<Content: View, Buttons: View>: View {
    @Environment(\.style) private var style
    let title: String
    var subject: String?
    @ViewBuilder let content: Content
    @ViewBuilder let buttons: Buttons

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).styleText(\.strong).foregroundStyle(style.color(\.text))
                if let subject {
                    Text(subject).styleText(\.caption).foregroundStyle(style.color(\.text3)).lineLimit(1).truncationMode(.middle)
                }
            }
            content
            HStack { buttons }
        }
        .padding(16)
        .frame(width: 340, alignment: .leading)
    }
}

/// Finder's panel, on the style's pop face (HUD.makePanel): what it acts on, its settings, Cancel and the one primary.
struct ImageToolCard: View {
    @Environment(\.style) private var style
    let files: [URL]
    @State var target: ResizeTarget
    let resize: (ResizeTarget) -> Void
    let cancel: () -> Void

    var body: some View {
        let name = files.count == 1 ? files[0].lastPathComponent : "\(files.count) images"
        ToolPanel(title: "Resize", subject: "\(name) · \(target.originalWidth) × \(target.originalHeight)") {
            ResizeOptions(target: $target)
            if files.count > 1 { Text("The others change by the same amount.").styleText(\.caption).foregroundStyle(style.color(\.text3)) }
        } buttons: {
            Spacer()
            ToolButtons(primary: "Resize", disabled: !target.changed, run: { resize(target) }, cancel: cancel)
        }
    }
}
