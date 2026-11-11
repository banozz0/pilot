import AppKit
import PilotCore
import SwiftUI

/// Files' first tab, Convert (Sven 2026-10-10: "the file converter is mentioned nowhere; it's a very good feature we
/// will be shipping"): story 139 said in full: a drop zone that converts what lands on it, the two ways in from Finder
/// and Hyper+Space, every format by kind and the two tools some need. Its second tab is File search (was Menu's).
struct ConvertPage: View {
    @Environment(\.ink) private var ink
    /// Hands dropped or chosen files to Convert's picker; a render passes one that records them.
    var offer: @MainActor ([URL]) -> Void = { ConvertFiles.offer($0) }
    /// The tools Homebrew has now, read as the page shows and when Pilot comes back to the front, never per redraw.
    @State private var tools: Set<ConvertTool>?
    @State private var targeted = false

    static let intro = "Convert pictures, video, sound and documents on this Mac. Nothing is uploaded."
    static let introInfo = "The new file lands beside the old one."

    static let otherWays = "Or in Finder: right-click, Services › Convert with Pilot…; in Hyper+Space: ⌘K on a file, Convert to…"

    var body: some View {
        KitPage(intro: Self.intro, info: Self.introInfo) {
            KitBlock(title: "Convert", symbol: "arrow.triangle.2.circlepath") {
                dropZone
                // The two other ways in, one line under the drop zone (simplify-pages T5).
                Text(Self.otherWays).font(ink.ui(12)).foregroundStyle(ink.muted).padding(.bottom, 10)
            }
            KitBlock(title: "Formats", symbol: "list.bullet") { formats }
        }
        .task { tools = Self.installedTools() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            let now = Self.installedTools()
            if now != tools { tools = now }
        }
    }

    private var dropZone: some View {
        let shape = RoundedRectangle(cornerRadius: ink.radius(10), style: .continuous)
        return VStack(spacing: 8) {
            Image(systemName: "arrow.down.doc").font(ink.ui(26)).foregroundStyle(targeted ? ink.accent : ink.muted)
            Text("Drop files here to convert them").font(ink.ui(13.5, .semibold))
            Text("Pick the format next; several files get the formats they share.").font(ink.ui(12)).foregroundStyle(ink.muted)
            Button("Choose files…") { choose() }.buttonStyle(.pilot).padding(.top, 2)
        }
        .frame(maxWidth: .infinity).padding(.vertical, 22)
        .background(targeted ? ink.accent.opacity(0.1) : .clear, in: shape)
        .overlay { shape.strokeBorder(targeted ? ink.accent : ink.edge, style: StrokeStyle(lineWidth: ink.stroke + 0.5, dash: [6, 4])) }
        .padding(.vertical, 10)
        .contentShape(shape)
        .dropDestination(for: URL.self) { urls, _ in
            let files = urls.filter(\.isFileURL)
            guard !files.isEmpty else { return false }
            offer(files)
            return true
        } isTargeted: { targeted = $0 }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Drop files here to convert them")
    }

    /// Each kind, what it reads and the formats it can become; a format waiting for a tool says which, with Install.
    @ViewBuilder private var formats: some View {
        ForEach(Array(Convert.catalogue.enumerated()), id: \.offset) { i, row in
            BlockRow(first: i == 0) {
                TitledText(title: row.kind, detail: row.reads).padding(.vertical, 4).frame(maxWidth: .infinity, alignment: .leading)
                Flow(spacing: 5, lineSpacing: 5) {
                    ForEach(row.to, id: \.self) { format in
                        let missing = format.tool.map { tools?.contains($0) == false } ?? false
                        Chip(text: format.title, color: missing ? ink.yellow : nil)
                            .help(missing ? "Needs \(format.tool!.formula) from Homebrew" : "")
                    }
                }
                .frame(width: 330, alignment: .leading).padding(.vertical, 6)
            }
        }
        ForEach(ConvertTool.allCases, id: \.self) { tool in
            BlockRow {
                TitledText(title: tool.formula, detail: Self.needs(tool)).padding(.vertical, 4)
                Spacer()
                if tools?.contains(tool) == true {
                    Chip(text: "installed", color: ink.green)
                } else if let package = tool.package {
                    Button("Install") { InstallModule.pick(package.key) }.buttonStyle(.pilot)
                }
            }
        }
    }

    /// What a tool writes that macOS cannot.
    static func needs(_ tool: ConvertTool) -> String {
        tool == .ffmpeg ? "Writes MP3, and GIF from a video; macOS writes neither" : "Writes WebP, which macOS cannot"
    }

    static func installedTools() -> Set<ConvertTool> { Set(Converter.installed().tools.keys) }

    /// Panels begin rather than run modal, so the tap keeps going while one is open.
    private func choose() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.prompt = "Convert"
        panel.begin { response in
            guard response == .OK, !panel.urls.isEmpty else { return }
            offer(panel.urls)
        }
    }
}
