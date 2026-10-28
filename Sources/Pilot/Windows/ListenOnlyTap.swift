@preconcurrency import Cocoa

/// A listen-only session tap placed last on the main run loop, for the events in `mask`: it never holds or changes an
/// event, and turns itself back on when macOS turns it off. The swipe's gesture tap and Defocus's shake tap use it.
@MainActor
final class ListenOnlyTap {
    private let mask: CGEventMask
    private var tap: CFMachPort?
    private var source: CFRunLoopSource?
    fileprivate var handle: (CGEvent) -> Void = { _ in }

    init(mask: CGEventMask) { self.mask = mask }

    /// False when the tap could not be made.
    func start(_ handle: @escaping (CGEvent) -> Void) -> Bool {
        self.handle = handle
        let me = Unmanaged.passUnretained(self).toOpaque()
        guard let tap = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .tailAppendEventTap, options: .listenOnly,
                                          eventsOfInterest: mask, callback: listenOnlyCallback, userInfo: me) else { return false }
        let source = CFMachPortCreateRunLoopSource(nil, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        self.tap = tap
        self.source = source
        return true
    }

    func stop() {
        if let tap { CGEvent.tapEnable(tap: tap, enable: false); CFMachPortInvalidate(tap) }
        if let source { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes) }
        tap = nil; source = nil
    }

    fileprivate func received(_ type: CGEventType, _ event: CGEvent) {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            return
        }
        handle(event)
    }
}

private let listenOnlyCallback: CGEventTapCallBack = { _, type, event, userInfo in
    guard let userInfo else { return Unmanaged.passUnretained(event) }
    let tap = Unmanaged<ListenOnlyTap>.fromOpaque(userInfo).takeUnretainedValue()
    // The tap's run loop source lives on the main run loop, so this runs on the main thread.
    nonisolated(unsafe) let event = event
    MainActor.assumeIsolated { tap.received(type, event) }
    return Unmanaged.passUnretained(event)
}
