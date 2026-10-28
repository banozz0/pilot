import CoreAudio
import CoreMediaIO
import Foundation
import os

/// One property listened to: an object's selector in a scope (CoreAudio's or CoreMediaIO's, both 32-bit ids).
struct PropertyKey: Hashable, Sendable {
    let object: UInt32
    let selector: UInt32
    let scope: UInt32
}

/// CoreAudio or CoreMediaIO property listeners that really come off, never pile up, and never flood the main thread
/// (Build 55: 58 minutes at 110% CPU on main). Three rules:
/// - the C listener API, not the block one: `AudioObjectRemovePropertyListenerBlock` called from Swift removes nothing
///   (the imported block type is a Swift closure, bridged to a new block on every call), so every re-arm added a set;
/// - a change adds only the listeners now wanted and removes only those gone, so a re-arm with nothing new touches nothing;
/// - callbacks, on the framework's own thread, only mark a change; one main-queue hop at a time re-arms and reads, so a
///   burst of any size costs one re-arm and one read, and a listener added while re-arming can never re-enter it.
@MainActor
final class PropertyListeners {
    /// What adds and removes one listener, given the pointer its callback hands back.
    struct System: Sendable {
        let add: @Sendable (PropertyKey, UnsafeMutableRawPointer) -> Bool
        let remove: @Sendable (PropertyKey, UnsafeMutableRawPointer) -> Void
    }

    private let system: System
    private let wanted: @MainActor () -> Set<PropertyKey>
    private let signal = Signal()
    private(set) var listening: Set<PropertyKey> = []
    /// For the tests: how many re-arms ran, and whether one began inside another.
    private(set) var arms = 0
    private(set) var reentered = false
    private var arming = false

    /// `wanted` is read on each arm (the processes or cameras as they now are); `changed` runs after it, on main.
    init(_ system: System, wanted: @escaping @MainActor () -> Set<PropertyKey>, changed: @escaping @MainActor () -> Void) {
        self.system = system
        self.wanted = wanted
        signal.fired = { [weak self] in
            guard let self else { return }
            arm()
            changed()
        }
    }

    /// Listens to what is wanted now: adds the new, removes the gone; false when nothing could be listened to.
    @discardableResult func arm() -> Bool {
        guard !arming else { reentered = true; return !listening.isEmpty }
        arming = true
        defer { arming = false }
        arms += 1
        let now = wanted(), context = signal.context
        for key in listening.subtracting(now) { system.remove(key, context) }
        listening.formIntersection(now)
        for key in now.subtracting(listening) where system.add(key, context) { listening.insert(key) }
        return !listening.isEmpty
    }

    /// Every listener off. A callback already on its way finds the signal still alive, then nothing to call.
    func disarm() {
        let context = signal.context
        listening.forEach { system.remove($0, context) }
        listening = []
        signal.fired = nil
    }

    /// What a callback calls, on any thread: marks the change, and hops to main unless a hop is already pending.
    nonisolated static func fire(_ context: UnsafeMutableRawPointer) { Unmanaged<Signal>.fromOpaque(context).takeUnretainedValue().fire() }

    /// The pending mark, shared with the framework's thread. Retained for the process's life once handed out: a pointer
    /// a late callback may still hold must never dangle, and one is made per watch start.
    final class Signal: @unchecked Sendable {
        private let pending = OSAllocatedUnfairLock(initialState: false)
        @MainActor var fired: (@MainActor () -> Void)?
        private(set) lazy var context = Unmanaged.passRetained(self).toOpaque()

        func fire() {
            let first = pending.withLock { was in
                let first = !was
                was = true
                return first
            }
            guard first else { return }
            DispatchQueue.main.async { [self] in
                MainActor.assumeIsolated {
                    pending.withLock { $0 = false }
                    fired?()
                }
            }
        }
    }
}

extension PropertyListeners.System {
    /// CoreAudio's C listeners, called on CoreAudio's own thread.
    static let audio = Self(add: { key, context in
        var address = key.audio
        return AudioObjectHasProperty(key.object, &address) && AudioObjectAddPropertyListener(key.object, &address, audioProc, context) == noErr
    }, remove: { key, context in
        var address = key.audio
        AudioObjectRemovePropertyListener(key.object, &address, audioProc, context)
    })

    /// CoreMediaIO's, the cameras'.
    static let camera = Self(add: { key, context in
        var address = key.cmio
        return CMIOObjectHasProperty(key.object, &address) && CMIOObjectAddPropertyListener(key.object, &address, cmioProc, context) == 0
    }, remove: { key, context in
        var address = key.cmio
        CMIOObjectRemovePropertyListener(key.object, &address, cmioProc, context)
    })
}

private let audioProc: AudioObjectPropertyListenerProc = { _, _, _, context in
    if let context { PropertyListeners.fire(context) }
    return noErr
}

private let cmioProc: CMIOObjectPropertyListenerProc = { _, _, _, context in
    if let context { PropertyListeners.fire(context) }
    return 0
}

extension PropertyKey {
    init(_ object: UInt32, _ selector: UInt32, _ scope: UInt32 = kAudioObjectPropertyScopeGlobal) {
        self.init(object: object, selector: selector, scope: scope)
    }

    var audio: AudioObjectPropertyAddress { AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain) }
    var cmio: CMIOObjectPropertyAddress {
        CMIOObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: CMIOObjectPropertyElement(kCMIOObjectPropertyElementMain))
    }
}
