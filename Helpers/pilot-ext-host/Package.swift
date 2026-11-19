// swift-tools-version:6.2
import PackageDescription

// pilot-ext-host (ADR 0017): runs one Raycast-format extension command on JavaScriptCore, which ships with macOS, so it adds
// no engine. A package of its own so Pilot's main binary never links it; Scripts/build-app.sh builds it into
// Contents/Helpers/pilot-ext-host and its prelude, pilot-ext-prelude.js, into Contents/Resources.
let package = Package(
    name: "pilot-ext-host",
    platforms: [.macOS(.v26)],
    products: [.executable(name: "pilot-ext-host", targets: ["pilot-ext-host"])],
    targets: [
        .executableTarget(name: "pilot-ext-host", linkerSettings: [.linkedFramework("JavaScriptCore")]),
    ]
)
