import Foundation
import Testing

/// Pilot's lean budgets (story 142, Sven 2026-10-08): the built app and its main program stay inside the sizes in
/// Scripts/lean-budgets.json, the file Scripts/lean-check.py also reads for RAM (before the app window first opens), CPU
/// and launch time on lane 1.
/// Measures build/Pilot.app as Scripts/build-app.sh last left it (or PILOT_APP), only when build-app.sh stamped it a release
/// build (PilotBuildConfiguration in its Info.plist); skipped for a debug, unstamped or missing bundle. Every release
/// build-app.sh run also checks the fresh bundle with lean-check.py.
private let root = URL(filePath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
private let builtApp = ProcessInfo.processInfo.environment["PILOT_APP"].map { URL(filePath: $0) } ?? root.appending(path: "build/Pilot.app")

@Suite("Lean budgets")
struct LeanBudgetTests {
    struct Budgets: Decodable { let appMB: Double; let binaryMB: Double }

    static let mib = 1_048_576.0

    /// Whether build-app.sh stamped this bundle a release build; a debug build is bigger and is never shipped.
    static func isRelease(_ app: URL) -> Bool {
        let info = NSDictionary(contentsOf: app.appending(path: "Contents/Info.plist"))
        return info?["PilotBuildConfiguration"] as? String == "release"
    }

    static func budgets() throws -> Budgets {
        try JSONDecoder().decode(Budgets.self, from: Data(contentsOf: root.appending(path: "Scripts/lean-budgets.json")))
    }

    /// Bytes on disk the way du counts them: every file's allocated size, through the whole folder.
    static func allocated(_ url: URL) throws -> Int {
        let keys: Set<URLResourceKey> = [.totalFileAllocatedSizeKey, .isRegularFileKey]
        let inside = FileManager.default.enumerator(at: url, includingPropertiesForKeys: Array(keys))?.compactMap { $0 as? URL } ?? []
        return try ([url] + inside).reduce(0) { sum, file in
            let values = try file.resourceValues(forKeys: keys)
            return sum + (values.isRegularFile == true ? values.totalFileAllocatedSize ?? 0 : 0)
        }
    }

    @Test("a folder's size counts every file in it, nested ones too")
    func allocatedCountsNestedFiles() throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: "lean-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder.appending(path: "Contents/MacOS"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        try Data(count: 1 << 20).write(to: folder.appending(path: "Contents/MacOS/Pilot"))
        try Data(count: 1 << 19).write(to: folder.appending(path: "Info.plist"))
        let mb = Double(try Self.allocated(folder)) / Self.mib
        #expect(mb >= 1.5 && mb < 1.6)
    }

    @Test("only a bundle build-app.sh stamped as a release build is judged, never a debug, unstamped or missing one")
    func judgesOnlyReleaseBundles() throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: "lean-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        func bundle(_ name: String, configuration: String?) throws -> URL {
            let app = folder.appending(path: "\(name).app")
            try FileManager.default.createDirectory(at: app.appending(path: "Contents"), withIntermediateDirectories: true)
            let info = configuration.map { ["PilotBuildConfiguration": $0] } ?? [:]
            try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
                .write(to: app.appending(path: "Contents/Info.plist"))
            return app
        }
        #expect(Self.isRelease(try bundle("release", configuration: "release")))
        #expect(!Self.isRelease(try bundle("debug", configuration: "debug")))
        #expect(!Self.isRelease(try bundle("unstamped", configuration: nil)))
        #expect(!Self.isRelease(folder.appending(path: "missing.app")))
    }

    @Test("the budget file sets a size for the app and its main program")
    func budgetFile() throws {
        let budgets = try Self.budgets()
        #expect(budgets.appMB > budgets.binaryMB && budgets.binaryMB > 0)
    }

    @Test("the built app and its main program fit their size budgets", .enabled(if: LeanBudgetTests.isRelease(builtApp), "judges only a release bundle: build/Pilot.app is missing, a debug build, or built before build-app.sh stamped its configuration"))
    func builtAppSize() throws {
        let budgets = try Self.budgets()
        let app = Double(try Self.allocated(builtApp)) / Self.mib
        let binary = Double(try Self.allocated(builtApp.appending(path: "Contents/MacOS/Pilot"))) / Self.mib
        #expect(app <= budgets.appMB, "Pilot.app is \(Int(app.rounded())) MB, over its \(Int(budgets.appMB)) MB budget")
        #expect(binary <= budgets.binaryMB, "Pilot's main program is \(Int(binary.rounded())) MB, over its \(Int(budgets.binaryMB)) MB budget")
    }
}
