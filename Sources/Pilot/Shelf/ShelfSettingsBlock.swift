import SwiftUI

/// Workspaces › Tiling's Window shelf block (ADR 0015, ADR 0012's amendments): Window pictures Off, Stills (the default,
/// Q690) or Live. Live warns first and turns on only from the warning's own button (Q662); Stills or Live without Screen
/// Recording says the shelf shows icons, and its Allow asks for it.
struct ShelfSettingsBlock: View {
    @Environment(\.ink) private var ink
    var pictures: ShelfPictures = .shared
    /// Live picked, waiting on the warning's Turn on.
    @State private var askingLive = false

    static let options = ShelfPictureMode.allCases.map { (value: $0, title: $0.title) }

    var body: some View {
        KitBlock(title: "Window shelf", symbol: "sidebar.squares.left",
                 note: "On a Stage workspace, your other windows wait at the left edge; a click brings one to the centre.") {
            VStack(alignment: .leading, spacing: 0) {
                BlockRow(first: true) {
                    HStack(spacing: 10) {
                        Text("Window pictures")
                        InfoMark(text: "Stills, the default, takes a picture as a window leaves the centre and while the pointer is on the shelf. Live keeps every shelved window's picture moving, at a cost in memory and CPU. Off shows each window's app icon and title. Pictures need Screen Recording; until it is allowed the shelf shows icons.")
                        Spacer()
                        Segments(selection: Binding(get: { askingLive ? .live : pictures.mode }, set: pick),
                                 options: Self.options, label: "Window pictures")
                    }
                }
                if askingLive {
                    BlockRow {
                        HStack(spacing: 10) {
                            FinePrint(text: ShelfPictures.liveWarning, color: ink.yellow)
                            Spacer()
                            Button("Cancel") { askingLive = false }.buttonStyle(PilotButtonStyle(ghost: true))
                            Button("Turn on Live") { askingLive = false; pictures.set(.live) }.buttonStyle(PilotButtonStyle(primary: true))
                        }
                    }
                }
                if pictures.mode != .off, pictures.needsReopen, !pictures.lacksPermission {
                    BlockRow {
                        HStack(spacing: 10) {
                            FinePrint(text: "Quit and reopen Pilot to finish allowing Screen Recording; until then the shelf shows icons.")
                            Spacer()
                            Button("Quit & Reopen") { PermissionDragPanel.relaunch() }.buttonStyle(.pilot)
                        }
                    }
                }
                if pictures.mode != .off, pictures.lacksPermission {
                    BlockRow {
                        HStack(spacing: 10) {
                            FinePrint(text: "Screen Recording is off for Pilot, so the shelf shows icons.")
                            Spacer()
                            Button("Allow") { pictures.allow() }.buttonStyle(.pilot)
                        }
                    }
                }
            }
        }
    }

    private func pick(_ mode: ShelfPictureMode) {
        if mode == .live, pictures.mode != .live { askingLive = true; return }
        askingLive = false
        pictures.set(mode)
    }
}
