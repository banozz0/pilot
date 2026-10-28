import AppKit
import SwiftUI
import Testing
@testable import Pilot

/// The workspace name field ends typing as Finder's rename does (Sven, Build 62: a click elsewhere left the cursor in it):
/// Return and a click outside it save, Esc puts the name back. Drawn in a borderless window off every screen, never key,
/// so nothing of Sven's loses focus; keys go to the window as they arrive, the click through the app, where Pilot's
/// click watch sees it.
@MainActor
@Suite("Workspace name field")
struct WorkspaceNameFieldTests {
    final class Saved { var name = "Workspace 1" }

    /// The field typed "Chat" into, in a window with room around it (LookPageTests.hosted); `end` ends the typing, then the saved name and
    /// whether the cursor is still in the field are read back.
    func typed(_ end: (NSWindow, NSView) throws -> Void) throws -> (name: String, editing: Bool) {
        let saved = Saved()
        let field = NameField(name: Binding(get: { saved.name }, set: { saved.name = $0 }), workspace: "1")
        var editing = true
        try LookPageTests().hosted(field.padding(20).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading), height: 300) { host in
            let window = try #require(host.window)
            #expect(window.makeFirstResponder(try #require(Self.textField(in: host))))
            PanelTestSupport.pump()
            let editor = try #require(window.firstResponder as? NSTextView)
            editor.insertText("Chat", replacementRange: NSRange(location: NSNotFound, length: 0))
            PanelTestSupport.pump()
            #expect(saved.name == "Workspace 1", "typing alone saves nothing")
            try end(window, host)
            PanelTestSupport.pump()
            editing = window.firstResponder is NSTextView
        }
        return (saved.name, editing)
    }

    static func textField(in view: NSView) -> NSTextField? {
        if let field = view as? NSTextField, field.isEditable { return field }
        return view.subviews.lazy.compactMap(textField).first
    }

    static func key(_ code: UInt16, _ characters: String, in window: NSWindow) throws {
        let event = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                                  windowNumber: window.windowNumber, context: nil, characters: characters,
                                                  charactersIgnoringModifiers: characters, isARepeat: false, keyCode: code))
        window.sendEvent(event)
    }

    @Test("Return saves the name and ends the typing")
    func returnSaves() throws {
        let after = try typed { window, _ in try Self.key(36, "\r", in: window) }
        #expect(after.name == "Chat")
        #expect(!after.editing)
    }

    @Test("Esc puts the name back and ends the typing")
    func escReverts() throws {
        let after = try typed { window, _ in try Self.key(53, "\u{1b}", in: window) }
        #expect(after.name == "Workspace 1")
        #expect(!after.editing)
    }

    @Test("A click elsewhere in the window saves the name and ends the typing; a click in the field keeps it")
    func clickOutsideSaves() throws {
        func click(_ point: CGPoint, in window: NSWindow) throws {
            for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
                let event = try #require(NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                                            windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
                NSApp.sendEvent(event)
                PanelTestSupport.pump(0.05)
            }
        }
        let inside = try typed { window, host in
            let field = try #require(Self.textField(in: host))
            try click(field.convert(CGPoint(x: field.bounds.midX, y: field.bounds.midY), to: nil), in: window)
        }
        #expect(inside.name == "Workspace 1")
        #expect(inside.editing)
        let outside = try typed { window, _ in try click(CGPoint(x: 800, y: 40), in: window) }
        #expect(outside.name == "Chat")
        #expect(!outside.editing)
    }
}
