// swift-tools-version:6.2
import PackageDescription

let package = Package(
    name: "WidgetProbe",
    platforms: [.macOS(.v26)],
    targets: [.executableTarget(name: "WidgetProbe", swiftSettings: [.swiftLanguageMode(.v5)])]
)
