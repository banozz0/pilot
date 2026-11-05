import CoreGraphics
import Foundation

/// Pilot's own captures (spec `capture.html`, Sven's yes Q156): what a capture or recording file is called and where it
/// goes. Captures land in `~/Pictures/Pilot`, recordings in `~/Movies/Pilot`,
/// each folder changeable on the Captures page (Q157).
public enum CaptureKind: String, Sendable, CaseIterable {
    case capture, recording

    /// The word a file name starts with: `Capture 2026-10-16 at 14.03.22.png`, the Mac's own pattern.
    public var word: String { self == .capture ? "Capture" : "Recording" }

    public var fileExtension: String { self == .capture ? "png" : "mp4" }

    /// The folder in the home folder a kind goes to until Sven picks another.
    public var standardFolder: String { self == .capture ? "Pictures/Pilot" : "Movies/Pilot" }
}

public enum CaptureFiles {
    /// `Capture 2026-10-16 at 14.03.22.png` in the Mac's time zone, digits always Western.
    public static func name(_ kind: CaptureKind, at date: Date, zone: TimeZone = .current) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = zone
        f.dateFormat = "yyyy-MM-dd 'at' HH.mm.ss"
        return "\(kind.word) \(f.string(from: date)).\(kind.fileExtension)"
    }

    /// A file in `folder` no other file holds: the name, else the name with " 2", " 3" … before its extension, so two
    /// captures in one second never overwrite each other.
    public static func freeURL(_ kind: CaptureKind, in folder: URL, at date: Date, zone: TimeZone = .current,
                               exists: (URL) -> Bool = { FileManager.default.fileExists(atPath: $0.path) }) -> URL {
        let name = Self.name(kind, at: date, zone: zone)
        let stem = String(name.dropLast(kind.fileExtension.count + 1))
        var url = folder.appending(path: name, directoryHint: .notDirectory)
        var n = 2
        while exists(url) {
            url = folder.appending(path: "\(stem) \(n).\(kind.fileExtension)", directoryHint: .notDirectory)
            n += 1
        }
        return url
    }

    /// The kind's folder: Sven's pick (a full path, `~` allowed), else its standard one in `home`.
    public static func folder(_ kind: CaptureKind, picked: String?, home: URL = URL(filePath: NSHomeDirectory())) -> URL {
        if let picked, !picked.trimmingCharacters(in: .whitespaces).isEmpty {
            return URL(filePath: (picked as NSString).expandingTildeInPath, directoryHint: .isDirectory)
        }
        return home.appending(path: kind.standardFolder, directoryHint: .isDirectory)
    }

    /// One file the Captures page lists.
    public struct Listed: Equatable, Sendable {
        public let url: URL
        public let kind: CaptureKind
        public let date: Date
        public let bytes: Int

        public init(url: URL, kind: CaptureKind, date: Date, bytes: Int) {
            self.url = url
            self.kind = kind
            self.date = date
            self.bytes = bytes
        }
    }

    /// The newest `limit` captures and recordings in the two folders, newest first: images and movies by extension,
    /// whatever made them, hidden files left out. A missing folder lists nothing.
    public static func recent(captures: URL, recordings: URL, limit: Int = 30, fileManager: FileManager = .default) -> [Listed] {
        let keys: [URLResourceKey] = [.contentModificationDateKey, .fileSizeKey, .isRegularFileKey]
        func list(_ folder: URL, _ kind: CaptureKind, _ extensions: Set<String>) -> [Listed] {
            let urls = (try? fileManager.contentsOfDirectory(at: folder, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles])) ?? []
            return urls.compactMap { url in
                guard extensions.contains(url.pathExtension.lowercased()),
                      let values = try? url.resourceValues(forKeys: Set(keys)), values.isRegularFile == true else { return nil }
                return Listed(url: url, kind: kind, date: values.contentModificationDate ?? .distantPast, bytes: values.fileSize ?? 0)
            }
        }
        let all = list(captures, .capture, ["png", "jpg", "jpeg", "heic"])
            + (recordings.standardizedFileURL == captures.standardizedFileURL ? [] : list(recordings, .recording, ["mp4", "mov"]))
        return Array(all.sorted { $0.date > $1.date }.prefix(limit))
    }

    /// The Capture branch's newest captures (CP10): file rows, so they draw their thumbnails and take a file's actions;
    /// Return on one opens it in the editor. Pictures only, at most ten, not found by the root search.
    public static func menuRows(_ listed: [Listed], now: Date = Date()) -> [MenuEntry] {
        let ago = RelativeDateTimeFormatter()
        ago.unitsStyle = .short
        return listed.filter { $0.kind == .capture }.prefix(10).map { file in
            MenuEntry(title: file.url.deletingPathExtension().lastPathComponent, target: .file(file.url.path(percentEncoded: false)), home: .capture,
                      detail: ago.localizedString(for: file.date, relativeTo: now), inSearch: false)
        }
    }
}

/// The screen an area capture was cut from (P77): the display's still at its own pixels and where the capture sits in
/// it, so the editor can uncrop past the capture's edge, up to that display and no other. Kept in memory only, never in
/// a file (Sven, Q814), while the capture's thumbnail or editor is up (CaptureHistoryStore).
public struct CaptureGrab: @unchecked Sendable {
    /// The display's still.
    public let image: CGImage
    /// The capture's pixels in the still, from its top left: exactly the ones the capture was cut from.
    public let taken: CGRect
    public let scale: CGFloat
    /// The windows on the display as it was taken, in its points from its top left: the crop snaps to their edges (C3).
    public let windows: [CGRect]

    public init(image: CGImage, taken: CGRect, scale: CGFloat, windows: [CGRect] = []) {
        self.image = image
        self.taken = taken.integral
        self.scale = scale
        self.windows = windows
    }

    /// The capture's place in the still, in points.
    public var takenPoints: CGRect { CGRect(x: taken.minX / scale, y: taken.minY / scale, width: taken.width / scale, height: taken.height / scale) }

    /// The still's size in points.
    public var size: CGSize { CGSize(width: CGFloat(image.width) / scale, height: CGFloat(image.height) / scale) }

    /// Whether it is the screen of a capture `width` × `height` pixels at `scale`: a capture written over since (Done with
    /// a crop or a backdrop) or another file under the name is not, and gets no uncrop.
    public func fits(width: Int, height: Int, scale: CGFloat) -> Bool {
        Int(taken.width) == width && Int(taken.height) == height && abs(self.scale - scale) < 0.01
            && CGRect(x: 0, y: 0, width: image.width, height: image.height).contains(taken) && taken.size != CGSize(width: image.width, height: image.height)
    }
}

/// The last area captured, on its display (CP10): Hyper+Alt+S takes it again without the overlay.
public struct LastArea: Codable, Equatable, Sendable {
    public let display: UInt32
    public let rect: CGRect

    public init(display: UInt32, rect: CGRect) {
        self.display = display
        self.rect = rect
    }
}

/// The capture settings the Captures page and `pilot get capture.*` share.
public struct CaptureSettings: Codable, Equatable, Sendable {
    /// What a recording hears (spec `capture.html`): nothing, the Mac's sound, the microphone, or both on two tracks.
    public enum Audio: String, Codable, CaseIterable, Sendable {
        case none, system, mic, both

        public var system: Bool { self == .system || self == .both }
        public var mic: Bool { self == .mic || self == .both }
    }

    /// A folder Sven picked; nil is the kind's standard folder.
    public var capturesFolder: String?
    public var recordingsFolder: String?
    public var audio: Audio
    /// Seconds counted down before a recording starts: 0 or 3.
    public var countdown: Int
    /// A ring where the mouse clicks, drawn into the recording by macOS.
    public var showClicks: Bool
    /// What follows a capture (Sven, build 54: several captures opened several editors): a thumbnail in a corner that a
    /// click opens in the editor (the default, as CleanShot does), the editor at once, or only the copy and save.
    public enum AfterCapture: String, Codable, CaseIterable, Sendable { case thumbnail, editor, copy }

    public var afterCapture: AfterCapture
    /// Where the thumbnails float (Sven on build 54): a corner of the screen or its middle; the stack grows away from
    /// the edge, newest nearest it.
    public enum ThumbnailPlace: String, Codable, CaseIterable, Sendable {
        case bottomRight, bottomLeft, topRight, topLeft, middle

        public var title: String {
            switch self {
            case .bottomRight: "Bottom right"
            case .bottomLeft: "Bottom left"
            case .topRight: "Top right"
            case .topLeft: "Top left"
            case .middle: "Middle"
            }
        }
    }

    public var thumbnailPlace: ThumbnailPlace
    /// Seconds a delayed capture counts down: 3, 5 or 10 (CP10).
    public var delay: Int
    /// A scrolling capture scrolls the page itself (Sven, build 52); off, Sven scrolls.
    public var autoScroll: Bool
    /// How a recording is encoded (Sven, build 53: "quality is a bit bad"): a quality level the encoder holds, not an
    /// average bitrate it undershot on screen content (1.4 Mbit/s for 1704 × 1288).
    public enum RecordQuality: String, Codable, CaseIterable, Sendable {
        case standard, high, best

        /// VideoToolbox's quality, 0 to 1: measured on light text over a dark gradient scrolling at 60 fps, 1280 × 800,
        /// 2.6, 4.5 and 10.3 Mbit/s at 41.5, 44.2 and 47.2 dB against a near-lossless encode (the old average bitrate:
        /// 2.6 Mbit/s at 42.3 dB).
        public var level: Double {
            switch self {
            case .standard: 0.75
            case .high: 0.85
            case .best: 0.92
            }
        }
    }

    /// Recorded at the display's own pixels (Retina's 2x), or at its points (1x, a quarter of the pixels on Retina).
    public enum RecordResolution: String, Codable, CaseIterable, Sendable { case native, points }

    public var recordQuality: RecordQuality
    public var recordResolution: RecordResolution
    /// 30 or 60 frames a second at most; the screen sends a frame only when it changes.
    public var recordFPS: Int
    /// Desktop icons are left out of captures and recordings (DesktopIcons); off, they are in them as on screen.
    public var hideDesktopIcons: Bool
    /// Every capture's copy framed in this look (C11, Xnapper's): a BackdropPreset's id, Pilot's own look or a saved one;
    /// nil, the copy is the capture as taken. The saved file stays as taken, so its editor and uncrop start from it.
    public var everyCaptureLook: String?

    public init(capturesFolder: String? = nil, recordingsFolder: String? = nil, audio: Audio = .none,
                countdown: Int = 3, showClicks: Bool = false, afterCapture: AfterCapture = .thumbnail, delay: Int = 3, autoScroll: Bool = true,
                recordQuality: RecordQuality = .high, recordResolution: RecordResolution = .native, recordFPS: Int = 60,
                hideDesktopIcons: Bool = false, thumbnailPlace: ThumbnailPlace = .bottomRight, everyCaptureLook: String? = nil) {
        self.capturesFolder = capturesFolder
        self.recordingsFolder = recordingsFolder
        self.audio = audio
        self.countdown = countdown
        self.showClicks = showClicks
        self.afterCapture = afterCapture
        self.delay = delay
        self.autoScroll = autoScroll
        self.recordQuality = recordQuality
        self.recordResolution = recordResolution
        self.recordFPS = recordFPS
        self.hideDesktopIcons = hideDesktopIcons
        self.thumbnailPlace = thumbnailPlace
        self.everyCaptureLook = everyCaptureLook
    }

    private enum CodingKeys: String, CodingKey {
        case capturesFolder, recordingsFolder, audio, countdown, showClicks, afterCapture, delay, autoScroll, recordQuality,
             recordResolution, recordFPS, hideDesktopIcons, thumbnailPlace, everyCaptureLook, openEditor
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encodeIfPresent(capturesFolder, forKey: .capturesFolder)
        try c.encodeIfPresent(recordingsFolder, forKey: .recordingsFolder)
        try c.encode(audio, forKey: .audio)
        try c.encode(countdown, forKey: .countdown)
        try c.encode(showClicks, forKey: .showClicks)
        try c.encode(afterCapture, forKey: .afterCapture)
        try c.encode(delay, forKey: .delay)
        try c.encode(autoScroll, forKey: .autoScroll)
        try c.encode(recordQuality, forKey: .recordQuality)
        try c.encode(recordResolution, forKey: .recordResolution)
        try c.encode(recordFPS, forKey: .recordFPS)
        try c.encode(hideDesktopIcons, forKey: .hideDesktopIcons)
        try c.encode(thumbnailPlace, forKey: .thumbnailPlace)
        try c.encodeIfPresent(everyCaptureLook, forKey: .everyCaptureLook)
    }

    /// Settings saved before a key existed read that key as its default, never as no settings at all.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = CaptureSettings()
        capturesFolder = try c.decodeIfPresent(String.self, forKey: .capturesFolder)
        recordingsFolder = try c.decodeIfPresent(String.self, forKey: .recordingsFolder)
        audio = try c.decodeIfPresent(Audio.self, forKey: .audio) ?? d.audio
        countdown = try c.decodeIfPresent(Int.self, forKey: .countdown) ?? d.countdown
        showClicks = try c.decodeIfPresent(Bool.self, forKey: .showClicks) ?? d.showClicks
        // Before build 55 a switch, openEditor: off kept to copying only; on (the old default) takes the thumbnail now.
        let old = try c.decodeIfPresent(Bool.self, forKey: .openEditor)
        afterCapture = try c.decodeIfPresent(AfterCapture.self, forKey: .afterCapture) ?? (old == false ? .copy : d.afterCapture)
        delay = try c.decodeIfPresent(Int.self, forKey: .delay) ?? d.delay
        autoScroll = try c.decodeIfPresent(Bool.self, forKey: .autoScroll) ?? d.autoScroll
        recordQuality = try c.decodeIfPresent(RecordQuality.self, forKey: .recordQuality) ?? d.recordQuality
        recordResolution = try c.decodeIfPresent(RecordResolution.self, forKey: .recordResolution) ?? d.recordResolution
        recordFPS = try c.decodeIfPresent(Int.self, forKey: .recordFPS) ?? d.recordFPS
        hideDesktopIcons = try c.decodeIfPresent(Bool.self, forKey: .hideDesktopIcons) ?? d.hideDesktopIcons
        thumbnailPlace = try c.decodeIfPresent(ThumbnailPlace.self, forKey: .thumbnailPlace) ?? d.thumbnailPlace
        everyCaptureLook = try c.decodeIfPresent(String.self, forKey: .everyCaptureLook)
    }

    public static let `default` = CaptureSettings()

    public func folder(_ kind: CaptureKind, home: URL = URL(filePath: NSHomeDirectory())) -> URL {
        CaptureFiles.folder(kind, picked: kind == .capture ? capturesFolder : recordingsFolder, home: home)
    }
}

/// Where the after-capture thumbnails sit (build 54): the bottom-right corner of the screen, the newest lowest, the
/// others stacked above it, at most four; each fits 200 × 140 points keeping its shape.
public enum ThumbnailStack {
    public static let most = 4
    /// Every thumbnail's card, whatever the capture's shape (Sven, 2026-10-19: a thin strip's thumbnail was 40 points tall
    /// and cut its buttons off): 4:3, a little taller than a wide screen, the capture fitted inside it.
    public static let card = CGSize(width: 216, height: 162)
    public static let margin: CGFloat = 16, gap: CGFloat = 10

    /// A capture's thumbnail size: the card, for any capture.
    public static func size(_ capture: CGSize) -> CGSize { card }

    /// The frames for thumbnails of `sizes`, newest last, in `screen`'s visible frame (bottom-left origin), at `place`:
    /// in a bottom corner the newest at the foot and older ones up the stack, in a top corner the newest at the top and
    /// older ones down it, in the middle the stack centred, the newest at its foot.
    public static func frames(_ sizes: [CGSize], in screen: CGRect, place: CaptureSettings.ThumbnailPlace = .bottomRight) -> [CGRect] {
        let tall = sizes.reduce(0) { $0 + $1.height } + gap * CGFloat(max(sizes.count - 1, 0))
        let down = place == .topRight || place == .topLeft
        var y = switch place {
        case .bottomRight, .bottomLeft: screen.minY + margin
        case .topRight, .topLeft: screen.maxY - margin
        case .middle: (screen.midY - tall / 2).rounded()
        }
        var frames: [CGRect] = Array(repeating: .zero, count: sizes.count)
        for i in sizes.indices.reversed() {
            let s = sizes[i]
            let x = switch place {
            case .bottomRight, .topRight: screen.maxX - margin - s.width
            case .bottomLeft, .topLeft: screen.minX + margin
            case .middle: (screen.midX - s.width / 2).rounded()
            }
            if down { y -= s.height }
            frames[i] = CGRect(x: x, y: y, width: s.width, height: s.height)
            y += down ? -gap : s.height + gap
        }
        return frames
    }
}