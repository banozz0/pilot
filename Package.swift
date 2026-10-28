// swift-tools-version:6.2
import PackageDescription

// The bar drop's terminal (spec Bar drops T6, T11): libghostty, Ghostty v1.3.1 built from source with Sentry off by
// Scripts/build-ghosttykit.sh into .build/ghosttykit (GHOSTTY_LIB_DIR points elsewhere). A static libghostty autolinks
// nothing: these are the system libraries and frameworks it calls.
let ghosttyLibDir = Context.environment["GHOSTTY_LIB_DIR"] ?? "\(Context.packageDirectory)/.build/ghosttykit"
let ghosttyLinks: [LinkerSetting] = [.unsafeFlags(["-L", ghosttyLibDir]), .linkedLibrary("c++"), .linkedLibrary("z")]
    + ["Carbon", "Metal", "QuartzCore", "CoreText", "IOSurface", "UniformTypeIdentifiers", "Security", "IOKit"].map { .linkedFramework($0) }
// Sparkle 2 (SH6, pinned exactly): its framework sits in Pilot.app/Contents/Frameworks (Scripts/build-app.sh), so the bundled
// binary looks there too.
let sparkleRpath: LinkerSetting = .unsafeFlags(["-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks"])

// AeroSpace's own settings, which the lifted engine was written against.
let tilerSettings: [SwiftSetting] = [
    .enableUpcomingFeature("NonisolatedNonsendingByDefault"),
    .strictMemorySafety(),
]

let package = Package(
    name: "Pilot",
    platforms: [.macOS(.v26)],
    products: [
        .executable(name: "Pilot", targets: ["Pilot"]),
    ],
    dependencies: [
        .package(url: "https://github.com/sparkle-project/Sparkle", exact: "2.10.0"),
    ],
    targets: [
        // Pure logic, testable without a window server: layer state machine, keys, action registry.
        .target(name: "PilotCore", dependencies: ["PilotGate"]),
        // The AI agents' one rule for a `pilot` call (Packaging/pilot-agent-shell's): shared by PilotCore's API loop and pilot-mcp.
        .target(name: "PilotGate"),
        // The menu-bar app: event tap, onboarding, observers, UI. Bundled by Scripts/build-app.sh.
        .executableTarget(name: "Pilot", dependencies: ["PilotCore", "WebApps", "Clipboard", "PilotTiler", "PilotTilerPrivateApi", "CGhostty", "ImageScale",
                                                        .product(name: "Sparkle", package: "Sparkle")],
                          linkerSettings: ghosttyLinks + [sparkleRpath]),
        // The clipboard's image text in a child of its own, so Vision's memory leaves with it (story 142); Contents/Helpers/pilot-text.
        .executableTarget(name: "PilotText", dependencies: ["Clipboard"]),
        // Resize and upscale's pixels (Q246-Q248): resampling, the upscaler's tiles, the result's file; no Core ML here.
        .target(name: "ImageScale"),
        .testTarget(name: "ImageScaleTests", dependencies: ["ImageScale"]),
        // Real-ESRGAN on Core ML in a child that exits after each image (Q248), so its model and pixels never stay in Pilot;
        // Contents/Helpers/pilot-upscale.
        .executableTarget(name: "PilotUpscale", dependencies: ["ImageScale"]),
        // The pilot command (ADR 0013): talks to the running Pilot's control socket; Foundation only. Contents/Helpers/pilot, not
        // a target or product named pilot: on a case-insensitive disk that is the app's own Pilot.
        .executableTarget(name: "PilotCLI"),
        // Codex's one tool (ADR 0013): an MCP server over stdio that runs one gated `pilot` call; Contents/Helpers/pilot-mcp.
        .executableTarget(name: "PilotMCP", dependencies: ["PilotGate"]),
        // The web-app template: one binary, the site lives in the stamped copy's Info.plist (story 86).
        .executableTarget(name: "PilotWebApp", dependencies: ["WebApps"]),
        .testTarget(name: "PilotCoreTests", dependencies: ["PilotCore"], resources: [.copy("ScrollFrames")]),
        // The app window on a real NSWindow: Cmd+W, Cmd+Q, the Dock rule, and offscreen renders of every page.
        .testTarget(name: "PilotTests", dependencies: ["Pilot", "PilotTiler", "HungAppFixture", "PilotText", "PilotCLI", "PilotMCP", "PilotUpscale"]),
        // A windowless app that stops answering, for the Accessibility timeout test (card agent-bo-95423031).
        .executableTarget(name: "HungAppFixture", path: "Tests/Fixtures/HungApp"),
        // Install → Web App: stamps a signed copy of the PilotWebApp template per site (story 86).
        .target(name: "WebApps"),
        .testTarget(name: "WebAppsTests", dependencies: ["WebApps", "PilotWebApp"]),
        // Clipboard history, the store half: polls the pasteboard into SQLite (story 89).
        .target(name: "Clipboard"),
        .testTarget(name: "ClipboardTests", dependencies: ["Clipboard"]),
        // The own tiler (card agent-bo-95422996): AeroSpace's engine (MIT, 74a1bf17), lifted per the spike's code review.
        // Pilot's only tiler since 2026-10-10 (ADR 0011), driven through TilerService.
        .target(name: "PilotTilerPrivateApi", exclude: ["LICENSE"]),
        .target(name: "PilotTiler", dependencies: ["PilotTilerPrivateApi", "PilotCore"], exclude: ["LICENSE"], swiftSettings: tilerSettings),
        // Ghostty's embedder API (Sources/CGhostty/ghostty.h, the tag's); the archive comes from Scripts/build-ghosttykit.sh.
        .systemLibrary(name: "CGhostty", path: "Sources/CGhostty"),
        .testTarget(name: "PilotTilerTests", dependencies: ["PilotTiler", "PilotCore"], resources: [.copy("axDumps")], swiftSettings: tilerSettings),
    ]
)
