import Foundation
import PilotCore
import Testing
@testable import Pilot

/// A Mac's defaults in memory: what each kind opens with, what can open it, and every change asked for. Never NSWorkspace.
@MainActor
final class FakeDefaultApps: DefaultAppsSystem {
    static let https = DefaultHandler.url("https://example.com"), http = DefaultHandler.url("http://example.com")
    var defaults: [DefaultHandler: String] = [.contentType("public.plain-text"): "com.microsoft.VSCode",
                                              .contentType("com.adobe.pdf"): "com.apple.Preview", https: "com.google.Chrome",
                                              http: "com.google.Chrome"]
    var refuse: String?
    /// macOS showed its confirmation and Sven said no: no error, the default stays.
    var declined = false
    var sets: [(String, DefaultHandler)] = []

    func current(_ handler: DefaultHandler) -> String? { defaults[handler] }
    func choices(_ handlers: [DefaultHandler]) -> [(name: String, bundle: String)] {
        [("TextEdit", "com.apple.TextEdit"), ("Visual Studio Code", "com.microsoft.VSCode"), ("Zen", "app.zen-browser.zen")]
    }
    func name(_ bundle: String) -> String { "Name of \(bundle)" }
    /// As macOS does, a new https handler takes http with it.
    func setDefault(_ bundle: String, for handler: DefaultHandler) async throws {
        sets.append((bundle, handler))
        if let refuse { throw NSError(domain: "test", code: 1, userInfo: [NSLocalizedDescriptionKey: refuse]) }
        guard !declined else { return }
        defaults[handler] = bundle
        if handler == Self.https { defaults[Self.http] = bundle }
    }
}

/// Card agent-bo-95422842: the Default apps page reads each kind's default and changes it only on Sven's pick.
@MainActor
@Suite("Default apps page")
struct DefaultAppsModelTests {
    private let text = FileKind(id: "txt", name: "Plain text", handlers: [.contentType("public.plain-text")])
    private let pdf = FileKind(id: "pdf", name: "PDF", handlers: [.contentType("com.adobe.pdf")])
    private let web = FileKind(id: "web", name: "Web links", handlers: [FakeDefaultApps.https, FakeDefaultApps.http], confirmNote: "macOS asks")

    @Test("Loading reads each kind's default and its apps, and changes nothing")
    func load() {
        let system = FakeDefaultApps(), forgot = Forgot()
        let model = DefaultAppsModel(kinds: [text, pdf], system: system) { forgot.roles.append($0) }
        model.load()
        #expect(model.rows[text.id]?.current == "com.microsoft.VSCode")
        #expect(model.rows[pdf.id]?.current == "com.apple.Preview")
        #expect(model.rows[text.id]?.choices.map(\.bundle) == ["com.apple.TextEdit", "com.microsoft.VSCode", "app.zen-browser.zen"])
        // Preview is the PDF default but not among the apps macOS listed, so it leads the list by name.
        #expect(model.rows[pdf.id]?.choices.first?.bundle == "com.apple.Preview")
        #expect(model.rows[pdf.id]?.choices.first?.name == "Name of com.apple.Preview")
        #expect(system.sets.isEmpty && forgot.roles.isEmpty)
    }

    @Test("A pick changes that kind only, and the row reads the new default back")
    func pick() async {
        let system = FakeDefaultApps(), forgot = Forgot()
        let model = DefaultAppsModel(kinds: [text, pdf], system: system) { forgot.roles.append($0) }
        model.load()
        await model.change(text, to: "com.apple.TextEdit")
        #expect(system.sets.count == 1 && system.sets.first?.0 == "com.apple.TextEdit" && system.sets.first?.1 == .contentType("public.plain-text"))
        #expect(model.rows[text.id]?.current == "com.apple.TextEdit")
        #expect(model.rows[pdf.id]?.current == "com.apple.Preview")
        #expect(model.rows[text.id]?.message == nil)
        // Plain text feeds the main editor, which resolves each time anyway.
        #expect(forgot.roles == [.editor])
        // Picking what it already is asks macOS nothing.
        await model.change(text, to: "com.apple.TextEdit")
        #expect(system.sets.count == 1)
    }

    @Test("A new browser is asked of macOS once, for https, which takes http, and Pilot's browser role finds its app again")
    func schemeForgetsRole() async {
        let system = FakeDefaultApps(), forgot = Forgot()
        let model = DefaultAppsModel(kinds: [web], system: system) { forgot.roles.append($0) }
        model.load()
        await model.change(web, to: "app.zen-browser.zen")
        #expect(model.rows[web.id]?.current == "app.zen-browser.zen")
        #expect(system.sets.count == 1 && system.sets.first?.1 == FakeDefaultApps.https)
        #expect(system.defaults[FakeDefaultApps.http] == "app.zen-browser.zen")
        #expect(forgot.roles == [.browser])
    }

    @Test("A refused or declined change keeps the old default and says so")
    func refused() async {
        let system = FakeDefaultApps(), forgot = Forgot()
        let model = DefaultAppsModel(kinds: [text, web], system: system) { forgot.roles.append($0) }
        model.load()
        system.refuse = "The operation couldn't be completed."
        await model.change(text, to: "com.apple.TextEdit")
        #expect(model.rows[text.id]?.current == "com.microsoft.VSCode")
        #expect(model.rows[text.id]?.message == "Not changed: The operation couldn't be completed.")
        system.refuse = nil
        system.declined = true
        await model.change(web, to: "app.zen-browser.zen")
        #expect(model.rows[web.id]?.current == "com.google.Chrome")
        #expect(model.rows[web.id]?.message == "Not changed: macOS kept the old app.")
        #expect(forgot.roles.isEmpty)
    }
}

@MainActor
final class Forgot { var roles: [AppRole] = [] }
