// Ported from AeroSpace 74a1bf17 Sources/AppBundleTests/tree/TestWindow.swift (MIT).
@testable import PilotTiler
import AppKit

final class TestWindow: Window, CustomStringConvertible {
    private var _rect: Rect?
    var isMacosFullscreenForTest = false

    @MainActor
    private init(_ id: UInt32, _ parent: NonLeafTreeNodeObject, _ adaptiveWeight: CGFloat, _ rect: Rect?) throws {
        _rect = rect
        try super.init(id: id, TestApp.shared, lastFloatingSize: nil, parent: parent, adaptiveWeight: adaptiveWeight, index: INDEX_BIND_LAST)
    }

    @discardableResult
    @MainActor
    static func new(id: UInt32, parent: NonLeafTreeNodeObject, adaptiveWeight: CGFloat = 1, rect: Rect? = nil) throws -> TestWindow {
        let wi = try TestWindow(id, parent, adaptiveWeight, rect)
        TestApp.shared._windows.append(wi)
        return wi
    }

    nonisolated var description: String { "TestWindow(\(windowId))" }

    @MainActor
    override func nativeFocus() {
        appForTests = TestApp.shared
        TestApp.shared.focusedWindow = self
    }

    override func closeAxWindow() throws {
        try unbindFromParent()
    }

    override func getTitle(_ cm: CancellationMode) async throws -> String { description }

    @MainActor override func getAxRect(_ cm: CancellationMode) async throws -> Rect? { // todo change to not Optional
        axReads += 1
        return _rect
    }

    @MainActor override func getAxSize(_ cm: CancellationMode) async throws -> CGSize? {
        axReads += 1
        return _rect.map { CGSize(width: $0.width, height: $0.height) }
    }

    /// Pilot: a test window is never parked (card agent-bo-95423035 asks isManipulatedWithMouse).
    override var isHiddenInCorner: Bool { false }

    override func isMacosFullscreen(_ cm: CancellationMode) async throws -> Bool { isMacosFullscreenForTest }

    /// Pilot: where layout's last write would have glided from (card agent-bo-95423033).
    var lastGlidingFrom: Rect?

    /// Pilot: layout's frame writes, and the frame they left (card agent-bo-95423034).
    var frameWrites = 0
    /// Pilot: AX reads of its frame (card agent-bo-95423035: the gap hit test makes none).
    var axReads = 0
    var axRect: Rect? { _rect }

    /// Pilot: another writer's frame (Pilot's modifier drag writes it through AX), not counted in frameWrites (story 119).
    func movedByPilot(to rect: Rect) { _rect = rect }

    /// Pilot: a layout lands in the rect it reads back (OwnWindowTests lays one out beside Pilot's own window).
    /// Pilot: the last write's glide length and the x it was to keep within (scrolling layout).
    var lastGlideDuration = GlideSet.duration
    var lastSpan: ClosedRange<CGFloat>?

    override func setAxFrame(_ topLeft: CGPoint?, _ size: CGSize?, glidingFrom: Rect? = nil, duration: Duration = GlideSet.duration,
                             span: ClosedRange<CGFloat>? = nil, screen: GlideScreen? = nil) {
        lastGlidingFrom = glidingFrom
        lastGlideDuration = duration
        lastSpan = span
        frameWrites += 1
        let old = _rect ?? Rect(topLeftX: 0, topLeftY: 0, width: 0, height: 0)
        let topLeft = topLeft ?? old.topLeftCorner
        let size = size ?? old.size
        _rect = Rect(topLeftX: topLeft.x, topLeftY: topLeft.y, width: size.width, height: size.height)
    }
}
