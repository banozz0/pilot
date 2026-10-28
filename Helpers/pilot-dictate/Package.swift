// swift-tools-version:6.2
import PackageDescription

// pilot-dictate: Pilot's own dictation (story 194) on this Mac: Whisper through WhisperKit (argmax, MIT, its licence in
// WhisperKit-LICENSE.txt) and Parakeet through FluidAudio (FluidInference, Apache 2.0, FluidAudio-LICENSE.txt), which
// also reads aloud in Kokoro; its NemoTextProcessing trait on (Sven Q266) so Kokoro says "$45" as forty five dollars and
// reads dates and links as words: text-processing-rs, a static library (FluidInference, Apache 2.0, the same licence
// text), costing the helper 7.7 MiB stripped (5.2 to 12.9). A package of its own, like Helpers/pilot-files, so Pilot's
// build and tests never fetch or compile them; Scripts/build-app.sh builds it into Contents/Helpers/pilot-dictate.
let package = Package(
    name: "pilot-dictate",
    platforms: [.macOS(.v26)],
    products: [.executable(name: "pilot-dictate", targets: ["PilotDictate"])],
    dependencies: [
        .package(url: "https://github.com/argmaxinc/WhisperKit", exact: "1.1.1"),
        .package(url: "https://github.com/FluidInference/FluidAudio", exact: "0.17.7", traits: ["NemoTextProcessing"]),
    ],
    targets: [
        // Download, prewarm, listen and transcribe, apart from the command so the tests call them.
        .target(name: "Dictate", dependencies: [.product(name: "WhisperKit", package: "WhisperKit"),
                                                .product(name: "FluidAudio", package: "FluidAudio")]),
        .executableTarget(name: "PilotDictate", dependencies: ["Dictate"]),
        // PILOT_LIVE=1 with models downloaded: transcribes fox.wav in each, never the microphone.
        .testTarget(name: "DictateTests", dependencies: ["Dictate"], resources: [.copy("Resources/fox.wav")]),
    ]
)
