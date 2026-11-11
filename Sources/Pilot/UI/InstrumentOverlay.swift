import PilotCore
import SwiftUI

/// The hold overlay in Instrument (card agent-bo-95423181, ADR 0008): the layer held as key chips, the layer key's in the
/// signal colour, on a 44 pt header over a hairline; under it the page's binds in columns split by hairlines, each
/// module's under its mono capitals, every bind its key as a chip then what it does. The same rows and words as
/// OverlayView; its face, corner, ring and shadow are the panel's (PopSurface).
struct InstrumentOverlay: View {
    @Environment(\.style) private var style
    let title: String
    let rows: [BindsPage.Row]
    /// The binds past what fits (OverlayView cuts them) and the footer's link to Binds › Overlay.
    var more = 0
    var edit: (() -> Void)?
    /// The layer key whose sign leads the header; the engine's, else Caps Lock.
    var layerKeys = Engine.shared?.settings.layerKeys ?? [.capsLock]

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                InstrumentBindKeys(label: title, layerKeys: layerKeys)
                Text(title).styleText(\.title).foregroundStyle(style.color(\.text)).accessibilityAddTraits(.isHeader)
                Spacer(minLength: 16)
                if title == "Hyper" { Text("Add Shift or Ctrl for more").styleText(\.caption).foregroundStyle(style.color(\.text3)) }
            }
            .lineLimit(1).fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, 18).frame(height: 44)
            InstrumentRule()
            if rows.isEmpty {
                Text("No binds on this layer yet.").styleText(\.body).foregroundStyle(style.color(\.text3))
                    .padding(.horizontal, 18).padding(.vertical, 16)
            } else {
                HStack(alignment: .top, spacing: 0) {
                    let columns = Self.columns(rows)
                    ForEach(Array(columns.enumerated()), id: \.offset) { index, column in
                        if index > 0 { InstrumentRule(vertical: true) }
                        // A grid, so each column's words start past its widest key.
                        Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 0) {
                            ForEach(Array(column.enumerated()), id: \.offset) { _, line in
                                switch line {
                                case .group(let name, let first):
                                    InstrumentEyebrow(text: name).padding(.top, first ? 0 : 10).padding(.bottom, 6).gridCellColumns(2)
                                case .bind(let row): bind(row)
                                }
                            }
                        }
                        .fixedSize()
                        .padding(.horizontal, 18).padding(.vertical, 14)
                        .frame(maxHeight: .infinity, alignment: .top)
                    }
                }
                .fixedSize(horizontal: false, vertical: true)
            }
            OverlayFooter(more: more, edit: edit)
        }
        .frame(minWidth: 420, alignment: .leading)
    }

    /// A bind: its key as chips, then what it does.
    private func bind(_ row: BindsPage.Row) -> some View {
        GridRow {
            Group {
                if let key = row.key {
                    InstrumentKeys(caps: InstrumentBindKeys.caps(key, layerKeys: layerKeys).map(\.text), hyper: false)
                } else {
                    Text("—").styleText(\.key).foregroundStyle(style.color(\.text4))
                }
            }
            Text(row.label).styleText(\.body).foregroundStyle(style.color(\.text2))
        }
        .lineLimit(1).frame(height: 26)
        .accessibilityElement(children: .combine)
    }

    /// One line of a column: a module's eyebrow, or a bind.
    enum Line { case group(String, first: Bool), bind(BindsPage.Row) }

    /// The rows in columns of even height, a module's eyebrow over its first bind in each column (never left alone at a
    /// column's foot). Rows not grouped by module (My most used, ranked by presses) go without eyebrows. One column up to 6
    /// binds, two up to 16, three up to 30, four up to 48, five past that (`columnBreaks`; Binds › Overlay, 2026-10-10).
    static func columns(_ rows: [BindsPage.Row]) -> [[Line]] {
        var runs: [String] = []
        for row in rows where runs.last != row.module { runs.append(row.module) }
        let grouped = Set(runs).count == runs.count
        let count = (columnBreaks.firstIndex { rows.count <= $0 } ?? columnBreaks.count) + 1
        // The shortest column height that holds every line in `count` columns.
        var height = (rows.count + (grouped ? runs.count : 0) + count - 1) / count
        while true {
            let laid = lay(rows, grouped: grouped, height: height)
            if laid.count <= count { return laid }
            height += 1
        }
    }

    /// The most binds each column count takes: one column up to 6, two up to 16, three to 30, four to 48, then five.
    static let columnBreaks = [6, 16, 30, 48]
    static var maxColumns: Int { columnBreaks.count + 1 }
    static let maxLines = 18

    /// The rows the overlay draws and how many it leaves out: every one while five columns of 18 lines hold them (about
    /// 75 binds with their eyebrows, 90 ranked), else the most that fit, found by halving, the rest counted in the footer.
    static func fit(_ rows: [BindsPage.Row]) -> (rows: [BindsPage.Row], more: Int) {
        func fits(_ n: Int) -> Bool { (columns(Array(rows.prefix(n))).map(\.count).max() ?? 0) <= maxLines }
        guard !fits(rows.count) else { return (rows, 0) }
        var low = 0, high = min(rows.count, maxColumns * maxLines)
        while low < high {
            let mid = (low + high + 1) / 2
            if fits(mid) { low = mid } else { high = mid - 1 }
        }
        return (Array(rows.prefix(low)), rows.count - low)
    }

    /// `rows` in columns at most `height` lines tall (one bind over it where a column holds only an eyebrow and a bind).
    private static func lay(_ rows: [BindsPage.Row], grouped: Bool, height: Int) -> [[Line]] {
        var columns: [[Line]] = [[]]
        for (index, row) in rows.enumerated() {
            let starts = index == 0 || row.module != rows[index - 1].module
            // A new column once this one is full: an eyebrow and its first bind need two lines.
            if columns[columns.count - 1].count + (grouped && starts ? 2 : 1) > height, !columns[columns.count - 1].isEmpty {
                columns.append([])
            }
            if grouped, starts || columns[columns.count - 1].isEmpty {
                columns[columns.count - 1].append(.group(title(module: row.module), first: columns[columns.count - 1].isEmpty))
            }
            columns[columns.count - 1].append(.bind(row))
        }
        return columns
    }

    /// A module's name as its eyebrow says it: Pilot's own actions as Pilot.
    static func title(module: String) -> String { module == Module.engine.rawValue || module.isEmpty ? "Pilot" : module }
}
