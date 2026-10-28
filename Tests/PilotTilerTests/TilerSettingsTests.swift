import Foundation
@testable import PilotTiler
import Testing

// Nested in TilerTreeTests: it reads isTilerEnabled, which the enable test flips.
extension TilerTreeTests {
    @MainActor
    @Suite
    struct TilerSettingsTests {
        /// The engine's defaults are AeroSpace's default-config.toml, which the ported tests were written against, and the
        /// scrolling layout's (scrolling-layout notes: 1/3 to full, new 1/3, a 5 px sliver, a 350 ms glide).
        @Test func defaultsMatchAeroSpaceDefaultConfig() {
            let settings = TilerSettings()
            #expect(settings.scrollingWidths == [1.0 / 3, 1.0 / 2, 2.0 / 3, 1] && settings.scrollingNewWidth == 1.0 / 3)
            #expect(settings.scrollingSliver == 5 && settings.scrollingGlide == .milliseconds(350))
            #expect(settings.defaultRootContainerLayout == .tiles)
            #expect(settings.enableNormalizationFlattenContainers)
            #expect(settings.gaps == .zero)
            #expect(!isTilerEnabled)
        }

        /// AeroSpace's on-window-detected `move-node-to-workspace` and `layout floating` callbacks, as WindowRule's typed
        /// actions (Moody fbYAVj96Ats: the rule had no test).
        @Test func aWindowRuleMovesAndFloatsTheWindow() async throws {
            let window = try TestWindow.new(id: 1, parent: Workspace.get(byName: "rule-from").rootTilingContainer)
            try await WindowRule(actions: [.moveToWorkspace("rule-to"), .float]).apply(to: window)
            #expect(window.nodeWorkspace?.name == "rule-to")
            #expect(window.parent is FloatingWindowsContainer)
        }
    }
}
