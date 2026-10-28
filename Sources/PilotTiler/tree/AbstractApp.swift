// Vendored from AeroSpace (MIT, nikitabobko/AeroSpace) at 74a1bf17: Sources/AppBundle/tree/AbstractApp.swift

protocol AbstractApp: AnyObject, Hashable, AeroAny {
    var pid: Int32 { get }
    var rawAppBundleId: String? { get }

    @MainActor func getFocusedWindow(_ cm: CancellationMode) async throws -> Window?
    var name: String? { get }
}

extension AbstractApp {
    static func == (lhs: Self, rhs: Self) -> Bool {
        if lhs.pid == rhs.pid {
            checkSoft(lhs === rhs)
            return true
        } else {
            checkSoft(lhs !== rhs)
            return false
        }
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(pid)
    }
}

extension Window {
    var macAppUnsafe: MacApp { get throws(TilerFault) { try (app as? MacApp).orFault("\(app) is not a MacApp") } }
}
