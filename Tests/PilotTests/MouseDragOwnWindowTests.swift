import AppKit
import Testing
@testable import Pilot

/// A modifier drag did nothing on Pilot's own window (Sven 2026-10-10, build 18): every one of Pilot's windows stopped it.
/// Its normal windows (the app window) now move and resize like any app's; its panels, menu and bars still stop a drag.
@MainActor
@Suite("Mouse drag on Pilot's own window")
struct MouseDragOwnWindowTests {
    @Test("The app window drags; a panel, a borderless window, a raised one and a fixed one do not")
    func draggable() {
        let app = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 300), styleMask: [.titled, .resizable, .closable],
                           backing: .buffered, defer: true)
        #expect(MouseDragTap.isDraggableOwn(app))
        let panel = NSPanel(contentRect: .zero, styleMask: [.titled, .nonactivatingPanel], backing: .buffered, defer: true)
        #expect(!MouseDragTap.isDraggableOwn(panel))
        let borderless = NSWindow(contentRect: .zero, styleMask: [.borderless], backing: .buffered, defer: true)
        #expect(!MouseDragTap.isDraggableOwn(borderless))
        let raised = NSWindow(contentRect: .zero, styleMask: [.titled], backing: .buffered, defer: true)
        raised.level = .floating
        #expect(!MouseDragTap.isDraggableOwn(raised))
        let fixed = NSWindow(contentRect: .zero, styleMask: [.titled], backing: .buffered, defer: true)
        fixed.isMovable = false
        #expect(!MouseDragTap.isDraggableOwn(fixed))
    }
}
