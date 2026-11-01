import AppKit
import PilotCore
import SwiftUI
import WebApps

/// Fonts › Use fonts in (Sven, Q711 and Q712; its own page since 2026-11-01): where each font is used, per app, as macOS has no system-wide font.
/// Pilot's own words and mono, then each installed app's place with the font its config names now, a pick of the
/// installed fonts (the fixed-pitch ones for terminals and editors) and Undo back to the app's earlier font. The configs
/// are read when the block shows and after a pick; nothing polls.
struct FontUseBlock: View {
    @Environment(\.ink) private var ink
    @Bindable var fonts: PilotFonts
    let places: FontPlaces
    /// Whether an app is on this Mac; a render passes its own.
    let installed: @MainActor (FontPlace) -> Bool
    @State private var rows: [FontUse.Row] = []
    @State private var families: (all: [String], mono: [String]) = ([], [])

    init(fonts: PilotFonts = .shared, places: FontPlaces = .standard, installed: @escaping @MainActor (FontPlace) -> Bool = FontUse.installed) {
        self.fonts = fonts
        self.places = places
        self.installed = installed
    }

    var body: some View {
        KitBlock(title: "Use fonts in", symbol: "textformat") {
            BlockRow(first: true) { pilotRow(.ui, "Words", standard: ink.isInstrument ? "Geist" : "Nunito") }
            BlockRow { pilotRow(.mono, "Mono", standard: ink.isInstrument ? "Geist Mono" : "JetBrains Mono") }
            ForEach(rows, id: \.place.id) { row in BlockRow { appRow(row) } }
        }
        .onAppear(perform: refresh)
        .task { families = await Task.detached { (InstalledFonts.families(), InstalledFonts.monoFamilies()) }.value }
    }

    private func refresh() {
        let earlier = places.earlier()
        rows = FontPlace.known.filter(installed).map { FontUse.row($0, places: places, earlier: earlier) }
    }

    private func pilotRow(_ part: PilotFonts.Part, _ place: String, standard: String) -> some View {
        let picked = fonts.family(part)
        return HStack(spacing: 10) {
            label(name: "Pilot · \(place)", bundle: Bundle.main.bundleIdentifier, line: nil, warn: false)
            picker("Pilot \(place.lowercased()) font", current: picked, fallback: "Style's own (\(standard))", offersFallback: true,
                   families: part == .mono ? families.mono : families.all) { family in
                try? fonts.set(part, family)
            }
        }
    }

    private func appRow(_ row: FontUse.Row) -> some View {
        let place = row.place
        let line = row.problem ?? (row.restart ? "\(place.app) is open: restart it after a pick" : nil)
        return HStack(spacing: 10) {
            label(name: place.title, bundle: place.bundles.first, line: line, warn: row.problem != nil)
            if let earlier = row.earlier {
                Button("Undo") { change(place) { places throws(FontProblem) in try places.undo(place) } }
                    .buttonStyle(.pilot).help("Back to \(earlier.value.map(place.family) ?? "\(place.app)'s default")")
            }
            picker("\(place.title) font", current: row.font, fallback: "\(place.app)'s default", offersFallback: false,
                   families: place.mono ? families.mono : families.all) { family in
                if let family { change(place) { places throws(FontProblem) in try places.use(family, in: place) } }
            }
            .disabled(row.problem != nil)
        }
    }

    /// An app's name and icon, and under it its problem or its restart.
    private func label(name: String, bundle: String?, line: String?, warn: Bool) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            AppLabel(name: name, bundle: bundle, size: 18, symbol: "textformat")
                .font(ink.ui(13)).foregroundStyle(ink.text).lineLimit(1)
            if let line { Text(line).font(ink.ui(11.5)).foregroundStyle(warn ? ink.warnText : ink.muted).lineLimit(2) }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// The font field: the family in use or `fallback`, a menu of the families, `fallback` first when it can be picked
    /// (Pilot's style's own).
    private func picker(_ label: String, current: String?, fallback: String, offersFallback: Bool, families: [String],
                        pick: @escaping (String?) -> Void) -> some View {
        // The font in use stays listed even when it is not installed or not fixed-pitch.
        let listed = current.map { families.contains($0) ? families : [$0] + families } ?? families
        return AppPickerField(bundle: nil, name: current ?? fallback, label: label, compact: true, symbol: "textformat") {
            Picker(label, selection: Binding(get: { current }, set: { if $0 != current { pick($0) } })) {
                if offersFallback { Text(fallback).tag(String?.none) }
                ForEach(listed, id: \.self) { Text($0).tag(String?.some($0)) }
            }
            .pickerStyle(.inline).labelsHidden()
        }
        .frame(width: 240)
    }

    private func change(_ place: FontPlace, _ write: (FontPlaces) throws(FontProblem) -> Bool) {
        do { try FontUse.apply(place, places, write) } catch {
            HUD.tip("\(place.title): \(error)")
        }
        refresh()
    }
}

/// What Use fonts in and `pilot fonts` both read about a place, and what follows a write.
@MainActor
enum FontUse {
    struct Row {
        let place: FontPlace
        /// The family the app uses; nil for its default.
        let font: String?
        let problem: String?
        let earlier: FontPlaces.Earlier?
        /// The app is open and reads its config only at launch.
        let restart: Bool
    }

    /// `earlier` is FontPlaces.earlier(), read once for all the rows.
    static func row(_ place: FontPlace, places: FontPlaces, earlier: [String: FontPlaces.Earlier]) -> Row {
        var font: String?, problem: String?
        // A place that cannot take a pick says so before one, not after.
        do { font = try places.family(place); try places.check(place) } catch { problem = error.description }
        return Row(place: place, font: font, problem: problem, earlier: earlier[place.id], restart: !place.live && running(place))
    }

    static func installed(_ place: FontPlace) -> Bool { place.bundles.contains(where: AppsModule.isInstalled) }

    static func running(_ place: FontPlace) -> Bool { place.bundles.contains(where: WorkspaceRunningApps().isRunning) }

    /// One write, as the row's pick and `pilot fonts` make it: a changed Ghostty reloads through its menu, as on a theme pick,
    /// never from a test run, which must not reach the real one.
    static func apply(_ place: FontPlace, _ places: FontPlaces, _ write: (FontPlaces) throws(FontProblem) -> Bool) throws(FontProblem) {
        if try write(places), place.format == .ghostty, !isTestRun { GhosttyBridge.reload() }
    }
}
