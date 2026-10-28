#if DEBUG
import AppKit
import Foundation
import PilotCore
import SwiftUI
import Testing
@testable import Pilot

/// Menu-morph T2 (risk: typing): Line's Classic root grows into its search on the first key and back when the query
/// empties, and no key is ever lost, reordered or kept waiting by it. The real panel, view and window sizing (MenuSizer:
/// the 431 to 750 resize, the union window while the face morphs, the settle timer), hidden (alpha 0, no mouse), so
/// nothing draws on Sven's screen; keys go through the window as AppKit delivers them.
@MainActor
@Suite("Line morph", .serialized)
struct LineMorphTests {
    /// The real menu panel in Line with its sizer, hidden, its search field holding the keyboard.
    func lineMenu() throws -> (MenuModel, NSPanel, MenuSizer, NSTextView) {
        testApp()
        let entries = try SharedLook.LineMenuRenders.built()
        let model = MenuModel(nav: MenuNavigator(entries: entries))
        model.layout = .line
        let panel = PanelTestSupport.hide(PilotMenu.makePanel(model))
        let sizer = MenuSizer(panel: panel, model: model)
        panel.makeKeyAndOrderFront(nil)
        PanelTestSupport.pump()
        _ = HUD.focusSearch(in: panel)
        let editor = try #require(panel.firstResponder as? NSTextView, "the search field does not hold the keyboard")
        #expect(editor.isFieldEditor)
        return (model, panel, sizer, editor)
    }

    /// One key as AppKit hands it to the window, then `wait` seconds of the run loop: the morph's frames, the sizer's
    /// next turn and its settle timer run meanwhile.
    func key(_ c: String, code: UInt16 = 8, into panel: NSWindow, wait: Double) {
        panel.sendEvent(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: panel.windowNumber,
                                         context: nil, characters: c, charactersIgnoringModifiers: c, isARepeat: false, keyCode: code)!)
        if wait > 0 { PanelTestSupport.pump(wait) }
    }

    /// The search field in the panel's view tree: the one the keyboard types into.
    func field(in view: NSView?) -> NSTextField? {
        guard let view else { return nil }
        if let field = view as? NSTextField, field.isEditable { return field }
        return view.subviews.lazy.compactMap { field(in: $0) }.first
    }

    var reduce: Bool { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }

    /// The run loop until `sizer` has settled, at most a second (PanelTestSupport.pump stops once it is quiet, before the
    /// settle timer). A hidden test panel lets macOS coalesce the process's timers, so the 220 ms tick can come late here.
    func settled(_ sizer: MenuSizer) {
        let end = Date.now + 1
        while sizer.settling, Date.now < end { RunLoop.current.run(until: min(end, Date.now + 0.01)) }
    }

    @Test("Typed at 20 ms a key through the morph, \"notes\" reads \"notes\" in one field while the window grows, holds the union and settles", .pilotFocus)
    func typingThroughTheMorph() throws {
        let (model, panel, sizer, editor) = try lineMenu()
        // The sizer lives as long as the menu does, as PilotMenu holds it, to the test's end.
        defer { withExtendedLifetime(sizer) { panel.orderOut(nil) } }
        let root = model.instrumentSize
        #expect(model.atRoot && root.width == MenuPanelSize.lineRootWidth)
        #expect(panel.frame.size == root, "the window is not the root's face at rest")
        let before = try #require(field(in: panel.contentView))
        var typed = "", union: CGSize?, first: CGSize?
        for c in "notes" {
            // The key's own turn: the letter is in the query before any frame of the morph or the resize has run.
            key(String(c), into: panel, wait: 0)
            typed.append(c)
            #expect(model.nav.query == typed, "after \(typed.count) keys")
            #expect(panel.firstResponder === editor, "the field lost the keyboard mid-morph")
            PanelTestSupport.pump(0.02)
            if union == nil { (union, first) = (panel.frame.size, model.instrumentSize) }
        }
        let search = model.instrumentSize
        #expect(!model.atRoot && search.width == MenuPanelSize.width)
        // While the face morphs the window holds both shapes: the taller of the root and the first key's list, Line's width.
        // The root has no recents since 2026-10-20, so the first key's longer list can be the taller.
        if reduce {
            #expect(union == search)
        } else {
            #expect(union == CGSize(width: search.width, height: max(root.height, first?.height ?? 0)), "\(String(describing: union))")
            #expect(sizer.settling)
        }
        // Once the face settles the window is its shape again: the same field, still holding the keyboard, nothing lost.
        settled(sizer)
        #expect(!sizer.settling)
        #expect(panel.frame.size == model.instrumentSize, "\(panel.frame.size) is not the face's \(model.instrumentSize)")
        #expect(model.nav.query == "notes")
        #expect(panel.firstResponder === editor)
        #expect(field(in: panel.contentView) === before, "the search field was rebuilt by the morph")
    }

    @Test("Deleting back to an empty query morphs back to the root and its size; a key typed during that morph still lands", .pilotFocus)
    func backAndTypeAgain() throws {
        let (model, panel, sizer, editor) = try lineMenu()
        // The sizer lives as long as the menu does, as PilotMenu holds it, to the test's end.
        defer { withExtendedLifetime(sizer) { panel.orderOut(nil) } }
        key("g", into: panel, wait: 0.03); settled(sizer)
        #expect(model.nav.query == "g" && !model.atRoot)
        #expect(panel.frame.size == model.instrumentSize)
        // Delete (key code 51) empties the query: the root again, its window settling back to 431 wide.
        key("\u{7F}", code: 51, into: panel, wait: 0.03); settled(sizer)
        #expect(model.nav.query == "" && model.atRoot)
        #expect(!sizer.settling && panel.frame.size == model.instrumentSize && panel.frame.width == MenuPanelSize.lineRootWidth)
        // Mid-way back, a new key: it lands, and the window ends at the search's size.
        key("x", into: panel, wait: 0)
        key("\u{7F}", code: 51, into: panel, wait: 0.03)
        key("t", into: panel, wait: 0)
        #expect(model.nav.query == "t" && !model.atRoot)
        #expect(panel.firstResponder === editor)
        PanelTestSupport.pump(0.03)
        settled(sizer)
        #expect(model.nav.query == "t")
        #expect(panel.frame.size == model.instrumentSize)
    }

    @Test("The window holds the face's size at rest and the union of both only while the face morphs")
    func windowFrames() {
        let root = CGSize(width: 431, height: 648), search = CGSize(width: 750, height: 582), taller = CGSize(width: 750, height: 620)
        // Not a morph (a key that changes the row count): the new size at once.
        let plain = LineMorph.window(holding: search, to: taller, morph: false, settling: false, reduce: false)
        #expect(plain.now == taller && plain.settle == nil)
        // The first key: the union now, the search's size once the face has settled.
        let grow = LineMorph.window(holding: root, to: search, morph: true, settling: false, reduce: false)
        #expect(grow.now == CGSize(width: 750, height: 648) && grow.settle == search)
        // Another key while it settles: never smaller than the window already is, and the newest size to settle on.
        let mid = LineMorph.window(holding: grow.now, to: taller, morph: false, settling: true, reduce: false)
        #expect(mid.now == CGSize(width: 750, height: 648) && mid.settle == taller)
        // Back to the root: the union again, then Classic's narrow size.
        let back = LineMorph.window(holding: search, to: root, morph: true, settling: false, reduce: false)
        #expect(back.now == CGSize(width: 750, height: 648) && back.settle == root)
        // Reduce Motion: no morph, the new size at once.
        let calm = LineMorph.window(holding: root, to: search, morph: true, settling: false, reduce: true)
        #expect(calm.now == search && calm.settle == nil)
        #expect(LineMorph.plate(back: false, reduce: true) == nil)
        #expect(LineMorph.settle(back: false) > LineMorph.grow && LineMorph.settle(back: true) > LineMorph.back)
    }
}
#endif
