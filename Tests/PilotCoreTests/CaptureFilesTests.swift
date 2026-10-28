import Foundation
import Testing
@testable import PilotCore

/// Where captures and recordings go and what they are called (spec `capture.html`, Q157): `~/Pictures/Pilot` and
/// `~/Movies/Pilot` unless Sven picks others, named as the Mac names its own.
@Suite("Capture files")
struct CaptureFilesTests {
    static let date = Date(timeIntervalSince1970: 1_792_152_202) // 2026-10-16 14:03:22 in Malta (UTC+2)
    static let malta = TimeZone(identifier: "Europe/Malta")!

    @Test("Names follow the Mac's pattern in the Mac's time zone")
    func names() {
        #expect(CaptureFiles.name(.capture, at: Self.date, zone: Self.malta) == "Capture 2026-10-16 at 14.03.22.png")
        #expect(CaptureFiles.name(.recording, at: Self.date, zone: Self.malta) == "Recording 2026-10-16 at 14.03.22.mp4")
    }

    @Test("A second capture in the same second gets a number, never the first one's file")
    func free() {
        let folder = URL(filePath: "/tmp/caps", directoryHint: .isDirectory)
        let taken: Set<String> = ["Capture 2026-10-16 at 14.03.22.png", "Capture 2026-10-16 at 14.03.22 2.png"]
        let url = CaptureFiles.freeURL(.capture, in: folder, at: Self.date, zone: Self.malta) { taken.contains($0.lastPathComponent) }
        #expect(url.lastPathComponent == "Capture 2026-10-16 at 14.03.22 3.png")
    }

    @Test("The standard folders are Pilot's own; a picked one wins, ~ expanded")
    func folders() {
        let home = URL(filePath: "/Users/test", directoryHint: .isDirectory)
        #expect(CaptureSettings().folder(.capture, home: home).path == "/Users/test/Pictures/Pilot")
        #expect(CaptureSettings().folder(.recording, home: home).path == "/Users/test/Movies/Pilot")
        let picked = CaptureSettings(capturesFolder: "/Volumes/Shots", recordingsFolder: "~/Desktop")
        #expect(picked.folder(.capture, home: home).path == "/Volumes/Shots")
        #expect(picked.folder(.recording, home: home).path == NSHomeDirectory() + "/Desktop")
    }

    @Test("Recent lists images and movies from both folders, newest first, nothing else")
    func recent() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "capture-files-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: root) }
        let shots = root.appending(path: "shots"), films = root.appending(path: "films")
        for folder in [shots, films] { try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true) }
        func make(_ folder: URL, _ name: String, age: TimeInterval) throws {
            let url = folder.appending(path: name)
            try Data("x".utf8).write(to: url)
            try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(-age)], ofItemAtPath: url.path)
        }
        try make(shots, "Capture a.png", age: 30)
        try make(shots, "notes.txt", age: 1)
        try make(shots, ".hidden.png", age: 1)
        try make(films, "Recording b.mp4", age: 10)
        try make(films, "Capture c.png", age: 5)
        let listed = CaptureFiles.recent(captures: shots, recordings: films)
        #expect(listed.map(\.url.lastPathComponent) == ["Recording b.mp4", "Capture a.png"])
        #expect(listed.map(\.kind) == [.recording, .capture])
        #expect(CaptureFiles.recent(captures: root.appending(path: "none"), recordings: root.appending(path: "none")).isEmpty)
    }
}
