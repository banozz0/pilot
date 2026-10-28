import Foundation
import PilotCore
import Testing
@testable import Pilot

/// Card agent-bo-95423261: tests set the Style and layout on Look.shared and on Looks built without a store, which saved
/// them into the test runner's shared defaults (look.style left as Toybox, the layout as Calm), and the next run's
/// menu-scroll tests read them back and failed. A Look in a test run saves to a throwaway suite instead.
@MainActor
@Suite("Look isolation")
struct LookIsolationTests {
    static let keys = ["look.style", "look.glass", "look.layout"]

    @Test("A Look built without a store leaves the runner's shared look.* defaults as they were")
    func defaultStoreIsIsolated() {
        let shared = UserDefaults.standard
        let before = Self.keys.map { shared.object(forKey: $0) as? NSObject }
        let look = Look(inputSources: SetupKeepAwakeTests.FakeSources())
        look.style = look.style == .toybox ? .instrument : .toybox
        look.glass.toggle()
        let after = Self.keys.map { shared.object(forKey: $0) as? NSObject }
        // Only a leak is undone, so a red run doesn't leave the runner's defaults changed either.
        if after != before { for (key, value) in zip(Self.keys, before) { shared.set(value, forKey: key) } }
        #expect(after == before, "a test Look saved look.* into the test runner's shared defaults")
    }

    /// A test that sets Look.shared while a Shared look suite draws on it changes that suite's pixels mid-draw: Style seam's
    /// frame test failed under full-suite load, and Menu scroll measures by Look.shared's style. A test that reads it
    /// meanwhile reads another suite's pick (Menu panel pointer's kind tabs, 2026-10-10). Every test file that sets or reads
    /// Look.shared runs inside SharedLook, one suite at a time. A view that draws on it unnamed (HUD.makePanel's default
    /// look) is not seen here.
    @Test("Every test file that sets or reads Look.shared runs inside the serialized Shared look suite")
    func sharedLookUsersSerialized() throws {
        let dir = URL(filePath: #filePath).deletingLastPathComponent()
        let uses = #"Look\.shared\b|applyLook\(\.shared"#
        let files = try FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil).filter { $0.pathExtension == "swift" }
        let outside = try files.filter { file in
            // Comments and strings (a test's name) only speak of it.
            let code = try String(contentsOf: file, encoding: .utf8).split(separator: "\n", omittingEmptySubsequences: false)
                .map { $0.trimmingCharacters(in: .whitespaces).hasPrefix("//") ? "" : $0.replacing(/"(?:[^"\\]|\\.)*"/, with: "\"\"") }
                .joined(separator: "\n")
            // A use before the file's SharedLook wrap (which runs to the file's end), or with no wrap at all, is outside it.
            guard let use = code.range(of: uses, options: .regularExpression) else { return false }
            return code.range(of: "extension SharedLook {").map { use.lowerBound < $0.lowerBound } ?? true
        }.map(\.lastPathComponent).sorted()
        #expect(outside == [], "these set or read Look.shared outside SharedLook: \(outside)")
    }
}
