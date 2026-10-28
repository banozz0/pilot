// Ported from AeroSpace 74a1bf17 Sources/AppBundleTests/AxUiElementWindowTypeTest.swift (MIT).
import AppKit
import Foundation
@testable import PilotTiler
import Testing

@Suite struct AxWindowKindTest {
    /// Every axDump records what the heuristics must answer for that window; the dumps ship as test resources.
    @Test func test() throws {
        let dumps = try #require(Bundle.module.url(forResource: "axDumps", withExtension: nil))
        let count = try checkAxDumpsRecursive(dumps)
        #expect(count > 100)
    }
}

/// The number of dumps checked.
private func checkAxDumpsRecursive(_ dir: URL) throws -> Int {
    var count = 0
    for file in try FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) {
        if file.isDirectory {
            count += try checkAxDumpsRecursive(file)
            continue
        }
        if file.pathExtension == "md" { continue }

        let rawJson = try #require(
            try JSONSerialization.jsonObject(with: Data(contentsOf: file), options: [.json5Allowed]) as? [String: Any],
        )
        let json = try #require(try Json.newOrDieRecursive(rawJson).asDictOrNil)
        let app = try #require(json["Aero.AXApp"]?.asDictOrNil)
        let appBundleId = (rawJson["Aero.App.appBundleId"] as? String).flatMap(KnownBundleId.init(bundleId:))
        let windowLevel = try json["Aero.windowLevel"].map { try #require(MacOsWindowLevel.fromJson($0)) }
        let rawPolicy = try #require(rawJson["Aero.App.nsApp.activationPolicy"] as? String)
        let activationPolicy: NSApplication.ActivationPolicy = try .from(string: rawPolicy)
        let rawType = try #require(rawJson["Aero.AxUiElementWindowType"] as? String)
        let expectedType = try #require(AxUiElementWindowType(rawValue: rawType))
        #expect(
            json.getWindowType(axApp: app, appBundleId, activationPolicy, windowLevel) == expectedType,
            "\(file.path()):0:0: AxUiElementWindowType doesn't match",
        )
        let expectedDialog = try #require(rawJson["Aero.AxUiElementWindowType_isDialogHeuristic"] as? Bool)
        #expect(
            json.isDialogHeuristic(appBundleId, windowLevel) == expectedDialog,
            "\(file.path()):0:0: AxUiElementWindowType_isDialogHeuristic doesn't match",
        )
        count += 1
    }
    return count
}

extension [String: Json]: AxUiElementMock {
    /// AeroSpace died on a missing or unconvertible value; here the test records it and the attribute reads nil.
    public func get<Attr>(_ attr: Attr) -> Attr.T? where Attr: ReadableAttr {
        guard let value = self[attr.key] else {
            if isSynthetic { Issue.record("\(self) doesn't contain \(attr.key)") }
            return nil
        }
        guard let value = value.rawValue else { return nil }
        let converted = attr.getter(value as AnyObject)
        if converted == nil {
            Issue.record("Value \(value) (of type \(Swift.type(of: value))) isn't convertible to \(attr.key)")
        }
        return converted
    }

    private var isSynthetic: Bool { self[kAXAeroSynthetic] != nil }

    public func containingWindowId() -> CGWindowID? {
        guard let windowId = self["Aero.axWindowId"]?.asInt64OrNil else {
            Issue.record("\(self) has no Aero.axWindowId")
            return nil
        }
        return UInt32(exactly: windowId)
    }
}

extension NSApplication.ActivationPolicy {
    static func from(string: String) throws -> NSApplication.ActivationPolicy {
        switch string {
            case "regular": .regular
            case "accessory": .accessory
            case "prohibited": .prohibited
            default: try raiseFault("Unknown ActivationPolicy \(string)")
        }
    }
}

extension URL {
    var isDirectory: Bool {
        (try? resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true
    }
}
