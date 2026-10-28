// Ported from AeroSpace 74a1bf17 Sources/AppBundleTests/testUtil.swift (MIT).
import AppKit
@testable import PilotTiler
import Testing

/// Every suite that builds a tree nests here: the tree, focus and workspaces are global, and Swift Testing runs
/// top-level suites in parallel, so one serialized parent keeps two suites from meeting at an `await`. `.tilerTree`
/// gives each test inside AeroSpace's setUp.
@MainActor
@Suite(.serialized, .tilerTree)
enum TilerTreeTests {}

/// AeroSpace's `setUp() { setUpWorkspacesForTests() }` for every test under the trait, plus its crash on die/check:
/// an engine fault reported during the test fails it, and the previous handler is back afterwards.
struct TilerTreeScope: TestTrait, SuiteTrait, TestScoping {
    var isRecursive: Bool { true }

    @concurrent
    func provideScope(for test: Test, testCase: Test.Case?, performing function: @concurrent @Sendable () async throws -> Void) async throws {
        let previous = tilerFaultHandler
        tilerFaultHandler = { fault in Issue.record("Engine fault (AeroSpace would have died): \(fault.message)") }
        defer { tilerFaultHandler = previous }
        try await setUpWorkspacesForTests()
        try await function()
    }
}

extension Trait where Self == TilerTreeScope {
    static var tilerTree: Self { TilerTreeScope() }
}

/// The workspace each test builds in (AeroSpace used the XCTest name; every test unbinds everything first anyway).
let name = "test"

@MainActor
func setUpWorkspacesForTests() throws {
    config = TilerSettings()
    config.enableNormalizationFlattenContainers = false // Make layout tests more predictable
    config.enableNormalizationOppositeOrientationForNestedContainers = false // Make layout tests more predictable
    config.defaultRootContainerOrientation = .horizontal // Make default layout predictable

    // Don't create any workspaces for tests (Pilot has no binding modes to clear)
    config.persistentWorkspaces = []

    // Pilot: one test monitor and the engine off, as AeroSpace's tests always had (UnitTestScreen, isTilerEnabled)
    unitTestScreen.withLock { $0 = UnitTestScreen() }
    gcMonitors()
    isTilerEnabled = false
    arrangements = [:]
    draggedWindowId = nil
    dragPreview = nil
    cancelledDragWindowId = nil
    gapDrag = nil
    TilerGaps.shown = []
    scheduleDragPreview = previewInASession
    reduceMotion = { false }
    lowPowerMode = { false }
    currentlyManipulatedWithMouseWindowId = nil
    windowSlots = WindowSlots()
    windowHomes = WindowHomes()
    windowTitles = [:]
    windowsSeenInDrag.withLock { $0 = [] }

    for workspace in Workspace.all {
        for child in workspace.children {
            try child.unbindFromParent()
        }
    }
    try #require(Workspace.get(byName: "setUpWorkspacesForTests").focusWorkspace())
    Workspace.garbageCollectUnusedWorkspaces()
    try #require(focus.workspace.isEffectivelyEmpty)
    try #require(focus.workspace === Workspace.all.singleOrNil(), "\(Workspace.all.map(\.description).joined(separator: ", "))")
    try #require(mainMonitorInfo.setActiveWorkspace(focus.workspace))

    TestApp.shared.focusedWindow = nil
    TestApp.shared.windows = []
    _prevFocusedWorkspaceName = nil
}

/// What AeroSpace's `Shell.run` did around a command in tests: the call, then the closed-windows cache reset and
/// `refreshModel` (workspace GC, focus callbacks, normalization).
@MainActor @discardableResult
func run<T>(_ call: @MainActor () async throws -> T) async throws -> T {
    let result = try await call()
    resetClosedWindowsCache()
    try await refreshModel_nonCancellable()
    return result
}

extension AeroAny {
    /// `apply` for a block that throws: the engine's tree calls throw a TilerFault where AeroSpace died.
    @discardableResult
    func with(_ block: (Self) throws -> Void) throws -> Self {
        try block(self)
        return self
    }
}

extension TilingContainer {
    @MainActor @discardableResult
    static func newHTiles(parent: NonLeafTreeNodeObject, adaptiveWeight: CGFloat) throws -> TilingContainer {
        try newHTiles(parent: parent, adaptiveWeight: adaptiveWeight, index: INDEX_BIND_LAST)
    }

    @MainActor @discardableResult
    static func newVTiles(parent: NonLeafTreeNodeObject, adaptiveWeight: CGFloat) throws -> TilingContainer {
        try newVTiles(parent: parent, adaptiveWeight: adaptiveWeight, index: INDEX_BIND_LAST)
    }
}

/// The focused window, for the calls AeroSpace ran on the focus.
@MainActor
func focusedWindow() throws -> Window {
    try #require(focus.windowOrNil)
}

/// Window `id` opening on `workspace`: bound where a new tiled window goes there, before any layout or rebuild.
@MainActor @discardableResult
func openWindow(_ id: UInt32, on workspace: Workspace) async throws -> Window {
    let window = try TestWindow.new(id: id, parent: Workspace.get(byName: "opening").floatingWindowsContainer)
    try await window.relayoutWindow(on: workspace, .nonCancellable, forceTile: true)
    return window
}

/// A second 1920 x 1080 display, right of the test monitor.
let testSecondMonitorInfo = MonitorInfoImpl(monitorAppKitNsScreenScreensId: 2, name: "Second Monitor",
                                            rect: Rect(topLeftX: 1920, topLeftY: 0, width: 1920, height: 1080),
                                            visibleRect: Rect(topLeftX: 1920, topLeftY: 0, width: 1920, height: 1080), isMain: false)
