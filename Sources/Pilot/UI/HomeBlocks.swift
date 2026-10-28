import AppKit
import PilotCore
import SwiftUI

// What Home's blocks share across styles: how a workspace's windows sit, the last copy's line, the Pilot block's words
// and the quick actions.

// MARK: - Now

/// How the focused workspace's windows sit, in the words Home's Now block uses.
@MainActor
enum HomeNowBlock {
    /// "Columns, 2 apps": how the workspace's tiled windows sit, and how many there are (windows when an app has two).
    static func summary(_ windows: [AeroWindow]) -> String {
        guard !windows.isEmpty else { return "nothing open" }
        let apps = Set(windows.map(\.bundleId)).count
        let count = apps == windows.count ? (apps, apps == 1 ? "app" : "apps") : (windows.count, "windows")
        return "\(arrangement(windows)), \(count.0) \(count.1)"
    }

    /// How the workspace's tiled windows sit: Columns, Rows, Scrolling, Tiled, or Floating with none tiled.
    static func arrangement(_ windows: [AeroWindow]) -> String {
        switch windows.first(where: { !$0.isFloating })?.layout {
        case "h_tiles": "Columns"
        case "v_tiles": "Rows"
        case "h_scrolling": "Scrolling"
        case nil: "Floating"
        default: "Tiled"
        }
    }
}

extension [AeroWindow] {
    /// The tiled windows, then the floating ones, as a workspace screen draws them.
    var tiledFirst: [AeroWindow] { filter { !$0.isFloating } + filter(\.isFloating) }

    /// The windows as a workspace screen rows them: one a row when the tiler stacks them, else `tileRows`.
    var layoutRows: [[AeroWindow]] { first?.layout == "v_tiles" ? map { [$0] } : tileRows }

    /// Up to three windows a row, so six make two rows of three.
    var tileRows: [[AeroWindow]] {
        let perRow = count <= 3 ? Swift.max(1, count) : Int((Double(count) / 2).rounded(.up))
        return stride(from: 0, to: count, by: perRow).map { Array(self[$0..<Swift.min($0 + perRow, count)]) }
    }
}

extension EngineObservers {
    /// The window macOS has in front, by its app and title.
    func isInFront(_ window: AeroWindow) -> Bool {
        focusedApp?.bundleIdentifier == window.bundleId && focusedWindowTitle == window.title
    }
}

// MARK: - Pilot

/// The Pilot block's words: All clear, what to fix or Hyper is off, and the line under it.
@MainActor
enum PilotTile {
    /// What needs you first, else Hyper off, else All clear.
    static func headline(hyperOn: Bool, problems: Int) -> String {
        if problems == 1 { return "One thing to fix" }
        if problems > 1 { return "\(problems) things to fix" }
        return hyperOn ? "All clear" : "Hyper is off"
    }

    /// The line under it: what the one fix needs, else what Hyper off leaves the layer key doing, else that every key is
    /// yours.
    static func note(hyperOn: Bool, problems: [HomeProblems.Problem], layerKey: String) -> String {
        guard let problem = problems.first else {
            return hyperOn ? "Hyper is on, and every key is yours." : HyperToggle.offWords(layerKey: layerKey)
        }
        guard problems.count == 1 else { return "Fix these and every key is yours again." }
        return switch problem.kind {
        case .tiler: "Tiling needs Pilot's tiler; your binds still work."
        case .accessibility: "Pilot sees no keys until Accessibility is granted."
        case .secureInput: (problem.detail ?? "Hyper waits while a password field has the keyboard") + "."
        case .error: problem.detail ?? "The rest of Pilot still works."
        }
    }
}

// MARK: - Quick actions

/// The quick actions: what each runs (an action, or a page), its words, symbol and colour.
@MainActor
struct QuickAction: Identifiable {
    let id: String
    let title: String
    let colour: TileColour
    var page: AppPlace?
    /// The action's symbol on the keyboard's keys; a page's its own.
    var symbol: String { HomeBinds.symbols[id] ?? "shippingbox" }

    static let all: [QuickAction] = [
        QuickAction(id: "system.lock", title: "Lock screen", colour: .amber),
        QuickAction(id: "captures.area", title: "Capture area", colour: .good),
        QuickAction(id: "captures.ocr", title: "Capture text", colour: .good),
        QuickAction(id: "engine.sheet", title: "Keybindings", colour: .problem),
        QuickAction(id: "install", title: "Install an app", colour: .amber, page: AppPlace(.install)),
    ]
}
