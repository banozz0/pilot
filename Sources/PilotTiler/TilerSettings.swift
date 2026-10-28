import AppKit
import PilotCore

/// What the engine reads from its settings: AeroSpace's TOML config cut to the fields its engine uses (code review,
/// 2026-10-07). Defaults match AeroSpace's default-config.toml, so the ported tests run on the same world.
public struct TilerSettings: Equatable, Sendable {
    var gaps: Gaps = .zero
    /// Pilot (Sven on build 21): each monitor's top bar height, a hard edge no floating window sits under (barEdge.swift).
    var topBar: DynamicConfigValue<Int> = .constant(0)
    /// Pilot (scrolling layout): the widths a column steps through, as fractions of the usable width; a new column's
    /// width; how much of a column past an open edge stays on screen, in points; how long a strip scroll glides (nil jumps).
    var scrollingWidths: [CGFloat] = [1.0 / 3, 1.0 / 2, 2.0 / 3, 1]
    var scrollingNewWidth: CGFloat = 1.0 / 3
    var scrollingSliver: CGFloat = 5
    var scrollingGlide: Duration? = .milliseconds(350)
    /// Pilot (scrolling layout T9): when the strip centres the focused column.
    var scrollingCentre: PilotBlock.CentreMode = .never
    /// Pilot (scrolling layout T11): apps whose windows' columns keep a width of their own, by bundle id.
    var scrollingAppWidths: [String: CGFloat] = [:]
    /// Pilot (Sven's Q147): tiled windows glide to a new frame (GlideSet); off, every layout jumps.
    var glide: Bool = true
    var defaultRootContainerLayout: Layout = .tiles
    var defaultRootContainerOrientation: DefaultContainerOrientation = .auto
    var enableNormalizationFlattenContainers: Bool = true
    var enableNormalizationOppositeOrientationForNestedContainers: Bool = true
    var automaticallyUnhideMacosHiddenApps: Bool = false
    /// Workspaces that exist while empty, in order.
    var persistentWorkspaces: [String] = []
    var workspaceToMonitorForceAssignment: [String: [MonitorDescription]] = [:]
    var windowRules: [WindowRule] = []

    public init() {}
}

enum DefaultContainerOrientation: String, Sendable {
    case horizontal, vertical, auto
}

/// AeroSpace's on-window-detected callback, typed: a matcher and what to do with the window.
public struct WindowRule: Equatable, Sendable {
    public enum Action: Equatable, Sendable {
        case moveToWorkspace(String)
        case float
        /// Pilot (scrolling layout T11): the window focused now gets focus back once macOS gives it to this one.
        case keepFocus
    }

    var appId: String?
    var appNameRegexSubstring: CaseInsensitiveRegex?
    var windowTitleRegexSubstring: CaseInsensitiveRegex?
    var workspace: String?
    var duringStartup: Bool?
    var actions: [Action]
    var checkFurtherRules: Bool = false

    @MainActor
    func apply(to window: Window) async throws {
        for action in actions {
            switch action {
                case .moveToWorkspace(let name): _ = try window.moveToWorkspace(Workspace.get(byName: name))
                case .float: try await window.setLayout(.floating)
                case .keepFocus: if !isStartup, let kept = focus.windowOrNil, kept !== window { keepingFocus = (window.windowId, kept.windowId, .now) }
            }
        }
    }
}

@MainActor var config = TilerSettings()

/// True while the first refresh after start runs (AeroSpace's initAppBundle.swift:59).
@MainActor var isStartup: Bool { refreshSessionEvent?.isStartup == true }

/// AeroSpace's tray-menu enable gate (`TrayMenuModel.shared.isEnabled`): off, the engine leaves every window alone.
@MainActor var isTilerEnabled = false
