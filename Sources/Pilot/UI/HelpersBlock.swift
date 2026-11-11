import AppKit
import PilotCore
import SwiftUI

/// Install › More › Command-line tools (General's block until the page map, Sven 2026-10-17; Install's tab until
/// simplify-pages T16): the command-line tools other features run (Sven 2026-10-12), as cards in Catalogue's style: what
/// each unlocks, how it installs in its ⓘ, then installed, or Install through Install's confirm step; a formula waits for
/// Homebrew, which installs first. A block on Install's More.
struct HelpersBlock: View {
    @Environment(\.ink) private var ink
    /// The helpers installed, read when the block shows and when Pilot comes back to the front, as it does after an
    /// install's terminal window; nil until the first read. A render passes its own.
    @State private var installed: Set<String>?
    private let reads: Bool

    init(installed: Set<String>? = nil) {
        _installed = State(initialValue: installed)
        reads = installed == nil
    }

    static let note = "The command-line tools other Pilot features run. Each installs in a terminal window after you confirm the command."

    var body: some View {
        KitBlock(title: "Command-line tools", symbol: "shippingbox", note: Self.note) {
            Text(count).font(ink.mono(11.5))
        } content: {
            CardGrid(minimum: ink.style.kind == .toybox ? 330 : 280, spacing: 8, stretch: true) {
                ForEach(Helper.all) { card($0) }
            }
            .padding(.vertical, 10)
        }
        .task { if reads { installed = Helper.installed() } }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            if reads { installed = Helper.installed() }
        }
    }

    /// "5 · 2 installed", as Catalogue counts a category.
    private var count: String {
        let have = Helper.all.filter { installed?.contains($0.id) == true }.count
        return have == 0 ? "\(Helper.all.count)" : "\(Helper.all.count) · \(have) installed"
    }

    /// A helper as a card: its glyph, name and what it unlocks, how it installs in the ⓘ, and installed or Install.
    private func card(_ helper: Helper) -> some View {
        HStack(alignment: .center, spacing: 11) {
            IconTile(icon: .formula, size: 32)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(helper.name).font(ink.ui(13, .semibold)).foregroundStyle(ink.text).lineLimit(1)
                    InfoMark(text: "How it installs: \(helper.how).")
                }
                Text(helper.unlocks).font(ink.ui(11.5)).foregroundStyle(ink.muted).fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 6)
            switch installed.map({ helper.step(installed: $0) }) {
            case .installed?: Chip(text: "installed", color: ink.green)
            case .needsHomebrew?: Chip(text: "needs Homebrew")
            case .formula?, .installer?:
                Button("Install") { InstallModule.install(helper, installed: installed ?? []) }.buttonStyle(.pilot).help(helper.how)
            case nil: Chip(text: "…")
            }
        }
        .padding(.horizontal, 11).padding(.vertical, 9)
        .innerCard()
    }
}
