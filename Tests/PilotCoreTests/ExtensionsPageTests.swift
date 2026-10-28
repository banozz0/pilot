import Foundation
import Testing
@testable import PilotCore

/// Card agent-bo-95423247: the Extensions page lists every extension with its commands, its permissions in plain words
/// and a field per preference with the value a run gets; a folder that is not an extension shows why.
@Suite("Extensions page")
struct ExtensionsPageTests {
    private func folder() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("pilot-ext-page-\(UUID().uuidString)").resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func write(_ manifest: String, as name: String, in dir: URL) throws {
        let ext = dir.appending(path: name)
        try FileManager.default.createDirectory(at: ext, withIntermediateDirectories: true)
        try Data(manifest.utf8).write(to: ext.appending(path: Extension.manifestName))
        try Data("#!/bin/sh\n".utf8).write(to: ext.appending(path: "go"))
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: ext.appending(path: "go").path)
    }

    @Test("Each extension shows its commands, its permissions in words and a field per preference of all seven types; a broken folder its reason")
    func rows() throws {
        let dir = try folder()
        defer { try? FileManager.default.removeItem(at: dir) }
        try write(#"""
            {"id": "gh", "title": "GitHub", "icon": "🐙",
             "permissions": {"network": ["api.github.com", "github.com"], "clipboard": true, "files": ["~/code"], "actions": ["windows.close"]},
             "preferences": [{"name": "user", "type": "text", "title": "User", "required": true},
                             {"name": "pin", "type": "password", "title": "PIN", "required": true},
                             {"name": "forks", "type": "checkbox", "title": "Show forks"},
                             {"name": "sort", "type": "dropdown", "title": "Sort", "default": "stars", "data": [{"title": "Stars", "value": "stars"}]},
                             {"name": "editor", "type": "app", "title": "Editor"},
                             {"name": "notes", "type": "file", "title": "Notes"},
                             {"name": "clones", "type": "folder", "title": "Clones"}],
             "commands": [{"name": "repos", "title": "My repos", "mode": "list", "run": "go"},
                          {"name": "star", "title": "Star", "mode": "no-view", "run": "go"}]}
            """#, as: "github", in: dir)
        try write(#"{"id": "bare", "title": "Bare", "commands": [{"name": "go", "title": "Go", "mode": "no-view", "run": "go"}]}"#, as: "bare", in: dir)
        try write(#"{"id": "Bad!", "title": "Bad", "commands": []}"#, as: "broken", in: dir)

        let found = Extension.find(in: dir)
        let rows = ExtensionsPage.rows(found, values: { ext in ext.id == "gh" ? ["user": .string("sven"), "forks": .bool(false), "sort": .string("stars")] : [:] },
                                       label: { $0 == "windows.close" ? "Close window" : nil })
        #expect(rows.map(\.ext.title) == ["Bare", "GitHub"])
        let gh = rows[1]
        #expect(gh.ext.commands.map(\.title) == ["My repos", "Star"] && gh.ext.commands.map(\.actionID) == ["ext.gh.repos", "ext.gh.star"])
        #expect(gh.permissions == [.init(.network, "Connects to api.github.com and github.com"), .init(.clipboard, "Reads and writes the clipboard"),
                                   .init(.files, "Reads and writes ~/code"), .init(.actions, "Runs Pilot actions: Close window")])
        #expect(rows[0].permissions == [.init(.nothing, "Touches nothing it names")])
        #expect(gh.fields.map(\.preference.kind) == [.text, .password, .checkbox, .dropdown([.init(title: "Stars", value: "stars")]), .app, .file, .folder])
        #expect(gh.fields.map(\.value) == [.string("sven"), nil, .bool(false), .string("stars"), nil, nil, nil])
        #expect(gh.fields.map(\.isMissing) == [false, true, false, false, false, false, false], "the unset required PIN")
        #expect(found.broken.map(\.folder) == ["broken"])
        #expect(found.broken[0].problem.reason == #"id "Bad!" must be lowercase letters, digits and hyphens"#)
    }

    @Test("pilot://open?page=extensions lands on the Extensions page, its own area on Cmd+9 (Sven 2026-10-16; Cmd+9 since Launcher took Cmd+3, P37)")
    func place() throws {
        #expect(AppPlace.linked(try #require(URL(string: "pilot://open?page=extensions&extension=gh"))) == AppPlace(.extensions))
        #expect(AppPage.extensions.area == .extensions && AppArea.extensions.key == "9")
        #expect(AppPlace.search("preference").first == AppPlace(.extensions))
    }
}
