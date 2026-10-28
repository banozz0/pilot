import Foundation
import Testing
@testable import PilotCore

/// Card agent-bo-95422949: the notification keys on a fake Accessibility tree; no test reads or presses the real
/// Notification Center.
@Suite("Notification keys")
struct NotificationsTests {
    /// One element of a fake tree. A press is recorded, and Close or Clear All takes the element out of its parent,
    /// as Notification Center does.
    final class Fake: NotificationElement {
        let actionNames: [String]
        var kids: [Fake]
        weak var parent: Fake?
        var pressed: [String] = []
        /// A stuck element stays after its Close, as a tree that never empties.
        let stuck: Bool

        init(_ actions: [String] = [], _ kids: [Fake] = [], stuck: Bool = false) {
            actionNames = actions; self.kids = kids; self.stuck = stuck
            for k in kids { k.parent = self }
        }

        var children: [any NotificationElement] { kids }

        func perform(_ action: String) -> Bool {
            pressed.append(Notifications.name(action))
            if !stuck, ["Close", "Clear All"].contains(Notifications.name(action)) { parent?.kids.removeAll { $0 === self } }
            return true
        }
    }

    static let close = "Name:Close\nTarget:0x0\nSelector:(null)"
    static let clearAll = "Name:Clear All\nTarget:0x0\nSelector:(null)"

    /// The shape Notification Center has on screen: a window, groups, a scroll area, then the notifications.
    func window(_ items: [Fake]) -> Fake {
        Fake([], [Fake(["AXRaise"], [Fake([], [Fake([], [Fake([], items)])])])])
    }

    @Test("Clear latest closes the top notification only")
    func clearLatest() {
        let top = Fake(["AXPress", Self.close]), next = Fake(["AXPress", Self.close])
        let root = window([top, next])
        #expect(Notifications.clearLatest(root) == true)
        #expect(top.pressed == ["Close"])
        #expect(next.pressed.isEmpty)
    }

    @Test("Clear all presses Clear All on a stack and Close on a loose one, and leaves nothing")
    func clearAll() {
        let inStack = Fake(["AXPress", Self.close])
        let stack = Fake([Self.clearAll], [inStack, Fake(["AXPress", Self.close])])
        let loose = Fake(["AXPress", Self.close])
        let root = window([stack, loose])
        #expect(Notifications.clearAll { root } == 2)
        #expect(stack.pressed == ["Clear All"])
        #expect(inStack.pressed.isEmpty)
        #expect(loose.pressed == ["Close"])
        #expect(Notifications.clearAll { root } == 0)
    }

    @Test("A tree that never empties stops at 20 presses")
    func neverEmpties() {
        let stuck = Fake([Self.close], stuck: true)
        let root = window([stuck])
        #expect(Notifications.clearAll { root } == Notifications.maxPresses)
        #expect(stuck.pressed.count == 20)
    }

    @Test("A walk reads at most 300 elements, so a miss with the panel open stays short")
    func budget() {
        let late = Fake([Self.close])
        let root = window(Array(repeating: (), count: 400).map { Fake() } + [late])
        #expect(Notifications.clearLatest(root) == false)
        #expect(late.pressed.isEmpty)
    }

    @Test("Open latest presses the top notification and nothing else")
    func openLatest() {
        let top = Fake(["AXPress", Self.close]), next = Fake(["AXPress", Self.close])
        let root = window([top, next])
        #expect(Notifications.openLatest(root) == true)
        #expect(top.pressed == ["AXPress"])
        #expect(next.pressed.isEmpty)
    }

    @Test("A stack's top notification is the latest when the stack offers only Clear All")
    func stackedLatest() {
        let top = Fake(["AXPress", Self.close])
        let stack = Fake([Self.clearAll], [top, Fake(["AXPress", Self.close])])
        #expect(Notifications.clearLatest(window([stack])) == true)
        #expect(top.pressed == ["Close"])
        #expect(stack.pressed.isEmpty)
    }

    @Test("Nothing on screen: each key reports none and the tip says so")
    func none() {
        let empty = window([])
        #expect(Notifications.clearLatest(empty) == false)
        #expect(Notifications.openLatest(empty) == false)
        #expect(Notifications.clearAll { empty } == 0)
        #expect(Notifications.clearAll { nil } == 0)
        #expect(Notifications.clearLatest(nil) == false)
        #expect(Notifications.noneTip == "No notification on screen")
    }

    @Test("An action's Name part is what counts: the long AX form and the bare word both read as Close")
    func names() {
        #expect(Notifications.name(Self.close) == "Close")
        #expect(Notifications.name("Close") == "Close")
        #expect(Notifications.name(Self.clearAll) == "Clear All")
        #expect(Notifications.name("AXPress") == "AXPress")
    }
}
