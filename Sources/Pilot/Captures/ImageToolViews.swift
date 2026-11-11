import ImageScale
import PilotCore
import SwiftUI

// Resize and Upscale's settings (Q246-Q248), one set of views for the capture editor's popovers and Finder's panel:
// the editor's chrome parts (StyleTokens, Instrument's and Toybox's own), nothing new.

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

/// The size, as Upscayl, Gigapixel and Photoshop's Image Size offer it (build 62): 2x, 3x, 4x, or Custom's width or height
/// with the aspect kept; the result's size before the run; the model (Max quality says its download before it starts
/// one); the format; and the run's progress. Nothing the models ignore (denoise, faces, tile size) is offered.
struct UpscaleOptions: View {
    @Environment(\.style) private var style
    let job: UpscaleJob
    /// Custom picked: the width and height fields show, whatever the size is.
    @State private var custom = false

    var body: some View {
        let target = job.target
        VStack(alignment: .leading, spacing: 10) {
            VStack(alignment: .leading, spacing: 10) {
                row("Size") {
                    ToolSegments(options: UpscaleTarget.presets.map { ($0, "\($0)x") } + [(0, "Custom"), (-1, "Monitor")], label: "Size", compact: true,
                                 selection: Binding(get: { target.monitor != nil ? -1 : custom ? 0 : target.times ?? 0 }, set: { n in
                                     custom = n == 0
                                     if n == -1 { job.target.setMonitor(.ultrawide34) }
                                     else if n > 0 { job.target.setFactor(Double(n)) }
                                     else if target.monitor != nil { job.target.setFactor(target.factor) }
                                 }))
                }
                if let monitor = target.monitor {
                    row("Monitor") {
                        Menu {
                            ForEach(UpscaleTarget.Monitor.allCases, id: \.self) { preset in
                                Button(preset.label) { job.target.setMonitor(preset, framing: target.framing) }
                            }
                        } label: {
                            HStack {
                                Text(monitor.title).styleText(\.caption).lineLimit(1)
                                Spacer(minLength: 4)
                                Image(systemName: "chevron.down").font(.system(size: 9, weight: .semibold))
                            }
                            .foregroundStyle(style.color(\.text)).padding(.horizontal, 8).frame(height: 26)
                            .background(style.color(\.sunken), in: RoundedRectangle(cornerRadius: style.radii.control))
                            .overlay(RoundedRectangle(cornerRadius: style.radii.control).stroke(style.color(\.line2), lineWidth: 1))
                        }
                        .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden)
                        .accessibilityLabel("Monitor preset").accessibilityValue(monitor.label)
                    }
                    row("Framing") {
                        ToolSegments(options: UpscaleTarget.Framing.allCases.map { ($0, $0.title) }, label: "Framing",
                                     selection: Binding(get: { target.framing }, set: { job.target.setMonitor(monitor, framing: $0) }))
                    }
                } else if custom || target.times == nil {
                    HStack(alignment: .bottom, spacing: 8) {
                        PixelField(title: "Width", value: target.width) { job.target.setWidth($0) }
                        Image(systemName: "lock.fill").font(.system(size: 11, weight: .semibold)).foregroundStyle(style.color(\.text3))
                            .frame(width: 22, height: 28).help("The aspect is kept: the other side follows")
                        PixelField(title: "Height", value: target.height) { job.target.setHeight($0) }
                        Text("px").styleText(\.caption).foregroundStyle(style.color(\.text3)).frame(height: 28)
                    }
                    .padding(.leading, 56)
                }
                row("Result") {
                    Text(verbatim: "\(target.originalWidth) × \(target.originalHeight)  →  \(target.width) × \(target.height) px")
                        .styleText(\.caption).foregroundStyle(style.color(\.text)).monospacedDigit().lineLimit(1).fixedSize()
                }
                if let monitor = target.monitor {
                    VStack(alignment: .leading, spacing: 4) {
                        GeometryReader { proxy in
                            if let image = job.preview {
                                Image(decorative: image, scale: 1).resizable()
                                    .aspectRatio(contentMode: target.crops ? .fill : .fit)
                                    .frame(width: proxy.size.width, height: proxy.size.height).clipped()
                            } else {
                                Text("Loading preview…").styleText(\.caption).foregroundStyle(style.color(\.text3))
                                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                            }
                        }
                        .aspectRatio(CGFloat(monitor.size.width) / CGFloat(monitor.size.height), contentMode: .fit)
                        .background(style.color(\.sunken))
                        .clipShape(RoundedRectangle(cornerRadius: style.radii.control))
                        .overlay(RoundedRectangle(cornerRadius: style.radii.control).stroke(style.color(\.line2), lineWidth: 1))
                        Text(target.crops ? "Centred crop · \(monitor.size.width) × \(monitor.size.height) px" : "Fits inside \(monitor.size.width) × \(monitor.size.height) · no crop")
                            .styleText(\.small).foregroundStyle(style.color(\.text3))
                    }
                    if let issue = target.issue {
                        Text(issue).styleText(\.caption).foregroundStyle(style.color(\.text2)).fixedSize(horizontal: false, vertical: true)
                    }
                }
                row("Model") {
                    ToolSegments(options: UpscaleModel.allCases.map { ($0, $0.title) }, label: "Model",
                                 selection: Binding(get: { job.model }, set: { job.model = $0 }))
                }
                Text(note).styleText(\.caption).foregroundStyle(style.color(\.text3)).fixedSize(horizontal: false, vertical: true)
                row("Format") {
                    ToolSegments(options: ImageFormat.allCases.map { ($0, $0.title) }, label: "Format",
                                 selection: Binding(get: { job.format }, set: { job.format = $0 }))
                }
            }
            .disabled(job.busy)
            switch job.phase {
            case .idle: EmptyView()
            case .downloading:
                HStack(spacing: 8) { ProgressView().controlSize(.small); Text("Downloading \(megabytes) MB…").styleText(\.caption).foregroundStyle(style.color(\.text2)) }
            case .running(let share, let label):
                VStack(alignment: .leading, spacing: 4) {
                    ProgressView(value: share).progressViewStyle(.linear).tint(style.color(\.accent))
                    Text("Upscaling \(label)").styleText(\.caption).foregroundStyle(style.color(\.text2)).lineLimit(1).truncationMode(.middle)
                }
            case .failed(let why):
                Text(why).styleText(\.caption).foregroundStyle(Color(Paint(EditorModel.red)))
            }
        }
    }

    private var megabytes: Int { Int((Double(job.model.download?.bytes ?? 0) / 1_000_000).rounded()) }

    private var note: String {
        switch job.model {
        case .general: "Built in. Quick, and good on screenshots and photos."
        case .max: job.ready ? "Sharper on photos; about three times slower." : "Downloads \(megabytes) MB once, from Hugging Face, when you start."
        }
    }

    private func row(_ title: String, @ViewBuilder _ content: () -> some View) -> some View {
        HStack(spacing: 10) {
            Text(title).styleText(\.caption).foregroundStyle(style.color(\.text3)).frame(width: 46, alignment: .leading)
            content()
        }
    }

    /// The primary button's words: Max quality's first run says it downloads.
    static func action(_ job: UpscaleJob) -> String { job.ready ? "Upscale" : "Download and upscale" }
    /// Upscale can start: nothing running, and the size bigger than the image's.
    static func runs(_ job: UpscaleJob) -> Bool { !job.busy && job.target.issue == nil }
}

/// Instrument's or Toybox's segments, as the editor's footer picks them.
struct ToolSegments<Value: Hashable>: View {
    @Environment(\.style) private var style
    let options: [(value: Value, title: String)]
    let label: String
    var compact = false
    @Binding var selection: Value

    var body: some View {
        Group {
            if style.kind == .toybox {
                ToySegments(selection: $selection, options: options, label: label)
                    .scaleEffect(compact ? 0.72 : 0.85, anchor: .leading).frame(width: compact ? 250 : nil, height: 34, alignment: .leading)
            }
            else { InstrumentSegments(options: options, selection: $selection, height: 22) }
        }
        .fixedSize()
    }
}

/// A primary and a ghost button in the style.
struct ToolButtons: View {
    @Environment(\.style) private var style
    let primary: String
    var disabled = false
    var cancelTitle = "Cancel"
    let run: () -> Void
    let cancel: () -> Void

    var body: some View {
        HStack(spacing: 6) {
            if style.kind == .toybox {
                Button(cancelTitle, action: cancel).buttonStyle(ToyFaceStyle(ghost: true))
                Button(primary, action: run).buttonStyle(ToyFaceStyle(primary: true)).disabled(disabled)
            } else {
                Button(cancelTitle, action: cancel).buttonStyle(InstrumentButtonStyle(kind: .ghost))
                Button(primary, action: run).buttonStyle(InstrumentButtonStyle(kind: .primary)).disabled(disabled)
            }
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
/// While an upscale runs, its settings wait and Cancel stops it.
struct ImageToolCard: View {
    @Environment(\.style) private var style
    let mode: ImageTools.Mode
    let files: [URL]
    @State var target: ResizeTarget
    let job: UpscaleJob
    let resize: (ResizeTarget) -> Void
    let upscale: () -> Void
    let cancel: () -> Void

    var body: some View {
        let name = files.count == 1 ? files[0].lastPathComponent : "\(files.count) images"
        switch mode {
        case .resize:
            ToolPanel(title: "Resize", subject: "\(name) · \(target.originalWidth) × \(target.originalHeight)") {
                ResizeOptions(target: $target)
                if files.count > 1 { Text("The others change by the same amount.").styleText(\.caption).foregroundStyle(style.color(\.text3)) }
            } buttons: {
                Spacer()
                ToolButtons(primary: "Resize", disabled: !target.changed, run: { resize(target) }, cancel: cancel)
            }
        case .upscale:
            ToolPanel(title: "Upscale", subject: name) {
                UpscaleOptions(job: job)
                if files.count > 1 { Text(job.target.monitor == nil ? "The others change by the same amount." : "Each image uses this monitor preset; framing is calculated separately.").styleText(\.caption).foregroundStyle(style.color(\.text3)) }
            } buttons: {
                Spacer()
                ToolButtons(primary: UpscaleOptions.action(job), disabled: !UpscaleOptions.runs(job), run: upscale, cancel: cancel)
            }
            .task(id: files.first) { if let first = files.first { await job.loadPreview(first) } }
        }
    }
}
