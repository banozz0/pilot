import AppKit
import Observation
import PilotCore
import SwiftUI

/// A left-click drag on the Workspaces page (Sven, 2026-11-15): an app's tile from a workspace's card or the picked
/// workspace's preview, or a row of Always lands here, carried in the page's own space to another workspace's card or
/// onto another app's tile. Where it lands is the page's to say (`hit`) and to make (`land`, a WorkspaceAppDrop);
/// Escape lets go of it with nothing changed. The drag is the page's state, not the system's, so a render stages one.
@Observable @MainActor
final class WorkspaceDrag {
    static let space = "workspaces.drag"

    struct Item: Equatable {
        /// An app a workspace's preset holds, or an app rule (the app always lands on `from`).
        enum Kind { case app, rule }
        let kind: Kind
        let bundle: String
        let name: String
        let from: String
    }

    enum Target: Equatable {
        /// The workspace's card, away from its tiles: the app moves there.
        case workspace(String)
        /// Another app's tile: the two trade places.
        case tile(workspace: String, bundle: String, name: String)
    }

    /// A preview tile: its workspace's app. A workspace picked before keeps its tiles here; `hit` reads the picked one's.
    struct TileKey: Hashable { let workspace: String; let bundle: String }

    private(set) var item: Item?
    private(set) var target: Target?
    /// The pointer, in the page's space; only the chip's layer reads it, so a move redraws the chip alone.
    private(set) var at: CGPoint = .zero

    /// Each card's frame and its screen's, and the preview's tiles, in the page's space: what `hit` reads.
    @ObservationIgnored var cards: [String: CGRect] = [:]
    @ObservationIgnored var screens: [String: CGRect] = [:]
    @ObservationIgnored var previewTiles: [TileKey: CGRect] = [:]

    /// Where `item` would land at a point; the page sets it.
    @ObservationIgnored var hit: (Item, CGPoint) -> Target? = { _, _ in nil }
    /// The drop; the page sets it.
    @ObservationIgnored var land: (Item, Target) -> Void = { _, _ in }

    /// The rest of this gesture is ignored: Escape was pressed, or it started where nothing picks up.
    @ObservationIgnored private var ignored = false
    @ObservationIgnored private var escape: Any?

    /// The gesture moved: the first move picks `item` up, each one after finds where it would land.
    func moved(_ item: @autoclosure () -> Item?, to point: CGPoint) {
        guard !ignored else { return }
        if self.item == nil {
            guard let picked = item() else { ignored = true; return }
            self.item = picked
            watchEscape()
        }
        at = point
        let landing = self.item.flatMap { hit($0, point) }
        if landing != target { withAnimation(Kit.change) { target = landing } }
    }

    /// The gesture ended: dropped where it would land, else nothing.
    func ended() {
        defer { reset() }
        guard !ignored, let item, let target else { return }
        land(item, target)
    }

    /// Escape: let go, nothing changed.
    func cancel() {
        guard item != nil else { return }
        reset()
        ignored = true
    }

    private func reset() {
        withAnimation(Kit.change) { item = nil; target = nil }
        ignored = false
        if let escape { NSEvent.removeMonitor(escape) }
        escape = nil
    }

    private func watchEscape() {
        escape = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard Int64(event.keyCode) == KeyCode.escape, let self, self.item != nil else { return event }
            self.cancel()
            return nil
        }
    }

    /// The app picked up from `workspace` (a rule's row when `kind` is .rule): it fades in place while the chip carries it.
    func lifts(_ bundle: String, from workspace: String, _ kind: Item.Kind = .app) -> Bool {
        item?.kind == kind && item?.bundle == bundle && item?.from == workspace
    }

    /// A drop now would trade places with `bundle` on `workspace`: its tile lights.
    func lights(_ workspace: String, _ bundle: String) -> Bool {
        if case .tile(workspace, bundle, _)? = target { true } else { false }
    }

    #if DEBUG
    /// A render's drag: `item` held at `point`, over `target`.
    func stage(_ item: Item, at point: CGPoint, over target: Target?) {
        self.item = item
        at = point
        self.target = target
    }
    #endif

    /// The chip's second line: what letting go does.
    func words(title: (String) -> String) -> String? {
        switch target {
        case .workspace(let workspace)?: "Move to \(title(workspace))"
        case .tile(let workspace, _, let name)? where workspace == item?.from: "Swap places with \(name)"
        case .tile(let workspace, _, let name)?: "Swap with \(name) on \(title(workspace))"
        case nil: nil
        }
    }
}

/// The dragged app under the pointer, its icon and name and what letting go does; nothing while no drag is under way.
struct WorkspaceDragLayer: View {
    @Environment(\.ink) private var ink
    let drag: WorkspaceDrag
    let title: (String) -> String

    var body: some View {
        if let item = drag.item {
            let words = drag.words(title: title)
            HStack(spacing: 8) {
                AppGlyph(bundles: [item.bundle], symbol: "app.dashed", size: 22)
                VStack(alignment: .leading, spacing: 1) {
                    Text(item.name).font(ink.ui(12.5, .semibold)).foregroundStyle(ink.text).lineLimit(1)
                    Text(words ?? "Drop on a workspace").font(ink.ui(11)).foregroundStyle(words == nil ? ink.muted : ink.accent).lineLimit(1)
                }
            }
            .padding(.horizontal, 10).padding(.vertical, 7)
            .background(ink.surface, in: .rect(cornerRadius: ink.radius(9)))
            .overlay { RoundedRectangle(cornerRadius: ink.radius(9), style: .continuous).strokeBorder(words == nil ? ink.line2 : ink.accent, lineWidth: 1.5) }
            .shadow(color: .black.opacity(0.25), radius: 12, y: 6)
            .fixedSize()
            .offset(x: drag.at.x + 14, y: drag.at.y + 12)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
        }
    }
}

/// A card or a tile a drop lands on: lit in the accent.
struct DropRing: View {
    @Environment(\.ink) private var ink
    let radius: CGFloat

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
        shape.fill(ink.accent.opacity(0.14)).overlay { shape.strokeBorder(ink.accent, lineWidth: 2) }.allowsHitTesting(false)
    }
}

extension View {
    /// A left-click drag that picks `item` up once it has moved 4 points; nil (no tile under the press) drags nothing.
    func dragsInWorkspaces(_ drag: WorkspaceDrag?, _ item: @escaping (CGPoint) -> WorkspaceDrag.Item?) -> some View {
        simultaneousGesture(DragGesture(minimumDistance: 4, coordinateSpace: .named(WorkspaceDrag.space))
            .onChanged { value in drag?.moved(item(value.startLocation), to: value.location) }
            .onEnded { _ in drag?.ended() },
            including: drag == nil ? .subviews : .all)
    }
}
