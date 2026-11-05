import AppKit
import PilotCore
import SwiftUI

/// Tools › Captures (spec `capture.html`, Q157), in two tabs (page map, Sven 2026-10-17). Capture: how a capture ends, the keys, the Captures folder and the newest captures and recordings in Pilot's
/// folders, a click opening one. Recording: how a recording sounds, looks and counts down, its keys and the Recordings
/// folder. Every row has an ⓘ; a key's is the line Binds shows for it.
struct CapturesPage: View {
    @Bindable var store: CaptureSettingsStore
    var bar: BarItemsStore = .shared
    var thumbnails: FileThumbnails = .shared
    @State private var recent: [CaptureFiles.Listed] = []

    /// The Recording tab rather than Capture.
    var recording = false

    init(store: CaptureSettingsStore = .shared, recording: Bool = false) { self.store = store; self.recording = recording }

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
        static let recent = "The newest captures and recordings in Pilot's folders. A click opens one; right-click shows it in Finder."
    }

    var body: some View {
        KitPage {
            if recording { recordingTab } else { captureTab }
        }
        .onAppear(perform: reload)
        .onChange(of: store.settings) { reload() }
    }

    @ViewBuilder private var captureTab: some View {
        KitBlock(title: "Capture", symbol: "camera.viewfinder", note: Self.note) {
            BlockRow(first: true) {
                label("Capture menu", Info.menu)
                Segments(selection: menuPlace, options: [(nil, "Off"), (.menuBar, "Menu bar"), (.topBar, "Top bar"), (.both, "Both")], label: "Capture menu")
            }
            BlockRow { Toggle("Hide desktop icons in captures and recordings", isOn: $store.settings.hideDesktopIcons).toggleStyle(.pilotSwitchRow(info: Info.hideIcons)) }
            BlockRow {
                label("After capture", Info.afterCapture)
                Segments(selection: $store.settings.afterCapture, options: [(.thumbnail, "Thumbnail"), (.editor, "Open editor"), (.copy, "Copy only")],
                         label: "After capture")
            }
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
            keyRows(Self.keys)
        }
        KitBlock(title: "Folder", symbol: "folder") { folderRow("Captures", kind: .capture, info: Info.capturesFolder) }
        KitBlock(title: "Recent", symbol: "clock") {
            InfoMark(text: Info.recent)
        } content: {
            if recent.isEmpty {
                BlockRow(first: true) { FinePrint(text: "Nothing captured yet.").frame(maxWidth: .infinity, alignment: .leading) }
            } else {
                ForEach(Array(recent.enumerated()), id: \.element.url) { i, file in
                    BlockRow(first: i == 0) { row(file) }
                }
            }
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
            BlockRow {
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
            keyRows(Self.recordKeys)
        }
        KitBlock(title: "Folder", symbol: "folder") { folderRow("Recordings", kind: .recording, info: Info.recordingsFolder) }
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
    private func keyRows(_ keys: [(id: String, title: String)]) -> some View {
        ForEach(keys, id: \.id) { row in
            BlockRow { label(row.title, Abilities.what(row.id, label: row.title)); BindKey(action: row.id) }
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

    private func row(_ file: CaptureFiles.Listed) -> some View {
        Button { NSWorkspace.shared.open(file.url) } label: {
            HStack(spacing: 10) {
                Group {
                    if let image = thumbnails.image(file.url.path) { Image(nsImage: image).resizable().aspectRatio(contentMode: .fill) }
                    else { Image(systemName: file.kind == .capture ? "photo" : "film").foregroundStyle(.secondary) }
                }
                .frame(width: 44, height: 30).clipShape(RoundedRectangle(cornerRadius: 4))
                TitledText(title: Text(file.url.lastPathComponent),
                           detail: "\(file.date.formatted(date: .abbreviated, time: .shortened)) · \(ByteCountFormatter.string(fromByteCount: Int64(file.bytes), countStyle: .file))")
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .contextMenu { Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([file.url]) } }
    }

    /// Recent shows only on Capture, so the Recording tab lists nothing.
    private func reload() {
        guard !recording else { return }
        recent = CaptureFiles.recent(captures: store.folder(.capture), recordings: store.folder(.recording), limit: 20)
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
