#if DEBUG
import AppKit
import PilotCore
import SwiftUI
import Testing
@testable import Pilot

extension SharedLook {
/// Setup › Displays' arrangement with its arrows (Sven 2026-10-30), on a fake that moves its screens as CoreGraphics
/// would be asked to: no real screen moves. Sven's two screens, the 24G1WG4 portrait moved left of, right of, above and
/// below the CU34G4Z, each move's origins checked, then the main one moved under the portrait (which keeps the main at
/// 0, 0), and three screens with the Beside pick, where a move onto the third is refused. Opt-in like the other renders:
/// `CFFIXED_USER_HOME=/tmp/pilot-render-home PILOT_RENDER_DIR=/tmp/pilot-renders swift test --filter DisplayArrangementRenders`
@MainActor
@Suite("Display arrangement renders")
struct DisplayArrangementRenders {
    nonisolated static let env = ProcessInfo.processInfo.environment

    typealias FakeDisplays = SetupDisplaysTests.FakeDisplays
    static let builtIn = DisplayMode(id: 9, width: 1512, height: 982, pixelWidth: 3024, refresh: 120)

    @Test("The arrangement moves a screen to each side of another, origins checked", .enabled(if: env["PILOT_RENDER_DIR"] != nil && env["CFFIXED_USER_HOME"] != nil))
    func render() throws {
        let home = try #require(Self.env["CFFIXED_USER_HOME"])
        try #require(NSHomeDirectory() == home, "the home directory did not move; refusing to touch Sven's settings")
        let dir = URL(fileURLWithPath: try #require(Self.env["PILOT_RENDER_DIR"])).appendingPathComponent("display-arrangement")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        testApp()

        func origins(_ fake: FakeDisplays) -> [UInt32: CGPoint] { Dictionary(uniqueKeysWithValues: fake.screens.map { ($0.id, $0.frame.origin) }) }
        func shot(_ section: SetupDisplays, _ name: String) throws {
            let host = NSHostingView(rootView: Arrangement(section: section)
                .padding(16).frame(width: 560).pilotTheme().background(Theme.background))
            host.frame.size = host.fittingSize
            let w = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
            w.isReleasedWhenClosed = false
            w.contentView = host
            defer { w.close() }
            PanelTestSupport.pump(0.3)
            host.layoutSubtreeIfNeeded()
            try #require(snapshot(host, scale: 2)?.representation(using: .png, properties: [:])).write(to: dir.appendingPathComponent("\(name).png"))
        }

        // Sven's two screens: the portrait right of the wide one, as they start.
        let fake = FakeDisplays()
        let section = SetupDisplays(system: fake)
        section.start()
        try shot(section, "0-start")
        let expected: [(DisplayArrangement.Side, CGPoint)] = [
            (.left, CGPoint(x: -1440, y: -560)), (.above, CGPoint(x: 1000, y: -2560)), (.below, CGPoint(x: 1000, y: 1440)), (.right, CGPoint(x: 3440, y: -560)),
        ]
        for (i, (side, origin)) in expected.enumerated() {
            section.move(2, to: side, of: 1)
            let now = origins(fake)
            print("arrangement \(side.rawValue): CU34G4Z \(now[1]!), 24G1WG4 \(now[2]!)")
            #expect(now[1] == .zero && now[2] == origin, "24G1WG4 \(side.words) CU34G4Z")
            try shot(section, "\(i + 1)-\(side.rawValue)")
        }

        // The main one moved under the portrait: the main stays at 0, 0 and the portrait goes above it instead.
        section.move(1, to: .below, of: 2)
        print("arrangement main below: CU34G4Z \(origins(fake)[1]!), 24G1WG4 \(origins(fake)[2]!)")
        #expect(origins(fake) == [1: .zero, 2: CGPoint(x: 1000, y: -2560)])

        // macOS reading the old places back right after a move: the page draws the screen where it was sent, not one
        // press late.
        let late = FakeDisplays()
        late.lags = true
        let lagging = SetupDisplays(system: late)
        lagging.start()
        lagging.move(2, to: .left, of: 1)
        let drawn = lagging.displays.first { $0.id == 2 }!.frame.origin
        print("arrangement lagging read, left: macOS still says \(late.displays()[1].frame.origin), the page draws \(drawn)")
        #expect(drawn == CGPoint(x: -1440, y: -560), "the moved screen is drawn left of the main one at once")
        late.settle()

        // Dragged cards (Sven 2026-10-31): dropped near the main one's left edge, 100 points down, it lines up with its
        // top; dropped under it, a little left of centre, it centres.
        let dragged = FakeDisplays()
        let drops = SetupDisplays(system: dragged)
        drops.start()
        drops.drop(2, at: CGRect(x: -1500, y: 100, width: 1440, height: 2560))
        print("arrangement drop left: 24G1WG4 \(origins(dragged)[2]!)")
        #expect(origins(dragged) == [1: .zero, 2: CGPoint(x: -1440, y: 0)])
        drops.drop(2, at: CGRect(x: 900, y: 1500, width: 1440, height: 2560))
        print("arrangement drop below: 24G1WG4 \(origins(dragged)[2]!)")
        #expect(origins(dragged) == [1: .zero, 2: CGPoint(x: 1000, y: 1440)])
        // The main one dropped right of the portrait, its top 300 points below the portrait's: the main stays at 0, 0.
        drops.drop(1, at: CGRect(x: 2440, y: 1740, width: 3440, height: 1440))
        print("arrangement drop main right: CU34G4Z \(origins(dragged)[1]!), 24G1WG4 \(origins(dragged)[2]!)")
        #expect(origins(dragged) == [1: .zero, 2: CGPoint(x: -1440, y: -300)])
        try shot(drops, "6-dropped")

        // Three screens, a MacBook's left of the main one: the portrait left of the main would land on it, so nothing moves.
        let three = FakeDisplays()
        three.screens.append(DisplayInfo(id: 3, name: "Built-in Retina Display", main: false,
                                         frame: CGRect(x: -1512, y: 229, width: 1512, height: 982), mode: Self.builtIn, rotation: 0))
        let trio = SetupDisplays(system: three)
        trio.start()
        trio.move(2, to: .left, of: 1)
        print("arrangement three, left onto the built-in: \(three.arranged.isEmpty ? "refused" : "moved")")
        #expect(three.arranged.isEmpty, "a move onto a third screen is refused")
        trio.move(2, to: .above, of: 1)
        #expect(origins(three)[2] == CGPoint(x: 1000, y: -2560))
        try shot(trio, "5-three")
    }
}
}
#endif
