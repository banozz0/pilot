import Foundation
import Testing
@testable import Pilot

/// Pilot starts in libmalloc's space-efficient mode and keeps it to itself (story 142, 2026-10-11).
@Suite("Malloc mode", .serialized)
struct MallocModeTests {
    static let infoPlist = URL(filePath: #filePath).deletingLastPathComponent().appending(path: "../../Packaging/Info.plist").standardized

    @Test("The bundle's Info.plist starts Pilot with MallocSpaceEfficient=1")
    func bundleStartsSpaceEfficient() throws {
        let plist = try #require(NSDictionary(contentsOf: Self.infoPlist))
        let environment = try #require(plist["LSEnvironment"] as? [String: String])
        #expect(environment[MallocMode.variable] == "1")
    }

    @Test("Once read it leaves the environment, so no child Pilot starts inherits it")
    func childrenKeepTheDefault() {
        setenv(MallocMode.variable, "1", 1)
        MallocMode.forgetForChildren()
        #expect(getenv(MallocMode.variable) == nil)
        #expect(ProcessInfo.processInfo.environment[MallocMode.variable] == nil)
    }
}
