import Foundation
import PilotCore

extension SettingsSchema {
    /// Workspaces › Tiling's keys. The gaps and the glide live in the Pilot block, so each writes through its store as the
    /// page's controls do and answers once the tiler took it; a refused change is taken back and answers bad-value. The
    /// mouse's drag modifier and the swipe are the engine's PilotSettings, which re-arm their taps at once. Of the scrolling
    /// layout's settings only the centre mode (T9) has a key, its row on Workspaces (2026-10-20), while Tiling's block stays
    /// hidden (Q43; page map, Sven 2026-10-17); the block still keeps the other four.
    func registerTiling(block: PilotBlockStore, settings: PilotSettings) {
        register([
            .bool("tiling.gaps.on", "Gaps on", page: "tiling", standard: true,
                  read: { block.block.gapsOn }, write: { on throws(ControlError) in try await block.written { $0.gapsOn = on } }),
            .int("tiling.gaps.inner", "Inner gap, in points", page: "tiling", range: 0...100, standard: 0,
                 read: { block.block.gaps.inner }, write: { n throws(ControlError) in try await block.written { $0.gaps.inner = n } }),
            .int("tiling.gaps.outer", "Outer gap, in points", page: "tiling", range: 0...100, standard: 0,
                 read: { block.block.gaps.outer }, write: { n throws(ControlError) in try await block.written { $0.gaps.outer = n } }),
            .bool("tiling.glide", "Tiled windows glide to a new place", page: "tiling", standard: true,
                  read: { block.block.glide }, write: { on throws(ControlError) in try await block.written { $0.glide = on } }),
            .choice("tiling.scrolling.centre", "Centre the focused column on a scrolling strip", page: "workspaces",
                    PilotBlock.CentreMode.allCases, standard: .never, read: { block.block.scrolling.centre },
                    write: { mode throws(ControlError) in try await block.written { $0.scrolling.centre = mode } }),
            .choice("windows.dragModifier", "Hold to move or resize with the mouse", page: "tiling", DragModifier.allCases,
                    standard: .default, read: { settings.dragModifier }, write: { settings.dragModifier = $0 }),
            .bool("windows.swipeWorkspaces", "A three-finger swipe changes workspace", page: "workspaces", standard: false,
                  read: { settings.swipeWorkspaces }, write: { settings.swipeWorkspaces = $0 }),
        ])
    }
}

extension PilotBlockStore {
    /// One change as the page makes it, returning once the tiler took it; a refused one is taken back and throws.
    func written(_ change: @escaping @MainActor (inout PilotBlock) -> Void) async throws(ControlError) {
        let written = await withCheckedContinuation { done in edit(change) { done.resume(returning: $0) } }
        if !written { throw ControlError(.badValue, "not applied: \(lastError ?? "the tiler refused it")") }
    }
}
