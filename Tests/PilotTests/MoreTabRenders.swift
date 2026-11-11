#if DEBUG
import AppKit
import Foundation
import PilotCore
import SwiftUI
import Testing
@testable import Pilot

/// simplify-pages T6, Sven's pick B (Q60, 2026-11-10): a page's More tab is its blocks with a list of them beside, the one
/// in view marked, as Interior.dev's scroll spy; a More of one block shows the block alone. Drawn on Pilot's own page,
/// whose More holds the most (26 controls), and on Captures, whose More is Recording's one block. The window's rail is
/// the real one, drawn by AppWindowView at the page; the page column beside it is built from Kit's parts with fixed
/// values (no permission or file is read). Instrument and Toybox, a dark and a light theme each, at the window's first
/// size. The design T7 builds from, not the build. Opt-in, in a moved home:
/// `CFFIXED_USER_HOME=<fresh dir> PILOT_RENDER_DIR=<fresh dir> swift test --filter MoreTabRenders`
extension SharedLook {
@MainActor
@Suite("More tab renders")
struct MoreTabRenders {
    nonisolated static let env = ProcessInfo.processInfo.environment

    @Test("The More tab, with its index and as one block, in Instrument and Toybox, light and dark", .enabled(if: env["PILOT_RENDER_DIR"] != nil && env["CFFIXED_USER_HOME"] != nil))
    func render() throws {
        let home = try #require(Self.env["CFFIXED_USER_HOME"])
        try #require(NSHomeDirectory() == home, "the home directory did not move; refusing to start an engine on Sven's data")
        let dir = URL(fileURLWithPath: try #require(Self.env["PILOT_RENDER_DIR"])).appendingPathComponent("more-tab")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        testApp()
        DisplayFaces.directory = LookThemeTests.fonts
        DisplayFaces.register()

        let engine = try SharedLook.HomeRenders.engine()
        let model = AppWindowModel(defaults: try #require(UserDefaults(suiteName: testSuite())))
        let window = AppWindowController.makeWindow(content: NSHostingView(rootView: AppWindowView(model: model).environment(engine)))
        defer { window.close() }
        let frame = try #require(window.contentView?.superview)
        let look = Look.shared
        let saved = (look.themeID, look.style)
        defer { (look.themeID, look.style) = saved }
        let looks: [(name: String, style: PilotStyle, themes: [(String, String)])] = [
            ("instrument", .instrument, [("dark", "tokyo-night"), ("light", "porcelain")]),
            ("toybox", .toybox, [("dark", "toybox-night"), ("light", "toybox")]),
        ]
        for (name, style, themes) in looks {
            for (scheme, theme) in themes {
                look.style = style
                look.themeID = theme
                AppWindowController.applyLook(look, to: window)
                window.setContentSize(AppWindowController.size)
                for more in MorePage.all {
                    // The rail as the frame draws it at the page: 72 + 1 in Instrument, 76 + 2 in Toybox.
                    model.go(AppPlace(more.page))
                    RunLoop.main.run(until: Date().addingTimeInterval(0.7))
                    frame.layoutSubtreeIfNeeded()
                    let chrome = try #require(snapshot(frame, scale: 2))
                    let rail: CGFloat = style == .toybox ? 78 : 73
                    let size = frame.bounds.size
                    let cg = try #require(chrome.cgImage?.cropping(to: CGRect(x: 0, y: 0, width: Int(rail) * 2, height: Int(size.height) * 2)))
                    let railImage = NSImage(cgImage: cg, size: NSSize(width: rail, height: size.height))
                    let view = HStack(spacing: 0) {
                        Image(nsImage: railImage).resizable().frame(width: rail, height: size.height)
                        MoreColumn(more: more, look: look)
                    }
                    .frame(width: size.width, height: size.height)
                    .environment(engine)
                    .pilotWindowStyles()
                    .pilotTheme(look: look)
                    try Self.hosted(view, size: size) { host in
                        let rep = try #require(snapshot(host, scale: 2))
                        try #require(rep.representation(using: .png, properties: [:]))
                            .write(to: dir.appendingPathComponent("\(more.file)-\(name)-\(scheme).png"))
                    }
                }
            }
        }
    }

    /// `view` in a borderless window far off every screen, never key, at `size`.
    static func hosted(_ view: some View, size: CGSize, _ body: (NSView) throws -> Void) throws {
        let host = NSHostingView(rootView: view)
        host.frame.size = size
        let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        window.setFrameOrigin(NSPoint(x: -20_000, y: -20_000))
        window.orderFrontRegardless()
        defer { window.close() }
        PanelTestSupport.pump()
        RunLoop.main.run(until: Date().addingTimeInterval(0.4))
        host.layoutSubtreeIfNeeded()
        try body(host)
    }
}
}

/// One row of More, with fixed values.
private enum MoreRow {
    case heading(String, info: String)
    case toggle(String, on: Bool, info: String)
    case chip(String, info: String, chip: String, live: Bool)
    case button(String, info: String, title: String)
    case titled(String, detail: String, info: String, buttons: [String])
    case segments(String, info: String, options: [String], picked: Int)
    case hold
    case acknowledgements
}

private struct MoreSection: Identifiable {
    let id: String
    let symbol: String
    let rows: [MoreRow]
    var title: String { id }
    /// Its controls: every row but a heading.
    var controls: Int { rows.filter { if case .heading = $0 { false } else { true } }.count }
}

/// A page's More: the page, its title and parts in the bar, its blocks, and the render's file name.
@MainActor
private struct MorePage {
    let file: String
    let page: AppPage
    let parts: [String]
    let sections: [MoreSection]
    /// The bar's title: the page's, Pilot's as simplify-pages T4 names it ("General" before).
    var title: String { page == .general ? "Pilot" : page.title }

    static let all = [pilot, captures]

    /// Pilot's More (simplify-pages notes): Hyper's keys, Quick tap, hints, hold delay, every permission, status, data,
    /// About.
    static let pilot = MorePage(file: "B-index", page: .general, parts: ["Pilot", "More"], sections: [
        MoreSection(id: "Hyper key", symbol: "command", rows:
            [.heading("Hyper keys", info: "Each key that is on is Hyper by itself; only one side of Control, Option or Command can be on.")]
            + LayerKey.allCases.map { .toggle($0.label, on: $0 == .capsLock, info: $0.note) }
            + [.toggle("A quick tap sends Escape", on: true, info: "Tap a layer key by itself and it sends Escape; held with another key, it is Hyper."),
               .toggle("Show an app's bind after you open it", on: true, info: "After a click opens an app that has a bind. At most once an hour per bind."),
               .hold]),
        MoreSection(id: "Permissions", symbol: "lock.shield", rows: [
            .chip("Accessibility", info: GeneralPage.accessibilityInfo, chip: "granted", live: true),
            .button("Full Disk Access", info: "The file index: it lets the menu find files anywhere.", title: "Open Settings"),
            .chip("Microphone", info: "Dictation hears you through it.", chip: "granted", live: true),
            .chip("Screen Recording", info: "Captures, and Menu bar's exact items.", chip: "granted", live: true),
            .chip("Input Monitoring", info: MorePermissionRows.inputMonitoringInfo, chip: "granted", live: true),
            .chip("Automation: System Events", info: "Sleep, restart, shut down and log out go through System Events.", chip: "granted", live: true),
        ]),
        MoreSection(id: "Status", symbol: "waveform.path.ecg", rows: [
            .chip("Keyboard", info: "The part of Pilot that hears the Hyper key and runs your binds.", chip: "running", live: true),
            .chip("Password field lock", info: "A password field pauses Hyper; Pilot never works around it.", chip: "off", live: false),
            .chip("Tiler", info: "The tiler that places your windows and runs the workspaces.", chip: "running", live: true),
        ]),
        MoreSection(id: "Data", symbol: "folder", rows: [
            .titled("Pilot's folder", detail: "Binds, settings, history and snapshots", info: "Opens the folder in Finder.", buttons: ["Show in Finder"]),
            .chip("pilot command", info: "Links the pilot command into ~/.local/bin.", chip: "in ~/.local/bin", live: true),
            .toggle("Developer pages", on: false, info: DeveloperPages.help),
            .titled("Uninstall", detail: "Speech models, caches, your data or Pilot itself", info: "Ticked items go to the Trash.", buttons: ["Uninstall…"]),
            .titled("Terminal", detail: "Ghostty for Hyper+T, downloaded on its first press", info: "Remove ends its shell and deletes it.", buttons: ["Download"]),
        ]),
        MoreSection(id: "About", symbol: "info.circle", rows: [
            .titled("Send feedback", detail: "A GitHub issue with this Mac's facts filled in", info: "Nothing is sent until you submit it.",
                    buttons: Feedback.Kind.allCases.map(\.label)),
            .acknowledgements,
        ]),
    ])

    /// Captures' More (simplify-pages notes): Recording's quality, resolution, frame rate and clicks, one block.
    static let captures = MorePage(file: "B-single", page: .captures, parts: ["Capture", "Recording", "History", "More"], sections: [
        MoreSection(id: "Recording", symbol: "record.circle", rows: [
            .segments("Quality", info: CapturesPage.Info.quality, options: ["Standard", "High", "Best"], picked: 1),
            .segments("Resolution", info: CapturesPage.Info.resolution, options: ["Retina pixels", "1x"], picked: 0),
            .segments("Frame rate", info: CapturesPage.Info.frameRate, options: ["30 fps", "60 fps"], picked: 1),
            .toggle("Show clicks", on: true, info: CapturesPage.Info.showClicks),
        ]),
    ])
}

/// The page column: the bar with More picked, then More.
private struct MoreColumn: View {
    let more: MorePage
    let look: Look

    var body: some View {
        VStack(spacing: 0) {
            MoreBar(title: more.title, parts: more.parts).styled(.window, look: look)
            MoreBody(sections: more.sections).styled(.page(more.page), look: look)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .styled(.window, look: look)
        .background { MoreGround().styled(.window, look: look) }
    }
}

private struct MoreGround: View {
    @Environment(\.style) private var style
    var body: some View {
        if style.kind == .toybox { style.color(\.canvas) } else { Theme.windowFill(style.color(\.canvas)) }
    }
}

/// The page's bar as InstrumentToolbar and ToyPageHeader draw a page with parts: its title, then its parts, More picked.
private struct MoreBar: View {
    @Environment(\.style) private var style
    let title: String
    let parts: [String]

    var body: some View {
        let options = parts.enumerated().map { (value: $0.offset, title: $0.element) }
        let more = Binding.constant(parts.count - 1)
        if style.kind == .toybox {
            HStack(alignment: .center, spacing: 16) {
                PageTitle(text: title).lineLimit(1).fixedSize()
                ToySegments(selection: more, options: options, label: "\(title) parts")
                Spacer(minLength: 0)
            }
            .padding(.horizontal, Toy.gutter).padding(.top, 24).padding(.bottom, 14)
        } else {
            VStack(spacing: 0) {
                InstrumentPageBar(title: title) {
                    HStack(spacing: 10) {
                        InstrumentSegments(options: options, selection: more).fixedSize()
                        Text(RailLayout.partsHint).styleText(\.key).foregroundStyle(style.color(\.text3)).fixedSize()
                    }
                    .padding(.leading, 8)
                    Spacer(minLength: 8)
                }
                InstrumentRule()
            }
        }
    }
}

/// B: the blocks stacked, the index of them beside while there are two or more.
private struct MoreBody: View {
    let sections: [MoreSection]

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            if sections.count > 1 { MoreIndex(sections: sections, picked: sections[0].id) }
            KitPage {
                ForEach(sections) { section in
                    KitBlock(title: section.title, symbol: section.symbol) {
                        ForEach(Array(section.rows.enumerated()), id: \.offset) { i, row in MoreRowView(row: row, first: i == 0) }
                    }
                }
            }
        }
    }
}

private struct MoreRowView: View {
    @Environment(\.ink) private var ink
    let row: MoreRow
    let first: Bool

    var body: some View {
        BlockRow(first: first) {
            switch row {
            case .heading(let title, let info):
                Text(title); InfoMark(text: info); Spacer()
            case .toggle(let title, let on, let info):
                Toggle(title, isOn: .constant(on)).toggleStyle(.pilotSwitchRow(info: info))
            case .chip(let title, let info, let chip, let live):
                Text(title); InfoMark(text: info); Spacer()
                Chip(text: chip, color: live ? ink.green : nil)
            case .button(let title, let info, let button):
                Text(title); InfoMark(text: info); Spacer()
                Button(button) {}.buttonStyle(.pilot)
            case .titled(let title, let detail, let info, let buttons):
                TitledText(title: title, detail: detail).padding(.vertical, 4)
                InfoMark(text: info); Spacer()
                ForEach(buttons, id: \.self) { Button($0) {}.buttonStyle(.pilot) }
            case .segments(let title, let info, let options, let picked):
                Text(title); InfoMark(text: info); Spacer()
                Segments(selection: .constant(picked), options: options.enumerated().map { (value: $0.offset, title: $0.element) }, label: title)
                    .fixedSize()
            case .hold:
                Text("Hold Hyper to see your binds")
                InfoMark(text: "Hold the Hyper key this long to see that layer's binds.")
                Spacer()
                Text("0.4 s").font(ink.mono(11.5)).foregroundStyle(ink.text2)
                Button("Edit what shows") {}.buttonStyle(.pilot)
                Toggle("Show the overlay when I hold Hyper", isOn: .constant(true)).toggleStyle(.pilotSwitch)
            case .acknowledgements:
                HStack(spacing: 8) {
                    Image(systemName: "chevron.right").font(.system(size: 10, weight: .semibold)).foregroundStyle(ink.muted)
                    TitledText(title: "Acknowledgements", detail: "What Pilot bundles or downloads, each under its own licence").padding(.vertical, 4)
                }
                InfoMark(text: "Open the list, then click a row for its licence's full text.")
                Spacer()
            }
        }
    }
}

/// The index: each block's name and how many controls it holds, the one in view marked as the style marks a pick.
private struct MoreIndex: View {
    @Environment(\.style) private var style
    @Environment(\.ink) private var ink
    let sections: [MoreSection]
    let picked: String

    var body: some View {
        let toy = style.kind == .toybox
        VStack(alignment: .leading, spacing: toy ? 4 : 2) {
            Text("On More").styleText(\.caption).foregroundStyle(style.color(\.text3)).padding(.horizontal, 10).padding(.bottom, 6)
            ForEach(sections) { section in
                let on = section.id == picked
                HStack(spacing: 8) {
                    if !toy { Image(systemName: section.symbol).font(style.font(\.icon)).frame(width: 18) }
                    Text(section.title).font(toy ? style.toyNunito(800, 13.5) : nil).styleText(on ? \.strong : \.body)
                    Spacer(minLength: 4)
                    Text("\(section.controls)").font(ink.mono(11)).foregroundStyle(on && toy ? style.color(\.onInverse) : style.color(\.text3))
                }
                .foregroundStyle(on ? (toy ? style.color(\.onInverse) : style.color(\.text)) : style.color(\.text2))
                .padding(.horizontal, 10).frame(height: style.points(toy ? 34 : 30))
                .background {
                    if on {
                        if toy { RoundedRectangle(cornerRadius: 9, style: .continuous).fill(style.color(\.inverse)) }
                        else { Color.clear.instrumentRaised(true, fill: \.panel, radius: style.radii.control) }
                    }
                }
                .accessibilityElement(children: .combine)
                .accessibilityAddTraits(on ? .isSelected : [])
            }
        }
        .frame(width: 184, alignment: .leading)
        .padding(.leading, toy ? Toy.gutter - 6 : style.density.page - 6)
        .padding(.top, toy ? Toy.blockGap + 6 : style.density.padding + 12)
        .accessibilityElement(children: .contain).accessibilityLabel("On More")
    }
}
#endif
