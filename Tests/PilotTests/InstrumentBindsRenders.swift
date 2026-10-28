#if DEBUG
import AppKit
import Foundation
import PilotCore
import SwiftUI
import Testing
@testable import Pilot

/// Binds in Instrument (card agent-bo-95423181, mockup A binds-dark.png and binds-light.png), opt-in like the other
/// renders: the page as the window hosts it beside the sidebar, at 1207, 767 and 551 pt (the 1440, 1000 and 760 windows
/// less the sidebar), dark and light: the board with B picked, a free key picked, the Windows module picked, the Plain tab,
/// the list a search opens and a search that finds nothing, the 1440 window's states also whole below the fold. Seeded as
/// Toybox's renders are, in a moved home.
/// `CFFIXED_USER_HOME=<fresh dir> PILOT_RENDER_DIR=<fresh dir> swift test --filter InstrumentBindsRenders`
extension SharedLook {
@MainActor
@Suite("Instrument Binds renders")
struct InstrumentBindsRenders {
    nonisolated static let env = ProcessInfo.processInfo.environment

    /// Every act does nothing: a render only draws.
    static let acts = BindsKeyboardPage.Acts(pick: { _ in }, show: { _, _ in }, edit: { _ in }, clear: { _ in }, reset: { _ in },
                                             switchTo: { _ in }, resetAll: {}, showList: {}, go: { _ in })

    /// The page hosted as the window hosts it: the page surface, `width` by `height`, on the shared Look.
    func hosted(_ page: some View, _ engine: Engine, width: CGFloat, height: CGFloat) -> some View {
        page.styled(.page(.binds)).environment(engine).frame(width: width, height: height).pilotTheme(look: .shared).background(Theme.background)
    }

    /// `view` in a borderless window never shown, its page's scroll view scrolled `share` of the way down (1 the foot), drawn
    /// at 2x once SwiftUI has seen the scroll.
    static func scrolled(_ view: some View, share: Double) throws -> NSBitmapImageRep {
        testApp()
        let host = NSHostingView(rootView: view)
        host.frame.size = host.fittingSize
        let w = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        w.isReleasedWhenClosed = false
        w.contentView = host
        defer { w.close() }
        RunLoop.main.run(until: Date().addingTimeInterval(0.9))
        func scrollViews(_ v: NSView) -> [NSScrollView] { (v as? NSScrollView).map { [$0] } ?? v.subviews.flatMap(scrollViews) }
        let scroll = try #require(scrollViews(host).max { $0.documentView?.frame.height ?? 0 < $1.documentView?.frame.height ?? 0 })
        let room = (scroll.documentView?.frame.height ?? 0) - scroll.contentView.bounds.height
        scroll.contentView.scroll(to: NSPoint(x: 0, y: (scroll.documentView?.isFlipped ?? true ? room * share : room * (1 - share))))
        scroll.reflectScrolledClipView(scroll.contentView)
        RunLoop.main.run(until: Date().addingTimeInterval(0.6))
        host.layoutSubtreeIfNeeded()
        return try #require(snapshot(host, scale: 2))
    }

    @Test("Binds renders as mockup A in Instrument dark and light at 1207, 767 and 551, in its states", .enabled(if: env["PILOT_RENDER_DIR"] != nil && env["CFFIXED_USER_HOME"] != nil))
    func render() throws {
        let engine = try ToyboxBindsRenders().engine()
        let dir = URL(fileURLWithPath: try #require(Self.env["PILOT_RENDER_DIR"])).appendingPathComponent("binds-instrument")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        Look.shared.themeID = "nightwatch"
        defer { Look.shared.themeID = PilotTheme.defaultID; Look.shared.style = .instrument }
        let only = Self.env["PILOT_RENDER_ONLY"]
        func write(_ name: String, _ view: some View, trimmed: Bool) throws {
            guard only.map(name.contains) ?? true else { return }
            let rep = try rendered(view, wait: 0.9)
            let url = dir.appendingPathComponent("\(name).png")
            if trimmed { try RestyledRenders.writeTrimmed(rep, from: 0, to: url) }
            else { try #require(rep.representation(using: .png, properties: [:])).write(to: url) }
        }
        let boards = KeyboardCaptions.Boards(full: .init(.ansi), compact: .init(.ansi, compact: true))
        func page(_ layer: BindsKeyboard.Layer, key: String, module: Int? = nil) -> some View {
            InstrumentBindsPage(binds: HomeBinds(engine: engine, layer: layer), key: KeyNames.code(for: key), layer: .constant(layer), boards: boards,
                                refusal: nil, acts: Self.acts, module: module)
        }
        let states: [(String, AnyView)] = [
            ("1-hyper", AnyView(page(.hyper, key: "B"))), ("2-free", AnyView(page(.hyper, key: "Q"))),
            ("3-windows", AnyView(page(.hyper, key: "H", module: 1))), ("4-plain", AnyView(BindsKeyboardPage(search: "", startOnPlain: true) { _ in })),
            ("5-list", AnyView(BindsKeyboardPage(search: "Open") { _ in })), ("6-no-match", AnyView(BindsKeyboardPage(search: "zzqx") { _ in })),
        ]
        Look.shared.style = .instrument
        for dark in [true, false] {
            for width in [CGFloat(1207), 767, 551] {
                for (name, view) in states {
                    let stacked = width < InstrumentBindsPage.beside && !name.hasPrefix("5") && !name.hasPrefix("6")
                    try write("instrument-\(dark ? "dark" : "light")-\(Int(width))-\(name)", hosted(view, engine, width: width, height: stacked ? 4400 : 900),
                              trimmed: stacked)
                    // The 1440 window's page whole, below its 900 pt fold, as it scrolls; and its window scrolled halfway and to
                    // the foot, the inspector held in sight beside the table.
                    if !stacked, width >= InstrumentBindsPage.beside, !name.hasPrefix("5"), !name.hasPrefix("6") {
                        try write("instrument-\(dark ? "dark" : "light")-\(Int(width))-\(name)-page", hosted(view, engine, width: width, height: 4400),
                                  trimmed: true)
                        for (part, share) in [("half", 0.5), ("foot", 1.0)] where name.hasPrefix("1") {
                            let file = "instrument-\(dark ? "dark" : "light")-\(Int(width))-\(name)-scrolled-\(part)"
                            guard only.map(file.contains) ?? true else { continue }
                            let rep = try Self.scrolled(hosted(view, engine, width: width, height: 900), share: share)
                            try #require(rep.representation(using: .png, properties: [:])).write(to: dir.appendingPathComponent("\(file).png"))
                        }
                    }
                }
            }
        }
    }

    @Test("Bound keys wear their group's colour with the groups' legend under the board, in each style, on Void, a light theme and a coloured one (Q252)", .enabled(if: env["PILOT_RENDER_DIR"] != nil && env["CFFIXED_USER_HOME"] != nil))
    func groups() throws {
        let engine = try ToyboxBindsRenders().engine()
        let dir = URL(fileURLWithPath: try #require(Self.env["PILOT_RENDER_DIR"])).appendingPathComponent("binds-groups")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { Look.shared.themeID = PilotTheme.defaultID; Look.shared.style = .instrument }
        for (style, theme) in [(PilotStyle.instrument, "void"), (.instrument, "workshop"), (.instrument, "lagoon"), (.toybox, "toybox-night"), (.toybox, "void")] {
            Look.shared.style = style
            Look.shared.themeID = theme
            let rep = try rendered(hosted(BindsKeyboardPage(search: "") { _ in }, engine, width: 1207, height: 900), wait: 0.9)
            try #require(rep.representation(using: .png, properties: [:])).write(to: dir.appendingPathComponent("\(style.rawValue)-\(theme).png"))
        }
    }
}
}
#endif
