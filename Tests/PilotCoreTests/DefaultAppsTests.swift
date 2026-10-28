import Testing
@testable import PilotCore

@Suite("Default apps")
struct DefaultAppsTests {
    @Test("A known alternative beats the system default, which beats Apple's app")
    func resolutionOrder() {
        let none: (String) -> Bool = { _ in false }
        let noHandler: (DefaultHandler) -> String? = { _ in nil }
        #expect(AppRole.terminal.resolve(installed: none, handler: noHandler) == "com.apple.Terminal")
        #expect(AppRole.terminal.resolve(installed: { $0 == "com.googlecode.iterm2" }, handler: noHandler) == "com.googlecode.iterm2")
        #expect(AppRole.terminal.resolve(installed: { _ in true }, handler: noHandler) == "com.mitchellh.ghostty")
        #expect(AppRole.browser.resolve(installed: none, handler: { $0 == .url("https://example.com") ? "app.zen-browser.zen" : nil }) == "app.zen-browser.zen")
        #expect(AppRole.browser.resolve(installed: none, handler: noHandler) == "com.apple.Safari")
        #expect(AppRole.notes.resolve(installed: { $0 == "md.obsidian" }, handler: noHandler) == "md.obsidian")
        #expect(AppRole.passwords.resolve(installed: { $0 == "com.bitwarden.desktop" }, handler: noHandler) == "com.bitwarden.desktop")
        #expect(AppRole.files.resolve(installed: { _ in true }, handler: { _ in "x" }) == "com.apple.finder")
    }

    /// Card agent-bo-95422840, Sven 2026-10-05: configs open "with the main editor of the user so for me i think it is vs code".
    @Test("The editor is the Mac's default for plain text, then source code, when it is an editor; Xcode and TextEdit do not count")
    func editorFromDefaults() {
        let vscode = "com.microsoft.VSCode", xcode = "com.apple.dt.Xcode", textEdit = "com.apple.TextEdit"
        // Sven's Mac on 2026-10-05: plain text on VS Code, source code on Xcode.
        let sven: (DefaultHandler) -> String? = { $0 == .contentType("public.plain-text") ? vscode : xcode }
        #expect(AppRole.editor.resolve(installed: { _ in true }, handler: sven) == vscode)
        // Plain text on TextEdit and source code on Zed: Zed.
        let zed: (DefaultHandler) -> String? = { $0 == .contentType("public.plain-text") ? textEdit : "dev.zed.Zed" }
        #expect(AppRole.editor.resolve(installed: { _ in true }, handler: zed) == "dev.zed.Zed")
        // Neither default is an editor: the first known editor installed, VS Code before Cursor.
        let stock: (DefaultHandler) -> String? = { $0 == .contentType("public.plain-text") ? textEdit : xcode }
        #expect(AppRole.editor.resolve(installed: { $0 == "com.todesktop.230313mzl4w4u92" }, handler: stock) == "com.todesktop.230313mzl4w4u92")
        #expect(AppRole.editor.resolve(installed: { _ in true }, handler: stock) == vscode)
        // Nothing known: TextEdit.
        #expect(AppRole.editor.resolve(installed: { _ in false }, handler: stock) == textEdit)
        #expect(AppRole.editor.defaultHandlers == [.contentType("public.plain-text"), .contentType("public.source-code")])
    }

    @Test("The role is named Editor")
    func editorLabel() { #expect(AppRole.editor.label == "Editor") }

    @Test("My binds opens no editor by name: Hyper+N is the Editor role")
    func presetsUseTheRole() {
        let vscode = AppLink.open(bundle: "com.microsoft.VSCode").id
        #expect(MyBinds.extras[vscode] == nil)
        #expect(!MyBinds.extras.values.contains(Key("n")))
    }
}
