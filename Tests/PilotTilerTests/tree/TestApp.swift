// Ported from AeroSpace 74a1bf17 Sources/AppBundleTests/tree/TestApp.swift (MIT).
@testable import PilotTiler
import Testing

final class TestApp: AbstractApp {
    let pid: Int32
    let rawAppBundleId: String?
    let name: String?
    @MainActor
    static let shared = TestApp()

    private init() {
        self.pid = 0
        self.rawAppBundleId = "bobko.AeroSpace.test-app"
        self.name = rawAppBundleId
    }

    var _windows: [Window] = []
    var windows: [Window] {
        get { _windows }
        set {
            if let focusedWindow {
                #expect(newValue.contains(focusedWindow))
            }
            _windows = newValue
        }
    }

    private var _focusedWindow: Window? = nil
    var focusedWindow: Window? {
        get { _focusedWindow }
        set {
            if let window = newValue {
                #expect(windows.contains(window))
            }
            _focusedWindow = newValue
        }
    }
    @MainActor func getFocusedWindow(_ cm: CancellationMode) -> Window? { _focusedWindow }
}
