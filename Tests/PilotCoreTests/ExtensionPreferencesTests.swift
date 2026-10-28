import Foundation
import Synchronization
import Testing
@testable import PilotCore

/// Card agent-bo-95423246 (ADR 0010): an extension declares preferences of seven types; Pilot keeps their values in
/// its ExtensionData folder, passwords in the Keychain (a fake here, never the real one), and hands them with the
/// extension's data and cache folders to every run in its run message, never in its arguments or environment. A command
/// whose required preference is unset does not run.
@Suite("Extension preferences")
struct ExtensionPreferencesTests {
    /// The Keychain as a dictionary, so no test touches the real one.
    final class FakeKeychain: ExtensionKeychain {
        let items = Mutex<[String: String]>([:])
        func password(extension id: String, preference name: String) -> String? { items.withLock { $0["\(id)/\(name)"] } }
        func setPassword(_ password: String?, extension id: String, preference name: String) throws { items.withLock { $0["\(id)/\(name)"] = password } }
        func hasPassword(extension id: String, preference name: String) -> Bool { items.withLock { $0["\(id)/\(name)"] != nil } }
    }

    private func folder(_ name: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("pilot-ext-pref-\(name)-\(UUID().uuidString)").resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// An extension in a fresh folder with `preferences` and one no-view command running `body`.
    private func extensionWith(_ preferences: String, body: String = "true") throws -> Extension {
        let dir = try folder("ext")
        try Data(#"{"id": "demo", "title": "Demo", "preferences": [\#(preferences)], "commands": [{"name": "go", "title": "Go", "mode": "no-view", "run": "go"}]}"#.utf8)
            .write(to: dir.appending(path: Extension.manifestName))
        let program = dir.appending(path: "go")
        try Data("#!/bin/sh\n\(body)\n".utf8).write(to: program)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: program.path)
        return try Extension(folder: dir)
    }

    private let allSeven = """
        {"name": "user", "type": "text", "title": "User", "required": true, "default": "sven", "description": "Your GitHub login"},
        {"name": "pin", "type": "password", "title": "PIN", "required": true},
        {"name": "forks", "type": "checkbox", "title": "Show forks", "default": true},
        {"name": "sort", "type": "dropdown", "title": "Sort", "default": "stars",
         "data": [{"title": "Stars", "value": "stars"}, {"title": "Updated", "value": "updated"}]},
        {"name": "editor", "type": "app", "title": "Editor"},
        {"name": "notes", "type": "file", "title": "Notes file"},
        {"name": "clones", "type": "folder", "title": "Clones"}
        """

    @Test("All seven preference types decode with their title, required, default and description")
    func decodes() throws {
        let ext = try extensionWith(allSeven)
        defer { try? FileManager.default.removeItem(at: ext.folder) }
        typealias P = Extension.Preference
        #expect(ext.preferences.map(\.kind) == [.text, .password, .checkbox,
                                                .dropdown([P.Option(title: "Stars", value: "stars"), P.Option(title: "Updated", value: "updated")]),
                                                .app, .file, .folder])
        #expect(ext.preferences[0] == P(name: "user", title: "User", kind: .text, required: true, default: .string("sven"),
                                        description: "Your GitHub login"))
        #expect(ext.preferences.map(\.required) == [true, true, false, false, false, false, false])
        #expect(ext.preferences[2].default == .bool(true) && ext.preferences[3].default == .string("stars"))
        #expect(ext.preferences[4].default == nil && ext.preferences[4].description == nil)
    }

    @Test("A bad preference makes the folder no extension, with its reason")
    func refuses() throws {
        func problem(_ preference: String) throws -> Extension.Problem? {
            do { let ext = try extensionWith(preference); try? FileManager.default.removeItem(at: ext.folder); return nil }
            catch let p as Extension.Problem { return p }
        }
        #expect(try problem(#"{"name": "a", "type": "color", "title": "A"}"#) == .unknownPreferenceType(preference: "a", type: "color"))
        #expect(try problem(#"{"name": "a", "type": "dropdown", "title": "A"}"#) == .noOptions(preference: "a"))
        #expect(try problem(#"{"name": "a", "type": "text", "title": "A"}, {"name": "a", "type": "text", "title": "B"}"#)
                == .duplicatePreference("a"))
        #expect(try problem(#"{"name": "a b", "type": "text", "title": "A"}"#) == .badPreferenceName("a b"))
        #expect(try problem(#"{"name": "a", "type": "checkbox", "title": "A", "default": "yes"}"#) == .badDefault(preference: "a"))
        #expect(try problem(#"{"name": "a", "type": "dropdown", "title": "A", "default": "c", "data": [{"title": "B", "value": "b"}]}"#)
                == .badDefault(preference: "a"))
        #expect(Extension.Problem.unknownPreferenceType(preference: "a", type: "color").reason
                == #"preference a: type "color" is not text, password, checkbox, dropdown, app, file or folder"#)
    }

    @Test("Each type saves and reads back; a password goes only to the Keychain, never preferences.json; removing the extension leaves its data")
    func store() throws {
        let ext = try extensionWith(allSeven)
        let data = try folder("data"), cache = try folder("cache")
        defer { [data, cache].forEach { try? FileManager.default.removeItem(at: $0) } }
        let keychain = FakeKeychain()
        let storage = ExtensionStorage(data: data, cache: cache, keychain: keychain)
        #expect(storage.values(of: ext) == ["user": .string("sven"), "forks": .bool(true), "sort": .string("stars")], "defaults until set")

        let set: [String: JSONValue] = ["user": .string("banozz0"), "pin": .string("pw-SAMPLE-41"), "forks": .bool(false),
                                        "sort": .string("updated"), "editor": .string("/Applications/Zed.app"),
                                        "notes": .string("/Users/test/notes.md"), "clones": .string("/Users/test/code")]
        for preference in ext.preferences { try storage.set(set[preference.name], for: preference, of: ext) }
        #expect(storage.values(of: ext) == set)
        #expect(keychain.items.withLock { $0 } == ["demo/pin": "pw-SAMPLE-41"])
        let file = data.appending(path: "demo/preferences.json")
        let saved = try String(contentsOf: file, encoding: .utf8)
        #expect(!saved.contains("pw-SAMPLE-41") && !saved.contains("pin"), "preferences.json holds no password: \(saved)")
        #expect(saved.contains("banozz0") && saved.contains("Zed.app"))

        try storage.set(nil, for: ext.preferences[1], of: ext)
        try storage.set(nil, for: ext.preferences[0], of: ext)
        #expect(keychain.items.withLock { $0 }.isEmpty, "a cleared password leaves the Keychain")
        #expect(storage.values(of: ext)["user"] == .string("sven"), "a cleared value falls back to its default")

        try FileManager.default.removeItem(at: ext.folder)
        #expect(FileManager.default.fileExists(atPath: file.path), "the extension's data outlives its folder")
    }

    @Test("A required preference unset stops the run with its name; an empty text counts as unset; the folders are made on first run")
    func required() throws {
        let ext = try extensionWith(allSeven)
        let data = try folder("data"), cache = try folder("cache")
        defer { [ext.folder, data, cache].forEach { try? FileManager.default.removeItem(at: $0) } }
        let storage = ExtensionStorage(data: data, cache: cache, keychain: FakeKeychain())
        #expect(throws: ExtensionStorage.Unset(preference: ext.preferences[1])) { try storage.inputs(for: ext) }
        try storage.set(.string(""), for: ext.preferences[1], of: ext)
        #expect(throws: ExtensionStorage.Unset(preference: ext.preferences[1])) { try storage.inputs(for: ext) }
        #expect(ExtensionStorage.Unset(preference: ext.preferences[1]).message(in: ext) == "Demo needs PIN set first.")
        try storage.set(.string("pw-SAMPLE-41"), for: ext.preferences[1], of: ext)
        try storage.set(.string(""), for: ext.preferences[0], of: ext)
        #expect(throws: ExtensionStorage.Unset(preference: ext.preferences[0])) { try storage.inputs(for: ext) }
        try storage.set(nil, for: ext.preferences[0], of: ext)

        let inputs = try storage.inputs(for: ext)
        #expect(inputs.data == data.appending(path: "demo/data") && inputs.cache == cache.appending(path: "demo"))
        var isFolder: ObjCBool = false
        #expect(FileManager.default.fileExists(atPath: inputs.data.path, isDirectory: &isFolder) && isFolder.boolValue)
        #expect(FileManager.default.fileExists(atPath: inputs.cache.path, isDirectory: &isFolder) && isFolder.boolValue)
        #expect(inputs.preferences["pin"] == .string("pw-SAMPLE-41") && inputs.preferences["user"] == .string("sven"))
    }

    @Test("The run message carries the preferences and both folders; the environment holds none of them")
    func runMessage() async throws {
        let ext = try extensionWith(allSeven, body: "cat; echo ---; env")
        let data = try folder("data"), cache = try folder("cache")
        defer { [ext.folder, data, cache].forEach { try? FileManager.default.removeItem(at: $0) } }
        let storage = ExtensionStorage(data: data, cache: cache, keychain: FakeKeychain())
        try storage.set(.string("pw-SAMPLE-41"), for: ext.preferences[1], of: ext)
        let inputs = try storage.inputs(for: ext)
        let output = try await ExtensionRun.output(ext.commands[0], inputs: inputs, environment: ["HOME": "/Users/test", "PATH": "/usr/bin:/bin"])
        let parts = output.components(separatedBy: "---\n")
        let message = try JSONDecoder().decode([String: JSONValue].self, from: Data(parts[0].utf8))
        #expect(message["preferences"] == .object(["user": .string("sven"), "pin": .string("pw-SAMPLE-41"), "forks": .bool(true),
                                                   "sort": .string("stars")]))
        #expect(message["paths"] == .object(["data": .string(inputs.data.path), "cache": .string(inputs.cache.path)]))
        let env = parts[1]
        #expect(!env.contains("pw-SAMPLE-41") && !env.contains("sven") && !env.contains(data.path) && !env.contains(cache.path), "env: \(env)")
    }

    @Test("The real Keychain saves, reads back, replaces and removes a password", .enabled(if: ProcessInfo.processInfo.environment["PILOT_LIVE"] == "1"))
    func liveKeychain() throws {
        let keychain = SystemKeychain(), id = "live-test-\(UUID().uuidString.prefix(8).lowercased())"
        defer { try? keychain.setPassword(nil, extension: id, preference: "pin") }
        try keychain.setPassword("pw-SAMPLE-1", extension: id, preference: "pin")
        #expect(keychain.password(extension: id, preference: "pin") == "pw-SAMPLE-1")
        try keychain.setPassword("pw-SAMPLE-2", extension: id, preference: "pin")
        #expect(keychain.password(extension: id, preference: "pin") == "pw-SAMPLE-2")
        try keychain.setPassword(nil, extension: id, preference: "pin")
        #expect(keychain.password(extension: id, preference: "pin") == nil)
    }
}
