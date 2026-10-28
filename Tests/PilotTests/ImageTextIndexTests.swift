import AppKit
import Clipboard
import Foundation
import PilotCore
import Synchronization
import Testing
@testable import Pilot

/// Homy-style Files T1: the text index reads the words in the images of Text in images' folders, in the background. A
/// fake recognizer over a temporary home proves what the Files view and the disk see: acceptance checks 2 (a deleted
/// image leaves the search) and 7 (switched off, nothing is read and the index file is gone), the power rules, the
/// skips and the scope. Real Vision in pilot-text's batch mode runs with PILOT_LIVE=1.
@MainActor
@Suite("Image text index")
struct ImageTextIndexTests {
    /// Answers by the image's bytes and counts what it was handed.
    final class FakeRecognizer: TextRecognizing {
        let texts: [Data: String]
        let calls = Mutex(0)
        init(_ texts: [Data: String]) { self.texts = texts }
        func text(in image: Data) async -> String {
            calls.withLock { $0 += 1 }
            return texts[image] ?? ""
        }
        func boxes(of words: [String], in image: Data) async -> [CGRect] { [] }
        var count: Int { calls.withLock { $0 } }
    }

    /// The Mac's conditions, changed by a test while a pass runs.
    final class Power: Sendable {
        let now: Mutex<ImageTextReader.Conditions>
        /// Conditions after this many reads; nil keeps them.
        let after: Mutex<(reads: Int, then: ImageTextReader.Conditions)?> = Mutex(nil)
        init(_ now: ImageTextReader.Conditions = .init()) { self.now = Mutex(now) }
        func read() -> ImageTextReader.Conditions {
            let switched = after.withLock { pending -> ImageTextReader.Conditions? in
                guard let p = pending else { return nil }
                if p.reads > 0 { pending = (p.reads - 1, p.then); return nil }
                pending = nil
                return p.then
            }
            return now.withLock { if let switched { $0 = switched }; return $0 }
        }
    }

    struct Home {
        let root: URL
        var path: String { root.path(percentEncoded: false) }
        var file: URL { root.appending(path: "Pilot/image-text.sqlite") }

        init() throws {
            let made = FileManager.default.temporaryDirectory.appending(path: "ImageTextIndexTests-\(UUID().uuidString)")
            for folder in ["Desktop", "Downloads", "Documents", "Pictures/Screenshots", "code", "Documents/node_modules"] {
                try FileManager.default.createDirectory(at: made.appending(path: folder), withIntermediateDirectories: true)
            }
            // Resolved, as the folder walk gives its paths: /private/var, not /var (resolvingSymlinksInPath drops /private).
            root = URL(filePath: String(cString: try #require(realpath(made.path, nil))))
        }

        /// Writes a png of `pixels` square, its colour from `shade`, so each image's bytes differ; `modified` sets its date.
        /// With `words` it is a white strip with them written large, for real Vision.
        @discardableResult
        func png(_ relative: String, pixels: Int = 200, shade: Int = 0, modified: Date? = nil, words: String? = nil) throws -> Data {
            let wide = words == nil ? pixels : 800, high = words == nil ? pixels : 160
            let rep = try #require(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: wide, pixelsHigh: high, bitsPerSample: 8,
                                                    samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                                                    bytesPerRow: 0, bitsPerPixel: 0))
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
            (words == nil ? NSColor(deviceRed: CGFloat(shade * 9 % 256) / 255, green: 0.5, blue: 0.5, alpha: 1) : .white).setFill()
            NSRect(x: 0, y: 0, width: wide, height: high).fill()
            (words as NSString?)?.draw(at: NSPoint(x: 40, y: 50), withAttributes: [.font: NSFont.systemFont(ofSize: 56), .foregroundColor: NSColor.black])
            NSGraphicsContext.restoreGraphicsState()
            let data = try #require(rep.representation(using: .png, properties: [:]))
            let url = root.appending(path: relative)
            try data.write(to: url)
            if let modified { try FileManager.default.setAttributes([.modificationDate: modified], ofItemAtPath: url.path) }
            return data
        }
    }

    static func reader(_ home: Home, _ recognizer: FakeRecognizer, power: Power = Power(),
                       excluded: [String] = FileExclusions.defaults, reading: (any ImageTextReading)? = nil,
                       access: @escaping @Sendable () -> Bool = { true },
                       dataless: @escaping @Sendable (String) -> Bool = { _ in false }) -> (ImageTextReader, ImageTextSettings) {
        let settings = ImageTextSettings(defaults: UserDefaults(suiteName: testSuite())!, home: home.path, excluded: { excluded })
        let reader = ImageTextReader(settings: settings, file: home.file, reading: reading ?? RecognizerText(recognizer: recognizer),
                                     conditions: { power.read() }, fullDiskAccess: access, excluded: { excluded },
                                     dataless: dataless, home: home.path, hourly: false)
        settings.onChange = { reader.settingsChanged() }
        return (reader, settings)
    }

    @Test("Check 1 and 2: a screenshot is found by its words, an unchanged one is not read again, a deleted one leaves the search")
    func findsAndForgets() async throws {
        let home = try Home()
        let shot = try home.png("Pictures/Screenshots/Screenshot 14.png", shade: 1)
        let other = try home.png("Desktop/receipt.jpg", shade: 2)
        let fake = FakeRecognizer([shot: "Total due\ninvoice 4471", other: "lunch receipt"])
        let (reader, _) = Self.reader(home, fake)
        await reader.start().value
        let hit = try #require(reader.search("invoice").first)
        #expect(hit.path == home.path + "/Pictures/Screenshots/Screenshot 14.png")
        #expect(hit.words.contains("invoice 4471"))
        #expect(reader.search("INVOI 44").map(\.path) == [hit.path])
        #expect(reader.search("lunch").count == 1 && reader.search("dinner").isEmpty && reader.search("  ").isEmpty)
        #expect(fake.count == 2)

        await reader.start().value
        #expect(fake.count == 2)
        try FileManager.default.removeItem(atPath: hit.path)
        await reader.start().value
        #expect(reader.search("invoice").isEmpty)
        #expect(reader.search("lunch").count == 1)
        #expect(fake.count == 2)
    }

    @Test("Check 7: switched off, the index file is gone, nothing is read and the search finds nothing")
    func offClears() async throws {
        let home = try Home()
        let shot = try home.png("Desktop/a.png", shade: 3)
        let fake = FakeRecognizer([shot: "invoice"])
        let (reader, settings) = Self.reader(home, fake)
        await reader.start().value
        #expect(FileManager.default.fileExists(atPath: home.file.path))
        settings.enabled = false
        #expect(!FileManager.default.fileExists(atPath: home.file.path))
        try home.png("Desktop/b.png", shade: 4)
        #expect(reader.menuOpened() == nil)
        await reader.start().value
        #expect(reader.search("invoice").isEmpty)
        #expect(fake.count == 1)
        #expect(!FileManager.default.fileExists(atPath: home.file.path))
        settings.enabled = true
        await reader.start().value
        #expect(reader.search("invoice").count == 1)
        #expect(fake.count == 3)
    }

    @Test("Power: before the first full pass battery reads only new images; on power it reads all; Low Power Mode and heat read none")
    func power() async throws {
        let home = try Home()
        let old = try home.png("Documents/old.png", shade: 5, modified: Date().addingTimeInterval(-2 * 86_400))
        let fake = FakeRecognizer([old: "old words"])
        let power = Power(.init(onPower: false))
        let (reader, _) = Self.reader(home, fake, power: power)
        await reader.start().value
        #expect(fake.count == 0)
        try home.png("Downloads/new.png", shade: 6, modified: Date().addingTimeInterval(60))
        await reader.start().value
        #expect(fake.count == 1)

        power.now.withLock { $0 = .init(onPower: false, lowPower: true) }
        await reader.start().value
        power.now.withLock { $0 = .init(onPower: true, hot: true) }
        await reader.start().value
        #expect(fake.count == 1)

        power.now.withLock { $0 = .init(onPower: true) }
        await reader.start().value
        #expect(fake.count == 2)
        #expect(reader.search("old").count == 1)
        // The first pass is done: battery now reads any new or changed image, old dates too.
        power.now.withLock { $0 = .init(onPower: false) }
        try home.png("Documents/older.png", shade: 7, modified: Date().addingTimeInterval(-3 * 86_400))
        await reader.start().value
        #expect(fake.count == 3)
    }

    @Test("Power: a first pass stops when the Mac is unplugged or Low Power Mode comes on, and the next carries on")
    func stopsMidPass() async throws {
        let home = try Home()
        let then = Date().addingTimeInterval(-86_400)
        for n in 0..<3 { try home.png("Desktop/\(n).png", shade: 10 + n, modified: then) }
        let fake = FakeRecognizer([:])
        let power = Power()
        // The pass reads the conditions once to start and once after each image.
        power.after.withLock { $0 = (1, .init(onPower: false)) }
        let (reader, _) = Self.reader(home, fake, power: power)
        await reader.start().value
        #expect(fake.count == 1)
        power.now.withLock { $0 = .init() }
        power.after.withLock { $0 = (1, .init(onPower: true, lowPower: true)) }
        await reader.start().value
        #expect(fake.count == 2)
        power.now.withLock { $0 = .init() }
        await reader.start().value
        #expect(fake.count == 3)
    }

    @Test("Skips and scope: icons, images over 50 MB, other kinds, other folders and the never-index list are not read; a removed folder's words go")
    func skipsAndScope() async throws {
        let home = try Home()
        let kept = try home.png("Desktop/kept.png", shade: 20)
        let icon = try home.png("Desktop/icon.png", pixels: 32, shade: 21)
        let huge = try home.png("Desktop/huge.png", shade: 22)
        let handle = try FileHandle(forWritingTo: home.root.appending(path: "Desktop/huge.png"))
        try handle.truncate(atOffset: UInt64(ImageTextReader.maxBytes) + 1)
        try handle.close()
        let gif = try home.png("Desktop/anim.gif", shade: 23)
        let repo = try home.png("code/repo.png", shade: 24)
        let module = try home.png("Documents/node_modules/logo.png", shade: 25)
        let shot = try home.png("Pictures/Screenshots/shot.png", shade: 26)
        let fake = FakeRecognizer([kept: "kept", icon: "icon", huge: "huge", gif: "gif", repo: "repo", module: "module", shot: "shot"])
        let (reader, settings) = Self.reader(home, fake)
        await reader.start().value
        #expect(fake.count == 2)
        for word in ["kept", "shot"] { #expect(reader.search(word).count == 1, "\(word)") }
        for word in ["icon", "huge", "gif", "repo", "module"] { #expect(reader.search(word).isEmpty, "\(word)") }
        // The skipped images are stored with no text, so they are not looked at again.
        await reader.start().value
        #expect(fake.count == 2)

        settings.remove("~/Pictures")
        await reader.start().value
        #expect(reader.search("shot").isEmpty && reader.search("kept").count == 1)
        #expect(settings.add(home.path + "/code") == nil)
        await reader.start().value
        #expect(reader.search("repo").count == 1 && fake.count == 3)
        #expect(settings.add("node_modules") != nil)
    }

    @Test("The menu opening starts a pass at most once in 5 minutes")
    func menuCadence() async throws {
        let home = try Home()
        let (reader, _) = Self.reader(home, FakeRecognizer([:]))
        let start = Date()
        await reader.menuOpened(now: start)?.value
        #expect(reader.menuOpened(now: start.addingTimeInterval(4 * 60)) == nil)
        #expect(reader.menuOpened(now: start.addingTimeInterval(5 * 60 + 1)) != nil)
    }

    @Test("pilot-text batch answers a JSON line per path, an unreadable one with no text, without starting Vision")
    func batchLines() async throws {
        #expect(FileManager.default.isExecutableFile(atPath: HelperTextTests.built))
        let missing = "/nonexistent/\(UUID().uuidString) \"quoted\"\nline.png"
        var read: [(String, String)] = []
        for try await line in BatchText(helper: HelperTextTests.built).read([missing, missing + "2"]) { read.append(line) }
        #expect(read.map(\.0) == [missing, missing + "2"] && read.allSatisfy { $0.1.isEmpty })
        // A helper that fails gives the image it was on with no text, then ends the stream with its error.
        var failed: [(String, String)] = []
        await #expect(throws: (any Error).self) {
            for try await line in BatchText(helper: "/usr/bin/false").read([missing, missing + "2"]) { failed.append(line) }
        }
        #expect(failed.map(\.0) == [missing] && failed.first?.1 == "")
    }

    @Test("Moody 5: an image that crashes the child is stored with no text, so the next pass reads the older ones after it")
    func crashingImage() async throws {
        let home = try Home()
        let log = home.root.appending(path: "asked.txt").path
        // Answers the first path it is handed, then dies by a signal on the second, as a Vision crash would.
        let script = home.root.appending(path: "crashing-text")
        try """
            #!/bin/sh
            n=0
            while IFS= read -r line; do
              echo "$line" >> '\(log)'
              n=$((n + 1))
              if [ $n -eq 2 ]; then kill -SEGV $$; fi
              printf '{"path":%s,"text":"seen words"}\\n' "$line"
            done
            """.write(toFile: script.path, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
        let day: TimeInterval = 86_400
        for (n, name) in ["new", "crash", "old"].enumerated() {
            try home.png("Desktop/\(name).png", shade: 30 + n, modified: Date().addingTimeInterval(-day * Double(n + 1)))
        }
        let (reader, _) = Self.reader(home, FakeRecognizer([:]), reading: BatchText(helper: script.path))
        await reader.start().value
        #expect(reader.search("seen").map { ($0.path as NSString).lastPathComponent } == ["new.png"])
        await reader.start().value
        #expect(Set(reader.search("seen").map { ($0.path as NSString).lastPathComponent }) == ["new.png", "old.png"])
        await reader.start().value
        let asked = try String(contentsOfFile: log, encoding: .utf8).split(separator: "\n").map { ($0 as Substring).contains("crash.png") }
        #expect(asked == [false, true, false])
    }

    @Test("Moody 2: a scoped folder on the never-index list, or inside one, is not read, and add refuses it")
    func scopedFolderLeftOut() async throws {
        let home = try Home()
        let download = try home.png("Downloads/listed.png", shade: 40)
        let kept = try home.png("Desktop/kept.png", shade: 41)
        let fake = FakeRecognizer([download: "listed", kept: "kept"])
        let (reader, settings) = Self.reader(home, fake, excluded: FileExclusions.defaults + ["~/Downloads"])
        await reader.start().value
        #expect(reader.search("listed").isEmpty && reader.search("kept").count == 1 && fake.count == 1)
        #expect(settings.add("~/Library")?.contains("never-index") == true)
        #expect(settings.add("~/Library/Mobile Documents")?.contains("never-index") == true)
        #expect(settings.add("~/Downloads/Inbox")?.contains("never-index") == true)
        #expect(settings.add("~/Documents/node_modules")?.contains("never-index") == true)
        #expect(settings.add("~/Movies") == nil)
        #expect(ImageTextReader.leftOut(home.path + "/Documents/node_modules/pkg", excluded: ["node_modules"], home: home.path))
        #expect(!ImageTextReader.leftOut(home.path + "/Documents", excluded: ["node_modules"], home: home.path))
    }

    @Test("Moody 3: an iCloud-only image is never read, so nothing downloads it; once it is on the Mac it is read")
    func datalessSkipped() async throws {
        let home = try Home()
        let cloud = try home.png("Documents/cloud.png", shade: 50)
        let fake = FakeRecognizer([cloud: "cloud words"])
        let offline = Mutex(true)
        let (reader, _) = Self.reader(home, fake, dataless: { path in path.hasSuffix("cloud.png") && offline.withLock { $0 } })
        await reader.start().value
        #expect(fake.count == 0 && reader.search("cloud").isEmpty)
        offline.withLock { $0 = false }
        await reader.start().value
        #expect(fake.count == 1 && reader.search("cloud").count == 1)
        #expect(!ImageTextReader.isDataless(home.path + "/Documents/cloud.png"))
    }

    @Test("Moody 4: a pass stopped by Clear before it opens the index never makes the file again")
    func clearBeforeOpen() async throws {
        let home = try Home()
        try home.png("Desktop/a.png", shade: 60)
        let entered = Mutex(false), gate = DispatchSemaphore(value: 0)
        let (reader, settings) = Self.reader(home, FakeRecognizer([:]), access: {
            entered.withLock { $0 = true }
            gate.wait()
            return true
        })
        let pass = reader.start()
        while !entered.withLock({ $0 }) { try await Task.sleep(for: .milliseconds(5)) }
        settings.enabled = false
        gate.signal()
        await pass.value
        #expect(!FileManager.default.fileExists(atPath: home.file.path))
    }

    @Test("Check 2 always: in Low Power Mode a deleted image still leaves the search; without Full Disk Access the search finds none")
    func sweepsWhenBlocked() async throws {
        let home = try Home()
        let shot = try home.png("Desktop/gone.png", shade: 70)
        let fake = FakeRecognizer([shot: "gone words"])
        let power = Power()
        let (reader, _) = Self.reader(home, fake, power: power)
        await reader.start().value
        #expect(reader.search("gone").count == 1)
        try FileManager.default.removeItem(atPath: home.path + "/Desktop/gone.png")
        power.now.withLock { $0 = .init(lowPower: true) }
        await reader.start().value
        #expect(reader.search("gone").isEmpty)

        let other = try Home()
        let words = try other.png("Desktop/seen.png", shade: 71)
        let access = Mutex(true)
        let (locked, _) = Self.reader(other, FakeRecognizer([words: "seen"]), access: { access.withLock { $0 } })
        await locked.start().value
        #expect(locked.search("seen").count == 1)
        access.withLock { $0 = false }
        await locked.start().value
        #expect(locked.search("seen").isEmpty)
    }

    /// Vision compiles its model on a new binary's first image (a minute or more), so this runs on request.
    @Test("pilot-text batch reads a rendered image's words", .enabled(if: ProcessInfo.processInfo.environment["PILOT_LIVE"] == "1"))
    func batchReads() async throws {
        let home = try Home()
        try home.png("Desktop/Screenshot 14.png", words: "invoice 4471")
        let path = home.path + "/Desktop/Screenshot 14.png"
        var read: [(String, String)] = []
        for try await line in BatchText(helper: HelperTextTests.built).read([path]) { read.append(line) }
        #expect(read.map(\.0) == [path] && read.first?.1 == "invoice 4471")
    }
}
