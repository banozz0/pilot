import AppKit
import PilotCore
import SwiftUI

/// Tools › Captures (spec `capture.html`, Q157), in tabs (page map, Sven 2026-10-17; simplify-pages T13). Capture: how a
/// capture ends, the three daily keys and the Captures folder; the newest captures are on History. Recording: what a
/// recording hears, its count down, its keys and the Recordings folder. More: the capture options, the other keys and a
/// recording's quality. Every row has an ⓘ; a key's is the line Binds shows for it.
struct CapturesPage: View {
    @Bindable var store: CaptureSettingsStore
    var bar: BarItemsStore = .shared

    /// The Recording tab rather than Capture.
    var recording = false
    /// The More tab: the capture options, the other keys and a recording's quality (simplify-pages T13).
    var more = false

    init(store: CaptureSettingsStore = .shared, recording: Bool = false, more: Bool = false) {
        self.store = store; self.recording = recording; self.more = more
    }

    static let note = "The capture keys freeze the screen and capture with Pilot."

    /// What each row does, the ⓘ's words.
    enum Info {
        static let menu = "Where Capture's own item sits: the macOS menu bar, the top bar or both. A click lists every capture with its key; while recording it shows the time, with Stop and Pause."
        static let hideIcons = "Leaves the desktop icons out of captures and recordings. The desktop itself stays as it is."
        static let afterCapture = "What a capture or a recording does once saved: shows a thumbnail, opens its editor (a recording's is the video editor), or only copies it."
        static let thumbnailPlace = "Where on the screen the thumbnail shows: a corner or the middle."
        static let autoScroll = "A scrolling capture scrolls the page for you; Esc or a click stops it. Off, you scroll yourself."
        static let delay = "How long After a delay counts down before the screen freezes."
        static let sound = "What a recording hears: nothing, the Mac's own sound, the microphone or both."
        static let countdown = "Counts down three seconds before a recording starts."
        static let quality = "How sharp a recording is. Higher keeps more detail and makes a bigger file."
        static let resolution = "Retina pixels records every pixel of a Retina screen; 1x records at half that, a smaller file."
        static let frameRate = "Frames a second: 60 is smoother, 30 makes a smaller file."
        static let showClicks = "Rings each click of a new recording in the video you share or export, so a viewer sees where you clicked. Click ring in the video editor turns it on or off for one recording."
        static let capturesFolder = "Where captures are saved. Show opens it, Change picks another, Default goes back to ~/Pictures/Pilot."
        static let recordingsFolder = "Where recordings are saved. Show opens it, Change picks another, Default goes back to ~/Movies/Pilot."
    }

    /// More's index (simplify-pages T13). A row added to or moved off a block changes its count here.
    static let entries = [
        MoreEntry(id: .captureOptions, symbol: "camera.viewfinder", controls: 5),
        MoreEntry(id: .captureKeys, symbol: "keyboard", controls: keys.count - frontKeys),
        MoreEntry(id: .recordingQuality, symbol: "record.circle", controls: 4),
    ]

    /// The keys Capture's front shows: Area, Window and Full screen; the rest are on More.
    static let frontKeys = 3

    var body: some View {
        Group {
            if more {
                KitMore(entries: Self.entries) {
                    KitBlock(title: "Capture", symbol: "camera.viewfinder") { options }.moreBlock(.captureOptions)
                    KitBlock(title: "More capture keys", symbol: "keyboard") { keyRows(Array(Self.keys.dropFirst(Self.frontKeys)), first: true) }
                        .moreBlock(.captureKeys)
                    KitBlock(title: "Recording quality", symbol: "record.circle") { quality }.moreBlock(.recordingQuality)
                }
            } else {
                KitPage {
                    if recording { recordingTab } else { captureTab }
                }
            }
        }
    }

    /// Capture's front (simplify-pages T13): After capture, the three daily keys and the folder; the newest captures are on
    /// History.
    @ViewBuilder private var captureTab: some View {
        CapturePreview(after: store.settings.afterCapture, place: store.settings.thumbnailPlace)
        KitBlock(title: "Capture", symbol: "camera.viewfinder", note: Self.note) {
            BlockRow(first: true) {
                label("After capture", Info.afterCapture)
                Segments(selection: $store.settings.afterCapture, options: [(.thumbnail, "Thumbnail"), (.editor, "Open editor"), (.copy, "Copy only")],
                         label: "After capture")
            }
            keyRows(Array(Self.keys.prefix(Self.frontKeys)))
        }
        KitBlock(title: "Folder", symbol: "folder") { folderRow("Captures", kind: .capture, info: Info.capturesFolder) }
    }

    /// More's capture options: the Capture menu, hidden icons, the thumbnail's place, scrolling and the delay.
    @ViewBuilder private var options: some View {
        BlockRow(first: true) {
            label("Capture menu", Info.menu)
            Segments(selection: menuPlace, options: [(nil, "Off"), (.menuBar, "Menu bar"), (.topBar, "Top bar"), (.both, "Both")], label: "Capture menu")
        }
            BlockRow { Toggle("Hide desktop icons in captures and recordings", isOn: $store.settings.hideDesktopIcons).toggleStyle(.pilotSwitchRow(info: Info.hideIcons)) }
        if store.settings.afterCapture == .thumbnail {
            BlockRow {
                label("Thumbnail place", Info.thumbnailPlace)
                Picker("Thumbnail place", selection: $store.settings.thumbnailPlace) {
                    ForEach(CaptureSettings.ThumbnailPlace.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                .labelsHidden().fixedSize()
            }
        }
        BlockRow { Toggle("Scrolling captures: Pilot scrolls for you", isOn: $store.settings.autoScroll).toggleStyle(.pilotSwitchRow(info: Info.autoScroll)) }
        BlockRow {
            label("Delay", Info.delay)
            Segments(selection: $store.settings.delay, options: [(3, "3 s"), (5, "5 s"), (10, "10 s")], label: "Delay")
        }
    }

    @ViewBuilder private var recordingTab: some View {
        KitBlock(title: "Recording", symbol: "record.circle", note: Self.recordNote) {
            BlockRow(first: true) {
                label("Sound", Info.sound)
                Segments(selection: $store.settings.audio, options: [(.none, "None"), (.system, "Mac"), (.mic, "Microphone"), (.both, "Both")],
                         label: "Sound")
            }
            BlockRow {
                label("Count down first", Info.countdown)
                Segments(selection: $store.settings.countdown, options: [(0, "Off"), (3, "3 seconds")], label: "Count down first")
            }
            keyRows(Self.recordKeys)
        }
        KitBlock(title: "Folder", symbol: "folder") { folderRow("Recordings", kind: .recording, info: Info.recordingsFolder) }
    }

    /// More's recording quality: quality, resolution, frame rate and clicks.
    @ViewBuilder private var quality: some View {
        BlockRow(first: true) {
            label("Quality", Info.quality)
            Segments(selection: $store.settings.recordQuality, options: [(.standard, "Standard"), (.high, "High"), (.best, "Best")], label: "Quality")
        }
        BlockRow {
            label("Resolution", Info.resolution)
            Segments(selection: $store.settings.recordResolution, options: [(.native, "Retina pixels"), (.points, "1x")], label: "Resolution")
        }
        BlockRow {
            label("Frame rate", Info.frameRate)
            Segments(selection: $store.settings.recordFPS, options: [(30, "30 fps"), (60, "60 fps")], label: "Frame rate")
        }
        BlockRow { Toggle("Show clicks", isOn: $store.settings.showClicks).toggleStyle(.pilotSwitchRow(info: Info.showClicks)) }
    }

    /// Capture's bar item as Capture menu's pick (P69): off, or on where it is placed; the Menu bar page edits the same entry.
    private var menuPlace: Binding<BarPlacement?> {
        Binding {
            let entry = bar.settings.entry(.capture)
            return entry.on ? entry.placement : nil
        } set: { place in
            if let place { bar.settings.set(.capture, placement: place) }
            bar.settings.set(.capture, on: place != nil)
        }
    }

    /// A row's label with its ⓘ, taking the row's spare width.
    private func label(_ title: String, _ info: String) -> some View {
        HStack(spacing: 6) { Text(title); InfoMark(text: info) }.frame(maxWidth: .infinity, alignment: .leading)
    }

    /// One row per key, its ⓘ the line Binds shows for the action.
    private func keyRows(_ keys: [(id: String, title: String)], first: Bool = false) -> some View {
        ForEach(Array(keys.enumerated()), id: \.element.id) { i, row in
            BlockRow(first: first && i == 0) { label(row.title, Abilities.what(row.id, label: row.title)); BindKey(action: row.id) }
        }
    }

    static let keys: [(id: String, title: String)] = [
        ("captures.area", "Area"), ("captures.activeWindow", "Window"), ("captures.fullscreen", "Full screen"),
        ("captures.scrolling", "Scrolling"), ("captures.scrollingUp", "Scrolling, upward"),
        ("captures.ocr", "Read text and QR codes"),
        ("captures.smartElement", "A UI element"), ("captures.subject", "A subject, background removed"),
        ("captures.markup", "Mark up, then save"), ("captures.pickColour", "Pick a colour"),
        ("captures.repeatArea", "The last area again"), ("captures.delayed", "After a delay"),
        ("captures.editLast", "Edit the last capture"),
    ]

    static let recordKeys: [(id: String, title: String)] = [
        ("captures.screenRecording", "Record, and stop"), ("captures.pauseRecording", "Pause and resume"),
    ]

    static let recordNote = "Pick a screen, a window's app or an area, then it records into an .mp4. The time shows on Capture's item or the top bar, with Stop and Pause."

    private func folderRow(_ title: String, kind: CaptureKind, info: String) -> some View {
        let folder = store.folder(kind)
        return BlockRow(first: true) {
            HStack(spacing: 6) { TitledText(title: Text(title), detail: PilotCapture.shortPath(folder)); InfoMark(text: info) }
                .frame(maxWidth: .infinity, alignment: .leading)
            Button("Show") {
                try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                NSWorkspace.shared.open(folder)
            }.buttonStyle(.pilot)
            Button("Change…") { choose(kind) }.buttonStyle(.pilot)
            if (kind == .capture ? store.settings.capturesFolder : store.settings.recordingsFolder) != nil {
                Button("Default") { set(kind, nil) }.buttonStyle(.pilot)
            }
        }
    }

    private func set(_ kind: CaptureKind, _ path: String?) {
        if kind == .capture { store.settings.capturesFolder = path } else { store.settings.recordingsFolder = path }
    }

    /// Panels begin rather than run modal, so the main run loop and the tap keep going while one is open.
    private func choose(_ kind: CaptureKind) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.directoryURL = store.folder(kind)
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            set(kind, url.path(percentEncoded: false))
        }
    }
}

/// Capture's preview (simplify-pages T27, the prototype's): a screen in small (MiniDesktop) and what After capture does
/// on it: the thumbnail at its place (More's Thumbnail place), the capture's editor over the windows, or Copied.
struct CapturePreview: View {
    @Environment(\.ink) private var ink
    let after: CaptureSettings.AfterCapture
    let place: CaptureSettings.ThumbnailPlace

    /// Short enough that Capture's front still fits the window's first size (660 tall) in both styles.
    static let height: CGFloat = 104

    var body: some View {
        MiniDesktop(windows: ["Zen", "Notes"], inner: 16, outer: 20, focused: nil)
            .overlay(alignment: alignment) { result.padding(10) }
            .frame(height: Self.height)
            .animation(Kit.change, value: after)
            .animation(Kit.change, value: place)
    }

    private var alignment: Alignment {
        guard after == .thumbnail else { return .center }
        return switch place {
        case .bottomRight: .bottomTrailing
        case .bottomLeft: .bottomLeading
        case .topRight: .topTrailing
        case .topLeft: .topLeading
        case .middle: .center
        }
    }

    @ViewBuilder private var result: some View {
        let shape = RoundedRectangle(cornerRadius: ink.radius(5), style: .continuous)
        switch after {
        case .thumbnail:
            // The thumbnail's card in small: ThumbnailStack.card's 4:3 on its hairline.
            lines([0.7, 0.5]).frame(width: 56, height: 56 * ThumbnailStack.card.height / ThumbnailStack.card.width)
                .background(ink.surface, in: shape).overlay { shape.strokeBorder(ink.line2, lineWidth: 1) }
        case .editor:
            VStack(spacing: 0) {
                HStack(spacing: 5) {
                    Image(systemName: "viewfinder"); Text("Capture editor"); Spacer(); Image(systemName: "xmark")
                }
                .font(ink.ui(8.5, .medium)).foregroundStyle(ink.text2).padding(.horizontal, 7).frame(height: 16)
                shape.fill(ink.selected).padding(6)
            }
            .frame(width: 150, height: 76).background(ink.surface, in: shape).overlay { shape.strokeBorder(ink.line3, lineWidth: 1) }
        case .copy:
            Label("Copied", systemImage: "checkmark").font(ink.ui(10.5, .medium)).foregroundStyle(ink.text)
                .padding(.horizontal, 10).frame(height: 24).background(ink.surface, in: Capsule()).overlay { Capsule().strokeBorder(ink.line3, lineWidth: 1) }
        }
    }

    private func lines(_ shares: [Double]) -> some View {
        VStack(alignment: .leading, spacing: 5) { ForEach(shares, id: \.self) { Capsule().fill(ink.line2).frame(width: 46 * $0, height: 3) } }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading).padding(8)
    }
}
