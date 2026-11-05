import AppKit
import Foundation
import Testing
@testable import Pilot

/// The cursor engine's backup and Restore (P84) against a fake system: nothing here reaches SkyLight, so no test changes
/// a real cursor. The backup gates every `com.apple.coregraphics.*` name, and the applied stamp is this boot's.
@Suite("Cursor engine")
struct CursorEngineTests {
    static let build = "Version 27.2 (Build 27C52)", session = "boot-now"

    /// macOS's cursors as a fake WindowServer holds them; macOS's art is 99 pt, Pilot's 32, so each tells which it is.
    final class FakeCursors: CursorSystem, @unchecked Sendable {
        var macOS: [String: CursorCalls.Registered]
        var registered: [String: CursorCalls.Registered] = [:]
        var log: [String] = []
        var refuses: Set<String> = []
        var dock: Bool?

        init(macOS names: some Sequence<String> = CursorNames.coreGraphicsNames, size: CGFloat = 99) {
            macOS = Dictionary(uniqueKeysWithValues: names.map { ($0, FakeCursors.art(size)) })
        }

        static func art(_ size: CGFloat) -> CursorCalls.Registered {
            .init(size: CGSize(width: size, height: size), hotspot: CGPoint(x: 1, y: 1), frames: 1, duration: 0, images: [pixel])
        }
        /// One opaque pixel: the tests read sizes, never colours.
        static let pixel: CGImage = {
            let ctx = CGContext(data: nil, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4, space: CGColorSpaceCreateDeviceRGB(),
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            ctx.fill(CGRect(x: 0, y: 0, width: 1, height: 1))
            return ctx.makeImage()!
        }()

        func read(_ name: String) -> CursorCalls.Registered? {
            log.append("read \(name)")
            return registered[name] ?? macOS[name]
        }

        func register(_ name: String, _ cursor: CursorCalls.Registered) -> Int32 {
            log.append("register \(name)")
            if refuses.contains(name) { return 1000 }
            registered[name] = cursor
            return 0
        }

        func remove(_ name: String) { registered[name] = nil }

        func resetCoreCursors() -> Int32 {
            registered = registered.filter { CursorNames.coreGraphicsNames.contains($0.key) }
            return 0
        }

        func dockOverride(_ on: Bool) { dock = on }

        /// The backup reads taken before Pilot's first register.
        var readsBeforeRegister: Int { log.prefix { !$0.hasPrefix("register") }.count }
        func size(_ name: String) -> CGFloat? { registered[name]?.size.width }
    }

    /// A throwaway backup file and defaults for one test.
    struct Rig {
        let dir = FileManager.default.temporaryDirectory.appending(path: "cursor-engine-\(UUID().uuidString)")
        let defaults = UserDefaults(suiteName: testSuite())!
        var backupURL: URL { dir.appending(path: "macOS backup.plist") }

        func place(_ url: URL? = nil) -> CursorPlace {
            CursorPlace(backupURL: url ?? backupURL, build: CursorEngineTests.build, session: CursorEngineTests.session, defaults: defaults)
        }
        var stamp: String? { defaults.string(forKey: CursorPlace.appliedKey) }

        func apply(_ fake: FakeCursors, _ url: URL? = nil) -> String {
            CursorEngine.apply(.quiet, colours: .own, theme: "", system: fake, place: place(url), folder: CursorRenders.packaging)
        }
        func restore(_ fake: FakeCursors) -> String { CursorEngine.restore(system: fake, place: place()) }

        /// A backup as an earlier run left it.
        func saveBackup(build: String, size: CGFloat) throws {
            try CursorBackup(build: build, cursors: CursorNames.coreGraphicsNames.map { CursorBackup.Cursor($0, FakeCursors.art(size))! }).save(backupURL)
        }
    }

    static let arrow = CursorNames.coreGraphics + "Arrow", arrowS = CursorNames.coreGraphics + "ArrowS", ibeamS = CursorNames.coreGraphics + "IBeamS"

    @Test("A full backup comes before the first register, and Restore puts every name back and clears the stamp")
    func full() {
        let rig = Rig(), fake = FakeCursors()
        let line = rig.apply(fake)
        #expect(line.hasPrefix("Quiet is on") && !line.contains("stay macOS's"), "\(line)")
        #expect(fake.readsBeforeRegister == CursorNames.coreGraphicsNames.count)
        #expect(CursorBackup.load(rig.backupURL, build: Self.build)?.complete == true)
        #expect(CursorNames.coreGraphicsNames.allSatisfy { fake.size($0) == 32 } && fake.size(CursorNames.numbered(13)) == 32)
        #expect(rig.stamp == Self.session && fake.dock == true)
        #expect(rig.restore(fake) == "macOS's cursor is back.")
        #expect(CursorNames.coreGraphicsNames.allSatisfy { fake.size($0) == 99 } && fake.size(CursorNames.numbered(13)) == nil)
        #expect(rig.stamp == nil && fake.dock == false)
    }

    @Test("A partial backup registers only the names it holds, and is retaken on the next first apply")
    func partial() {
        let rig = Rig(), fake = FakeCursors(macOS: CursorNames.coreGraphicsNames.subtracting([Self.arrowS, Self.ibeamS]))
        let line = rig.apply(fake)
        #expect(line.contains("2 stay macOS's"), "\(line)")
        #expect(fake.registered[Self.arrowS] == nil && fake.registered[Self.ibeamS] == nil && fake.size(Self.arrow) == 32)
        #expect(CursorBackup.load(rig.backupURL, build: Self.build)?.cursors.count == CursorNames.coreGraphicsNames.count - 2)
        #expect(rig.restore(fake) == "macOS's cursor is back." && rig.stamp == nil)
        #expect(fake.registered.allSatisfy { $0.value.size.width == 99 })
        // Not applied now, and the backup lacks two names: the next apply backs up again first.
        fake.log = []
        fake.macOS[Self.arrowS] = FakeCursors.art(99)
        _ = rig.apply(fake)
        #expect(fake.readsBeforeRegister == CursorNames.coreGraphicsNames.count && fake.size(Self.arrowS) == 32)
        // Applied in this boot: no backup is taken over Pilot's art, and IBeamS, never backed up, keeps macOS's.
        fake.log = []
        fake.macOS[Self.ibeamS] = FakeCursors.art(99)
        _ = rig.apply(fake)
        #expect(fake.readsBeforeRegister == 0 && fake.registered[Self.ibeamS] == nil)
    }

    @Test("An empty backup refuses the apply: nothing registered, no stamp, no file")
    func empty() {
        let rig = Rig(), fake = FakeCursors(macOS: [])
        #expect(rig.apply(fake) == "macOS would not hand over its own cursors to back up, so Pilot changed nothing.")
        #expect(fake.registered.isEmpty && !fake.log.contains { $0.hasPrefix("register") } && fake.dock == nil)
        #expect(rig.stamp == nil && !FileManager.default.fileExists(atPath: rig.backupURL.path))
    }

    @Test("A save that throws refuses the apply: nothing registered, no stamp")
    func saveThrows() throws {
        let rig = Rig(), fake = FakeCursors()
        try FileManager.default.createDirectory(at: rig.dir, withIntermediateDirectories: true)
        let file = rig.dir.appending(path: "a file")
        try Data("x".utf8).write(to: file)
        #expect(rig.apply(fake, file.appending(path: "macOS backup.plist")) == "Pilot could not save macOS's cursors first, so it changed nothing.")
        #expect(fake.registered.isEmpty && fake.dock == nil && rig.stamp == nil)
    }

    @Test("After a macOS update and restart, the old build's backup is retaken and Restore puts back the new build's")
    func previousBuild() throws {
        let rig = Rig(), fake = FakeCursors()
        try rig.saveBackup(build: "Version 27.1 (Build 27B40)", size: 50)
        rig.defaults.set("boot-before", forKey: CursorPlace.appliedKey)     // stamped before the restart
        _ = rig.apply(fake)
        #expect(fake.readsBeforeRegister == CursorNames.coreGraphicsNames.count)
        #expect(CursorBackup.load(rig.backupURL, build: Self.build) != nil)
        #expect(rig.restore(fake) == "macOS's cursor is back." && fake.size(Self.arrow) == 99)
    }

    @Test("A stamp from a previous boot reads as not applied: Restore leaves macOS's own alone, apply reuses a whole backup")
    func previousBoot() throws {
        let rig = Rig(), fake = FakeCursors()
        try rig.saveBackup(build: Self.build, size: 99)
        rig.defaults.set("boot-before", forKey: CursorPlace.appliedKey)
        #expect(rig.restore(fake) == "macOS's cursor is on.")
        #expect(!fake.log.contains { $0.hasPrefix("register") } && rig.stamp == "boot-before")
        _ = rig.apply(fake)
        #expect(fake.readsBeforeRegister == 0 && CursorNames.coreGraphicsNames.allSatisfy { fake.size($0) == 32 } && rig.stamp == Self.session)
    }

    @Test("A Restore that cannot put a name back, or finds the backup gone, says so and keeps the stamp")
    func restoreFalls() throws {
        let rig = Rig(), fake = FakeCursors()
        _ = rig.apply(fake)
        fake.refuses = [Self.arrow]
        let line = rig.restore(fake)
        #expect(line == "\(CursorNames.coreGraphicsNames.count - 1) of macOS's \(CursorNames.coreGraphicsNames.count) backed-up cursors came back. A restart brings back the rest.")
        #expect(rig.stamp == Self.session)
        fake.refuses = []
        try FileManager.default.removeItem(at: rig.backupURL)
        #expect(rig.restore(fake) == "macOS's cursor is back, but its backup is gone: a restart brings back its arrow and I-beam.")
        #expect(rig.stamp == Self.session)
        // Still applied with no backup: the next apply touches no com.apple.coregraphics name.
        fake.log = []
        _ = rig.apply(fake)
        #expect(!fake.log.contains { $0.hasPrefix("register " + CursorNames.coreGraphics) } && fake.log.contains("register \(CursorNames.numbered(13))"))
    }
}
