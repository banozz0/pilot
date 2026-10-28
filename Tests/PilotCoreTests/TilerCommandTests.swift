import Testing
@testable import PilotCore

@Suite("Tiler commands")
struct TilerCommandTests {
    @Test("Workspace commands' text form, as logs and refusals print it")
    func commandArguments() {
        #expect(AeroCommand.workspace("3").arguments == ["workspace", "3"])
        #expect(AeroCommand.workspaceNext.arguments == ["workspace", "--wrap-around", "next"])
        #expect(AeroCommand.workspacePrevious.arguments == ["workspace", "--wrap-around", "prev"])
        #expect(AeroCommand.workspaceBackAndForth.arguments == ["workspace-back-and-forth"])
        #expect(AeroCommand.moveWindow(id: 9521, toWorkspace: "4").arguments
                == ["move-node-to-workspace", "--window-id", "9521", "4"])
        #expect(AeroCommand.moveWindow(id: 9521, toWorkspace: "3", follow: true).arguments
                == ["move-node-to-workspace", "--window-id", "9521", "--focus-follows-window", "3"])
    }

    @Test("Tiled window keys' text form, aimed at a window by id where the command allows it")
    func tiledCommandArguments() {
        #expect(AeroCommand.focus(.left).arguments == ["focus", "left"])
        #expect(AeroCommand.swap(id: 9521, .up).arguments == ["swap", "--window-id", "9521", "up"])
        #expect(AeroCommand.resize(id: 9521, .width, by: 60).arguments == ["resize", "--window-id", "9521", "width", "+60"])
        #expect(AeroCommand.resize(id: 9521, .height, by: -60).arguments == ["resize", "--window-id", "9521", "height", "-60"])
        #expect(AeroCommand.flipSplit(id: 9521).arguments == ["layout", "--window-id", "9521", "horizontal", "vertical"])
        #expect(AeroCommand.toggleScrolling(workspace: "3").arguments
                == ["layout", "--workspace", "3", "--root", "tiles", "scrolling"])
        #expect(AeroCommand.cycleColumnWidth(id: 9521, forward: true).arguments == ["column-width", "--window-id", "9521", "next"])
        #expect(AeroCommand.cycleColumnWidth(id: 9521, forward: false).arguments == ["column-width", "--window-id", "9521", "prev"])
        #expect(AeroCommand.centreColumn(id: 9521).arguments == ["center-column", "--window-id", "9521"])
        #expect(AeroCommand.maximiseColumn(id: 9521).arguments == ["column-width", "--window-id", "9521", "maximise"])
        #expect(AeroCommand.leaveStack(id: 9521).arguments == ["leave-stack", "--window-id", "9521"])
        #expect(AeroCommand.setColumnWidth(id: 9521, points: 1133).arguments == ["column-width", "--window-id", "9521", "1133"])
        #expect(AeroCommand.focusMonitor(.right).arguments == ["focus-monitor", "--wrap-around", "right"])
        #expect(AeroCommand.moveToMonitor(id: 9521, .left).arguments
                == ["move-node-to-monitor", "--window-id", "9521", "--focus-follows-window", "--wrap-around", "left"])
    }

    /// The listing shape the tiler answers in (recorded from the CLI it was ported from, 2026-10-04; titles neutralised).
    static let listWindowsFixture = #"""
    [
      {
        "app-bundle-id" : "com.madda.ghostex.gpui",
        "app-name" : "Ghostex",
        "app-pid" : 74719,
        "monitor-id" : 2,
        "window-id" : 9521,
        "window-layout" : "h_tiles",
        "window-title" : "agent-board - Ghostex",
        "workspace" : "1"
      },
      {
        "app-bundle-id" : "dev.vencord.vesktop",
        "app-name" : "Vesktop",
        "app-pid" : 47278,
        "monitor-id" : 1,
        "window-id" : 8962,
        "window-layout" : "floating",
        "window-title" : "• Discord | \"general\"",
        "workspace" : "10"
      }
    ]
    """#

    @Test("Window listings ask for every field Pilot reads, and parse into windows")
    func listWindows() throws {
        #expect(AeroCommand.listWindows(.focused).arguments
                == ["list-windows", "--focused", "--json", "--format", AeroWindow.format])
        #expect(AeroCommand.listWindows(.all).arguments.prefix(2) == ["list-windows", "--all"])
        #expect(AeroCommand.listWindows(.workspace("4")).arguments.prefix(3) == ["list-windows", "--workspace", "4"])
        for field in ["window-id", "app-name", "app-bundle-id", "app-pid", "workspace", "monitor-id", "window-layout", "window-title"] {
            #expect(AeroWindow.format.contains("%{\(field)}"))
        }

        let windows = try AeroWindow.parse(Self.listWindowsFixture)
        #expect(windows == [
            AeroWindow(id: 9521, appName: "Ghostex", bundleId: "com.madda.ghostex.gpui", pid: 74719,
                       workspace: "1", monitorId: 2, layout: "h_tiles", title: "agent-board - Ghostex"),
            AeroWindow(id: 8962, appName: "Vesktop", bundleId: "dev.vencord.vesktop", pid: 47278,
                       workspace: "10", monitorId: 1, layout: "floating", title: "• Discord | \"general\""),
        ])
        #expect(windows.map(\.isFloating) == [false, true])
        #expect(try AeroWindow.parse("[]").isEmpty)
        #expect(throws: (any Error).self) { try AeroWindow.parse("not json") }
    }

    @Test("Visible workspace per monitor parses from list-workspaces")
    func workspacePerMonitor() throws {
        #expect(AeroCommand.listVisibleWorkspaces.arguments
                == ["list-workspaces", "--monitor", "all", "--visible", "--json", "--format", "%{workspace} %{monitor-id} %{monitor-name}"])
        // Recorded on Sven's two displays, 2026-10-04.
        let json = #"""
        [
          { "monitor-id" : 2, "monitor-name" : "CU34G4Z", "workspace" : "1" },
          { "monitor-id" : 1, "monitor-name" : "24G1WG4", "workspace" : "10" }
        ]
        """#
        #expect(try AeroMonitorWorkspace.parse(json) == [
            AeroMonitorWorkspace(monitorId: 2, monitorName: "CU34G4Z", workspace: "1"),
            AeroMonitorWorkspace(monitorId: 1, monitorName: "24G1WG4", workspace: "10"),
        ])
    }
}
