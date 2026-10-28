// Vendored from AeroSpace (MIT, nikitabobko/AeroSpace) at 74a1bf17: Sources/AppBundle/getNativeFocusedWindow.swift
import AppKit

@MainActor
var appForTests: (any AbstractApp)? = nil

@MainActor
private var focusedApp: (any AbstractApp)? {
    get async throws {
        if isUnitTest {
            return appForTests
        } else {
            if appForTests != nil { try raiseFault("appForTests is set outside a unit test") }
            return switch NSWorkspace.shared.frontmostApplication {
                case let frontmostApplication?: try await MacApp.getOrRegister(frontmostApplication)
                case nil: nil
            }
        }
    }
}

@MainActor
func getNativeFocusedWindow(_ cm: CancellationMode) async throws -> Window? {
    // Pilot (AC6): a frontmost app that does not answer has no focused window this session
    do { return try await focusedApp?.getFocusedWindow(cm) } catch is AxTimeout { return nil }
}
