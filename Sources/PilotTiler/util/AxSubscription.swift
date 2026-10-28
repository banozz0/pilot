// Vendored from AeroSpace (MIT, nikitabobko/AeroSpace) at 74a1bf17: Sources/AppBundle/util/AxSubscription.swift
import AppKit

/// The subscription is active as long as you keep this class in memory
final class AxSubscription {
    let obs: AXObserver
    let ax: AXUIElement
    let owningThread: AxAppThreadToken
    var notifKeys: Set<String> = []

    private init(obs: AXObserver, ax: AXUIElement) throws(TilerFault) {
        owningThread = try axTaskLocalAppThreadToken.orFault("axTaskLocalAppThreadToken is not initialized")
        self.obs = obs
        self.ax = ax
    }

    private func subscribe(_ key: String) throws -> Bool {
        try owningThread.checkEquals(axTaskLocalAppThreadToken)
        if AXObserverAddNotification(obs, ax, key as CFString, nil) == .success {
            notifKeys.insert(key)
            return true
        } else {
            return false
        }
    }

    static func bulkSubscribe(
        _ nsApp: NSRunningApplication,
        _ ax: AXUIElement,
        _ job: RunLoopJob,
        _ handlerToNotifKeyMapping: HandlerToNotifKeyMapping,
    ) throws -> [AxSubscription] {
        var result: [AxSubscription] = []
        var visitedNotifKeys: Set<String> = []
        for unsafe (handler, notifKeys) in unsafe handlerToNotifKeyMapping {
            try job.checkCancellation()
            guard let obs = unsafe AXObserver.new(nsApp.processIdentifier, handler) else { return [] }
            let subscription = try AxSubscription(obs: obs, ax: ax)
            for key: String in notifKeys {
                try job.checkCancellation()
                checkSoft(visitedNotifKeys.insert(key).inserted)
                if try !subscription.subscribe(key) { return [] }
            }
            CFRunLoopAddSource(CFRunLoopGetCurrent(), AXObserverGetRunLoopSource(obs), .defaultMode)
            result.append(subscription)
        }
        return result
    }

    deinit {
        checkSoft(owningThread == axTaskLocalAppThreadToken, "\(owningThread) != \(axTaskLocalAppThreadToken.prettyDescription)")
        CFRunLoopRemoveSource(CFRunLoopGetCurrent(), AXObserverGetRunLoopSource(obs), .defaultMode)
        for notifKey in notifKeys {
            AXObserverRemoveNotification(obs, ax, notifKey as CFString)
        }
    }
}

typealias HandlerToNotifKeyMapping = [(AXObserverCallback, [String])]
