import AppKit

// A test stand-in for a hung app (card agent-bo-95423031): a windowless app whose main thread stops answering half a
// second after launch, for as many seconds as its argument says, so Accessibility asks to it wait out their timeout.
let seconds = CommandLine.arguments.dropFirst().first.flatMap(UInt32.init) ?? 10
NSApplication.shared.setActivationPolicy(.accessory)
DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
    print("hung")
    fflush(stdout)
    sleep(seconds)
    exit(0)
}
NSApplication.shared.run()
