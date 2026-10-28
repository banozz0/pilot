import Foundation
import PilotCore
import Testing
@testable import Pilot

/// Remove's sizes (card agent-bo-95423022): each row measured where it lives, off the main thread; a folder's size is
/// its files' allocated bytes. The measure is a fake except on a temporary folder this test makes.
@Suite("Remove sizes")
struct RemoveSizeTests {
    @Test("Each row gets the size of where it lives; a row with no place, or a path not there, stays unmeasured")
    func measure() async {
        let rows = [RemoveRow(source: .app(path: "/Applications/Notion.app"), name: "Notion", app: "/Applications/Notion.app"),
                    RemoveRow(source: .package(Package(.uv, "ruff")!), name: "ruff"),
                    RemoveRow(source: .webApp(bundleID: "dev.banozz.pilot.webapp.x"), name: "X")]
        let sized = await InstallModule.measure(rows) { path in path.hasSuffix("Notion.app") ? 300_000_000 : nil }
        #expect(sized.map(\.size) == [300_000_000, nil, nil])
        #expect(sized.map(\.key) == rows.map(\.key), "the rows keep their order")
    }

    @Test("A folder's size is its files' bytes on disk; a missing path has none")
    func diskSize() throws {
        let dir = FileManager.default.temporaryDirectory.appending(path: "remove-size-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createDirectory(at: dir.appending(path: "bin"), withIntermediateDirectories: true)
        try Data(repeating: 1, count: 100_000).write(to: dir.appending(path: "bin/tool"))
        try Data(repeating: 2, count: 50_000).write(to: dir.appending(path: "README"))
        let bytes = try #require(InstallModule.diskSize(dir.path))
        #expect(bytes >= 150_000 && bytes < 300_000, "\(bytes)")
        #expect(InstallModule.diskSize(dir.appending(path: "gone").path) == nil)
    }
}

/// App Store apps are told by the receipt in their bundle (card agent-bo-95423022); a temporary bundle this test makes.
@Suite("Remove App Store apps")
struct RemoveAppStoreTests {
    @Test("A bundle with the App Store's receipt is an App Store app; one without is not")
    func receipt() throws {
        let dir = FileManager.default.temporaryDirectory.appending(path: "remove-mas-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = dir.appending(path: "Things3.app"), plain = dir.appending(path: "Notion.app")
        try FileManager.default.createDirectory(at: store.appending(path: "Contents/_MASReceipt"), withIntermediateDirectories: true)
        try Data("receipt".utf8).write(to: store.appending(path: "Contents/_MASReceipt/receipt"))
        try FileManager.default.createDirectory(at: plain.appending(path: "Contents"), withIntermediateDirectories: true)
        #expect(InstallModule.isAppStore(store.path))
        #expect(!InstallModule.isAppStore(plain.path))
    }
}
