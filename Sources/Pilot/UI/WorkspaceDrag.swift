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

    enum Item: Equatable {
        /// An app a workspace's preset holds.
        case app(bundle: String, name: String, from: String)
        /// An app rule: the app always lands on `from`.
        case rule(bundle: String, name: String, from: String)

        var bundle: String { switch self { case .app(let b, _, _), .rule(let b, _, _): b } }
        var name: String { switch self { case .app(_, let n, _), .rule(_, let n, _): n } }
        var from: String { switch self { case .app(_, _, let w), .rule(_, _, let w): w } }
    }

    enum Target: Equatable {
        /// The workspace's card, away from its tiles: the app moves there.
        case workspace(String)
        /// Another app's tile: the two trade places.
        case tile(workspace: String, bundle: String, name: String)
    }

    private(set) var item: Item?
    /// The pointer, in the page's space.
    private(set) var at: CGPoint = .zero
    private(set) var target: Target?

    /// A preview tile: its workspace's app. A workspace picked before keeps its tiles here; `hit` reads the picked one's.
    struct TileKey: Hashable { let workspace: String; let bundle: String }

    /// Each card's frame and its screen's, and the preview's tiles, in the page's space: what `hit` reads.
    @ObservationIgnored var cards: [String: CGRect] = [:]
    @ObservationIgnored var screens: [String: CGRect] = [:]
    @ObservationIgnored var previewTiles: [TileKey: CGRect] = [:]

    /// Where `item` would land at a point; the page sets it.
    @ObservationIgnored var hit: (Item, CGPoint) -> Target? = { _, _ in nil }
    /// The drop; the page sets it.
    @ObservationIgnored var land: (Item, Target) -> Void = { _, _ in }

    /// Escape pressed: the rest of that gesture is ignored.
    @ObservationIgnored private var cancelled = false
    @ObservationIgnored private var escape: Any?

    /// The gesture moved: the first move picks `item` up, each one after finds where it would land.
    func moved(_ item: @autoclosure () -> Item?, to point: CGPoint) {
        guard !cancelled else { return }
        if self.item == nil {
            guard let picked = item() else { return }
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
        guard !cancelled, let item, let target else { return }
        land(item, target)
    }

    /// Escape: let go, nothing changed.
    func cancel() {
        guard item != nil else { return }
        reset()
        cancelled = true
    }

    private func reset() {
        withAnimation(Kit.change) { item = nil; target = nil }
        cancelled = false
        if let escape { NSEvent.removeMonitor(escape) }
        escape = nil
    }

    private func watchEscape() {
        escape = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard event.keyCode == 53, let self, self.item != nil else { return event }
            self.cancel()
            return nil
        }
    }

    #if DEBUG
    /// A render's drag: `item` held at `point`, over `target`.
    func stage(_ item: Item, at point: CGPoint, over target: Target?) {
        self.item = item
        at = point
        self.target = target
    }
    #endif

    /// The chip under the pointer: the app, and what letting go does.
    func words(title: (String) -> String) -> String? {
        switch target {
        case .workspace(let workspace)?: "Move to \(title(workspace))"
        case .tile(let workspace, _, let name)? where workspace == item?.from: "Swap places with \(name)"
        case .tile(let workspace, _, let name)?: "Swap with \(name) on \(title(workspace))"
        case nil: nil
        }
    }
}

/// The dragged app under the pointer: its icon and name, and what letting go does.
struct WorkspaceDragChip: View {
    @Environment(\.ink) private var ink
    let item: WorkspaceDrag.Item
    let words: String?

    var body: some View {
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
        .allowsHitTesting(false)
        .accessibilityHidden(true)
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
