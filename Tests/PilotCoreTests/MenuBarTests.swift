import Testing
@testable import PilotCore

@Suite("Workspace menu bar")
struct MenuBarTests {
    private func window(_ id: Int, _ app: String, on workspace: String) -> AeroWindow {
        AeroWindow(id: id, appName: app, bundleId: "x.\(app)", pid: 1, workspace: workspace, monitorId: 1, layout: "h_tiles", title: "")
    }

    @Test("The dropdown lists each workspace that has a window, numbers in order, its apps once each with their bundle ids")
    func occupied() {
        let windows = [
            window(1, "Vesktop", on: "10"), window(2, "Ghostty", on: "1"), window(3, "Zen", on: "2"),
            window(4, "Ghostex", on: "1"), window(5, "Ghostty", on: "1"), window(6, "Notes", on: "scratch"),
        ]
        #expect(OccupiedWorkspace.list(windows) == [
            OccupiedWorkspace(name: "1", apps: ["Ghostty", "Ghostex"], bundles: ["Ghostty": "x.Ghostty", "Ghostex": "x.Ghostex"]),
            OccupiedWorkspace(name: "2", apps: ["Zen"], bundles: ["Zen": "x.Zen"]),
            OccupiedWorkspace(name: "10", apps: ["Vesktop"], bundles: ["Vesktop": "x.Vesktop"]),
            OccupiedWorkspace(name: "scratch", apps: ["Notes"], bundles: ["Notes": "x.Notes"]),
        ])
        #expect(OccupiedWorkspace.list([]).isEmpty)
    }

    @Test("The icon is the workspace number, a dash without the tiler, ! for secure input, off when switched off")
    func iconText() {
        #expect(MenuBarTitle.text(isOn: true, workspace: "5", secureInput: false) == "5")
        #expect(MenuBarTitle.text(isOn: true, workspace: "5", secureInput: true) == "5 !")
        #expect(MenuBarTitle.text(isOn: true, workspace: nil, secureInput: false) == "–")
        #expect(MenuBarTitle.text(isOn: true, workspace: nil, secureInput: true) == "– !")
        #expect(MenuBarTitle.text(isOn: false, workspace: "5", secureInput: true) == "off")
    }
}
