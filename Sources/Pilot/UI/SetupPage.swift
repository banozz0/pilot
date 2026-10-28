import CoreAudio
import PilotCore
import SwiftUI

/// What the Setup page reads the Mac through: the real system, or fakes in the offscreen renders, which read nothing of
/// the Mac's.
@MainActor
struct SetupDevices {
    var audio: AudioSystem
    var bluetooth: BluetoothSystem
    var wifi: WiFiSystem
    /// The displays model is the app's own, so a resolution waiting for Keep goes back even if the page closes.
    var displays: SetupDisplays
    /// The keyboard layouts come from the Look page's model (story 111), the one place Pilot switches them.
    var look: Look
    /// Where Setup remembers Bluetooth's first Show press.
    var defaults: UserDefaults = .pilot()
    /// The brightness keys' switch (card agent-bo-95423314); none in the renders.
    var settings: PilotSettings?
    /// Each screen's brightness (story 144); none in the renders, which read nothing of the Mac's.
    var brightness: Brightness?
    /// System › Mouse's pointer speed (Q442); a fake's in the renders, so none moves the pointer.
    var pointer: PointerSpeed?

    static var make: () -> SetupDevices = {
        SetupDevices(audio: CoreAudioSystem(), bluetooth: IOBluetoothSystem(), wifi: CoreWLANSystem(), displays: .shared, look: .shared,
                     settings: Engine.shared?.settings, brightness: ScreenBrightness.engine, pointer: .shared)
    }
}

/// Setup (round 8, Sven 2026-10-05, plan card 6Kx5FuzW2DU; on the kit, card agent-bo-95422898, design round 4 section 7):
/// the Mac's sound, Wi-Fi, Bluetooth, displays and keep-awake, and the keyboard layout moved from Look, each changed in
/// place inside Pilot on its own card. Where macOS refuses something to an app, an ⓘ says so instead of opening
/// System Settings.
struct SetupPage: View {
    @Environment(\.ink) private var ink
    /// The app window shows: the page follows the Mac's changes only then (AppWindowModel.onScreen).
    let onScreen: Bool
    /// The section a key or a link asked for: the page opens it, scrolls there once and clears it.
    @Binding var section: SetupSection?
    /// Two columns of cards once the page is this wide.
    @State private var wide = true
    /// None offscreen; the cards list only the keys that are bound.
    @Environment(Engine.self) private var engine: Engine?
    @State private var sound: SetupSound
    @State private var bluetooth: SetupBluetooth
    @State private var wifi: SetupWiFi
    private let displays: SetupDisplays
    private let brightness: Brightness?
    /// The secured network whose password field is open, and what is typed in it; cleared once it is used.
    @State private var joining: String?
    @State private var password = ""
    private let look: Look
    private let settings: PilotSettings?
    private let pointer: PointerSpeed?
    private let awake = KeepAwake.shared

    static let intro = "Sound, network, screens and sleep, changed inside Pilot."

    /// `open` is the renders' old way in and changes nothing: every part shows at once.
    init(onScreen: Bool, section: Binding<SetupSection?> = .constant(nil), open: SetupSection? = .sound, devices: SetupDevices = SetupDevices.make()) {
        self.onScreen = onScreen
        _section = section
        _sound = State(initialValue: SetupSound(audio: devices.audio))
        _bluetooth = State(initialValue: SetupBluetooth(bluetooth: devices.bluetooth, defaults: devices.defaults))
        _wifi = State(initialValue: SetupWiFi(wifi: devices.wifi, defaults: devices.defaults))
        displays = devices.displays
        brightness = devices.brightness
        look = devices.look
        settings = devices.settings
        pointer = devices.pointer
    }

    var body: some View {
        ScrollViewReader { proxy in
            KitPage(intro: Self.intro, fills: true) {
                cards
            }
            // Hyper+Ctrl+A, B and W, or a pilot://open link, land on their part (card agent-bo-95422805).
            .onChange(of: section, initial: true) {
                guard let section else { return }
                proxy.scrollTo(section, anchor: .top)
                self.section = nil
            }
        }
        .onChange(of: onScreen, initial: true) { onScreen ? start() : sound.stop() }
        .onDisappear { sound.stop() }
    }

    private func start() {
        sound.start()
        Task { await bluetooth.start() }
        Task { await wifi.start() }
        displays.start()
        look.followLayouts()
        pointer?.refresh()
    }

    /// Setup's actions (SystemModule): the three Omarchy control-panel keys, the media keys and the switches.
    static let keys: [(part: SetupSection, action: String, label: String)] = [
        (.sound, "system.soundSettings", "Sound in Pilot"), (.sound, "media.volumeUp", "Volume up"),
        (.sound, "media.volumeDown", "Volume down"), (.sound, "media.mute", "Mute"),
        (.wifi, "system.wifiSettings", "Wi-Fi in Pilot"), (.wifi, "system.wifi", "Wi-Fi on or off"),
        (.bluetooth, "system.bluetoothSettings", "Bluetooth in Pilot"), (.displays, "system.displaySettings", "Displays in Pilot"),
        (.keepAwake, "system.keepAwake", "Keep awake on or off"),
    ]

    // MARK: The cards

    /// Every part as its own card with its controls showing (Sven, 2026-10-07: "fill them with whats needed"), in two
    /// columns once the window is wide enough; nothing folds, so a link only scrolls to its part.
    private var cards: some View {
        Group {
            if wide {
                HStack(alignment: .top, spacing: 14) {
                    VStack(spacing: 14) { ForEach([SetupSection.sound, .wifi, .keyboard, .mouse], id: \.self) { card($0) } }
                    VStack(spacing: 14) { ForEach([SetupSection.displays, .bluetooth, .keepAwake], id: \.self) { card($0) } }
                }
            } else {
                VStack(spacing: 14) { ForEach(SetupSection.allCases, id: \.self) { card($0) } }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .onGeometryChange(for: Bool.self) { $0.size.width >= 880 } action: { wide = $0 }
        .padding(.top, 18)
    }

    /// A part's card: its squircle, name and how it stands, its controls, its fine print and its keys. Instrument's is its
    /// panel: the glyph, name and how it stands on a 44 pt header over a hairline, the rest under it.
    private func card(_ part: SetupSection) -> some View {
        Group {
            if ink.isInstrument {
                InstrumentBlock(title: part.title, symbol: part.symbol) { summary(part).lineLimit(1) } content: { cardBody(part) }
            } else {
                VStack(alignment: .leading, spacing: 0) {
                    HStack(spacing: 12) {
                        Squircle(symbol: part.symbol, colour: ink.module(part.colour))
                        Text(part.title).font(ink.ui(13.5, .semibold)).accessibilityAddTraits(.isHeader)
                        Spacer(minLength: 8)
                        summary(part).font(ink.ui(12.5)).foregroundStyle(ink.muted).lineLimit(1)
                    }
                    .padding(.bottom, 8)
                    cardBody(part)
                }
                .padding(.horizontal, 16).padding(.vertical, 14)
                .blockSurface()
            }
        }
        .id(part)
    }

    /// A part's controls, its fine print and its keys.
    @ViewBuilder private func cardBody(_ part: SetupSection) -> some View {
        detail(part)
        if let info = info(part) { FinePrint(text: info).padding(.top, 10) }
        let keys = Self.keys.filter { $0.part == part && engine?.binds.store.trigger(for: $0.action) != nil }
        if !keys.isEmpty {
            HStack(spacing: 14) {
                ForEach(keys, id: \.action) { key in
                    HStack(spacing: 6) { BindKey(action: key.action); Text(key.label).font(ink.ui(12)).foregroundStyle(ink.muted) }
                }
            }
            .padding(.top, 10)
        }
    }

    // MARK: Each part

    /// How a part stands, in a few words: "MacBook Pro Speakers · 62 %", "Home", "2 connected".
    @ViewBuilder private func summary(_ part: SetupSection) -> some View {
        switch part {
        case .sound:
            let side = sound.side(.output)
            let name = side.devices.first { $0.id == side.current }?.name ?? "No output"
            let level = side.muted == true ? "muted" : side.volume.map { "\(Int(($0.value * 100).rounded())) %" }
            Text([name, level].compactMap { $0 }.joined(separator: " · "))
        case .wifi:
            if let status = wifi.status {
                Text(status.on ? status.network ?? (wifi.location == .allowed ? "Not joined" : "On") : "Off")
            } else {
                Text(wifi.checked ? "No Wi-Fi" : "Reading…")
            }
        case .bluetooth:
            if bluetooth.offersShow { Text("Not shown yet") }
            else if bluetooth.access == .denied { Text("Not allowed") }
            else {
                let connected = bluetooth.devices.filter(\.connected).count
                Text(bluetooth.devices.isEmpty ? "No paired devices" : "\(connected) connected")
            }
        case .displays:
            if displays.displays.count == 1, let only = displays.displays.first { Text(only.mode.sizeLabel) }
            else { Text("\(displays.displays.count) screens") }
        case .keepAwake:
            Text(awake.isOn ? awake.until.map { "On until \($0.formatted(date: .omitted, time: .shortened))" } ?? "On" : "Off")
        case .keyboard:
            Text(look.layouts.first(where: \.isCurrent)?.name ?? "—")
        case .mouse:
            if let pointer { Text(pointer.current.map(PointerSpeed.label) ?? "—") }
        }
    }

    /// What macOS keeps from apps, or a part's rule, as an ⓘ.
    private func info(_ part: SetupSection) -> String? {
        switch part {
        case .sound: nil
        case .wifi: "Pilot never logs or keeps a network's password. Turning Wi-Fi on or off may need an administrator if macOS's Wi-Fi settings ask for one."
        case .bluetooth: "Pairing a new device, forgetting one and turning Bluetooth on or off stay in Control Centre and System Settings: macOS gives apps no public way to do them."
        case .displays: "A new resolution goes back by itself in 15 s unless you keep it; a rotation stays unless you press Revert. Pilot shows where your screens sit and leaves moving them, the main display and mirroring to macOS: a wrong position can lose a screen."
        case .keepAwake: "Stops the display and the Mac sleeping while it is on; quitting Pilot ends it."
        case .keyboard: "Pilot switches between the layouts macOS has enabled and never adds or removes one; add more in System Settings › Keyboard › Text Input."
        case .mouse: "The speed is macOS's own Tracking speed: System Settings shows it too, and a mouse plugged in later gets it. Your mouse's DPI stays in the mouse."
        }
    }

    @ViewBuilder private func detail(_ part: SetupSection) -> some View {
        switch part {
        case .sound:
            ForEach(AudioDirection.allCases, id: \.self) { direction in
                heading(direction.rawValue.capitalized, info: direction == .output
                        ? "Click a device to play the Mac's sound through it." : "Click a device to record from it.")
                level(direction)
                soundDevices(direction)
            }
            if let problem = sound.problem { problemLine(problem) }
        case .wifi:
            wifiSection
            if let problem = wifi.problem { problemLine(problem) }
        case .bluetooth: bluetoothDevices
        case .displays: displaySection
        case .keepAwake:
            BlockRow(first: true) {
                Image(systemName: awake.isOn ? "cup.and.saucer.fill" : "moon.zzz").font(ink.ui(20))
                    .foregroundStyle(awake.isOn ? ink.warnText : ink.muted).frame(width: 28).accessibilityHidden(true)
                // The time left counts down by the minute while it shows.
                TimelineView(.everyMinute) { context in
                    Text(awake.state(at: context.date)).font(ink.ui(14, .semibold))
                }
                .padding(.vertical, 8)
                InfoMark(text: "On, the display and the Mac stay awake for the time picked below.")
                Spacer()
                Toggle("Keep awake", isOn: Binding(get: { awake.isOn }, set: { $0 ? awake.turnOn(awake.length) : awake.turnOff() }))
                    .toggleStyle(.pilotSwitch)
            }
            BlockRow {
                Text("For")
                InfoMark(text: "How long Keep awake stays on before the Mac may sleep again.")
                Spacer()
                Segments(selection: Binding(get: { awake.length }, set: { awake.select($0) }), options: KeepAwake.Length.allCases.map { ($0, $0.title) }, label: "Keep awake for")
            }
            if let problem = awake.problem { problemLine(problem) }
        case .keyboard:
            heading("Typing in", info: "Click a layout to type in it from now on.")
            ForEach(look.layouts, id: \.id) { layout in
                ChoiceRow(picked: layout.isCurrent, title: layout.name, detail: layout.isCurrent ? "In use" : nil) { look.pickLayout(layout.id) } glyph: {
                    Text(String(layout.name.prefix(2)).uppercased()).font(ink.mono(10.5)).fontWeight(.semibold)
                }
            }
            if let error = look.layoutError { problemLine(error) }
        case .mouse: mouseSection
        }
    }

    /// The pointer speed (Sven, Q440 to Q442): Slow, Normal or Fast picked and used, the slider on the picked one, the key
    /// that cycles them, and the way to the mouse's buttons.
    @ViewBuilder private var mouseSection: some View {
        if let pointer {
            let speed = pointer.current ?? pointer.saved[pointer.picked]
            BlockRow(first: true) {
                Text("Speed")
                InfoMark(text: "Picks a saved speed and uses it at once; the slider below changes the one picked.")
                Spacer()
                Segments(selection: Binding(get: { pointer.picked }, set: { pointer.pick($0) }),
                         options: PointerSpeed.names.enumerated().map { ($0, $1) }, label: "Pointer speed")
            }
            BlockRow {
                Text(PointerSpeed.names[pointer.picked])
                InfoMark(text: "0 to 3 in steps of 0.05, finer than System Settings' ten notches. Moves the pointer at once and saves into the speed picked above.")
                Spacer()
                KitSlider(value: Binding(get: { speed }, set: { pointer.set($0) }), range: PointerSpeed.range, step: PointerSpeed.step,
                          label: "\(PointerSpeed.names[pointer.picked]) pointer speed")
                Text(PointerSpeed.label(speed)).font(ink.mono(12)).monospacedDigit().frame(width: 34, alignment: .trailing)
            }
            BlockRow {
                Text("Cycle speeds")
                InfoMark(text: "Steps Slow, Normal, Fast and back to Slow, with the speed in a tip.")
                Spacer()
                BindKey(action: "system.pointerSpeedCycle")
            }
            BlockRow {
                Text("Mouse buttons")
                InfoMark(text: "Your mouse's extra buttons, bound to any action.")
                Spacer()
                Button(AppPlace(.mouse).path) { AppWindowController.shared.open(AppPlace(.mouse)) }.buttonStyle(.pilot)
            }
        }
    }

    private func problemLine(_ text: String) -> some View {
        FinePrint(text: text, color: ink.red).padding(.vertical, 6)
    }

    /// A list's heading with its ⓘ, which says what a click on one of its rows does (page map, Sven 2026-10-17: every
    /// row has an ⓘ; a list's says it once, over its rows).
    private func heading(_ text: String, info: String) -> some View {
        HStack(spacing: 6) { PartHeading(text: text); InfoMark(text: info).padding(.top, 8) }
    }

    @ViewBuilder private var displaySection: some View {
        if displays.displays.count > 1 {
            Arrangement(displays: displays.displays, nicknames: displays.nicknames).padding(.bottom, 10)
        }
        ForEach(Array(displays.displays.enumerated()), id: \.element.id) { i, display in
            let unique = displays.displays.filter { $0.displayUUID == display.displayUUID }.count == 1
            let label = displays.nicknames.label(systemName: display.name, displayUUID: unique ? display.displayUUID : nil)
            BlockRow(first: i == 0 && displays.displays.count < 2) {
                TitledText(title: label, detail: displayDetail(display)).lineLimit(1).padding(.vertical, 4).help(label)
                InfoMark(text: "This screen's resolution and refresh rate; a change goes back by itself in 15 s unless you keep it.")
                if display.main { Chip(text: "main", color: ink.accent) }
                Spacer()
                if displays.offersPicker(display.id) {
                    let sizes = displays.sizes(for: display.id), rates = displays.rates(for: display.id)
                    Picker("Resolution", selection: Binding(get: { displays.selectedSize(for: display.id) ?? display.mode },
                                                            set: { displays.pick($0, for: display.id) })) {
                        ForEach(sizes, id: \.self) { Text($0.sizeLabel).tag($0) }
                    }
                    .labelsHidden().fixedSize()
                    if rates.count > 1 {
                        Picker("Refresh rate", selection: Binding(get: { displays.selectedRate(for: display.id) ?? display.mode },
                                                                  set: { displays.pick($0, for: display.id) })) {
                            ForEach(rates, id: \.self) { Text($0.rate ?? "?").tag($0) }
                        }
                        .labelsHidden().fixedSize()
                    }
                }
            }
            BlockRow {
                DisplayNicknameEditor(systemName: display.name, displayUUID: display.displayUUID, nicknames: displays.nicknames,
                                      identityIsUnique: unique)
                    .id(display.displayUUID)
                InfoMark(text: "Rename gives this screen a name of your own, shown only in Pilot.")
            }
            if let brightness { brightnessRow(display, brightness) }
            if let pending = displays.pending, pending.display == display.id {
                BlockRow {
                    TimelineView(.periodic(from: .now, by: 1)) { context in
                        Text("Keep \(pending.new.label)? Going back in \(pending.secondsLeft(at: context.date)) s")
                    }
                    InfoMark(text: "Keep holds the new mode; Go back, or waiting, brings the old one back.")
                    Spacer()
                    Button("Go back") { displays.revert() }.buttonStyle(.pilot)
                    Button("Keep") { displays.keep() }.buttonStyle(.pilotPrimary)
                }
            }
        }
        if let settings, brightness != nil { brightnessKeysRow(settings) }
        if let problem = displays.problem { problemLine(problem) }
    }

    /// The keyboard's own brightness keys through Pilot (card agent-bo-95423314), on at first.
    private func brightnessKeysRow(_ settings: PilotSettings) -> some View {
        let title = "Brightness keys follow the focused window"
        return BlockRow {
            TitledText(title: title, detail: "Your keyboard's brightness keys change the focused window's screen. Off, macOS keeps them.")
                .padding(.vertical, 4)
            InfoMark(text: "The brightness keys dim or brighten the screen the focused window is on, the main one or not.")
            Spacer()
            Toggle(title, isOn: Bindable(settings).brightnessKeys).toggleStyle(.pilotSwitch)
        }
    }

    /// A slider per screen, labelled with the route Pilot reaches it by (story 144); a screen that answers neither route
    /// says so, with what Sven can check.
    private func brightnessRow(_ display: DisplayInfo, _ brightness: Brightness) -> some View {
        let screen = brightness.screens[display.id]
        return BlockRow {
            Image(systemName: "sun.max.fill").foregroundStyle(ink.muted).frame(width: 16).accessibilityHidden(true)
            if let screen, let level = screen.level {
                KitSlider(value: Binding(get: { level }, set: { brightness.set(display.id, $0) }), label: "\(displays.nicknames.label(systemName: display.name, displayUUID: displays.displays.filter { $0.displayUUID == display.displayUUID }.count == 1 ? display.displayUUID : nil)) brightness")
                Text("\(Int((level * 100).rounded())) %").font(ink.mono(12)).foregroundStyle(ink.text2).monospacedDigit()
                    .frame(width: 44, alignment: .trailing)
            } else {
                Text(screen == nil ? "Reading brightness…" : "No brightness control").foregroundStyle(ink.muted)
                if screen != nil {
                    InfoMark(text: "This screen answers neither Apple's brightness call nor DDC/CI. Check that DDC/CI is on in the monitor's own menu and that its cable doesn't run through a hub or converter.")
                }
            }
            Spacer()
            if let screen { Chip(text: screen.route.label, tag: true) }
            if screen?.level != nil {
                InfoMark(text: "Sets this screen's brightness; the tag says how Pilot reaches it, Apple's own call or DDC/CI.")
            }
        }
    }

    /// "3440 × 1440 · 100 Hz · rotated 90°".
    private func displayDetail(_ display: DisplayInfo) -> String {
        display.mode.label + (display.rotation == 0 ? "" : " · rotated \(display.rotation)°")
    }

    @ViewBuilder private var wifiSection: some View {
        if let status = wifi.status {
            BlockRow(first: true) {
                TitledText(title: "Wi-Fi", detail: wifiState(status)).padding(.vertical, 4)
                InfoMark(text: "Turns this Mac's Wi-Fi on or off; the line under it is the network joined.")
                Spacer()
                Toggle("Wi-Fi", isOn: Binding(get: { status.on }, set: { on in Task { await wifi.setPower(on) } })).toggleStyle(.pilotSwitch)
            }
            if status.on { networkRows }
        } else {
            BlockRow(first: true) { Text(wifi.checked ? "This Mac has no Wi-Fi" : "Reading Wi-Fi…").foregroundStyle(ink.muted) }
        }
    }

    /// Under the switch while Wi-Fi is on: the Show networks press, the refusal, or the networks nearby.
    @ViewBuilder private var networkRows: some View {
        if wifi.offersShow {
            BlockRow {
                Text("Networks nearby")
                InfoMark(text: SetupWiFi.hiddenLine + " The first time, macOS asks.")
                Spacer()
                Button("Show networks") { Task { await wifi.showNetworks() } }.buttonStyle(.pilotPrimary)
            }
        } else if wifi.location == .denied {
            BlockRow { problemLine(SetupWiFi.deniedLine) }
        } else {
            BlockRow {
                Text("Networks nearby").foregroundStyle(ink.text2)
                InfoMark(text: "Join a network below; a secured one asks for its password first. Scan again looks afresh.")
                Spacer()
                Button(wifi.scanning ? "Scanning…" : "Scan again") { Task { await wifi.refreshNetworks(fresh: true) } }
                    .buttonStyle(.pilot).disabled(wifi.scanning)
            }
            HidingList(list: .wifi, items: wifi.networks, id: { $0.name }, name: \.name, inUse: wifi.isJoined, slot: true) { network, _ in
                VStack(spacing: 0) { networkRow(network) }
            }
        }
    }

    /// The bars' fill for a signal: -90 dBm none, -40 dBm full.
    private static func bars(_ signal: Int) -> Double { min(1, max(0, Double(signal + 90) / 50)) }

    /// Join: a secured network asks for its password first, an open one joins at once.
    private func join(_ network: WiFiNetwork) {
        if network.secured {
            joining = network.name
            password = ""
        } else {
            Task { await wifi.join(network, password: nil) }
        }
    }

    private func passwordRow(_ network: WiFiNetwork) -> some View {
        BlockRow {
            SecureField("Password, or empty if this Mac knows \(network.name)", text: $password).pilotField()
                .onSubmit { joinTyped(network) }
            InfoMark(text: "Pilot hands the password to macOS once and keeps no copy; empty uses the one this Mac saved.")
            Button("Cancel") { (joining, password) = (nil, "") }.buttonStyle(.pilot)
            Button("Join") { joinTyped(network) }.buttonStyle(.pilotPrimary)
        }
    }

    @ViewBuilder private func networkRow(_ network: WiFiNetwork) -> some View {
        BlockRow {
            Image(systemName: "wifi", variableValue: Self.bars(network.signal))
                .foregroundStyle(wifi.isJoined(network) ? ink.accent : ink.text2).frame(width: 18).accessibilityHidden(true)
            Text(network.name)
            if network.secured {
                Image(systemName: "lock.fill").font(ink.ui(9)).foregroundStyle(ink.muted).accessibilityLabel("Secured")
            }
            Spacer()
            Text("\(network.signal) dBm").font(ink.mono(12)).foregroundStyle(ink.muted)
            if wifi.isJoined(network) {
                Chip(text: "joined", color: ink.green)
            } else if joining != network.name {
                Button("Join") { join(network) }.buttonStyle(.pilot)
            }
        }
        if joining == network.name { passwordRow(network) }
    }

    /// Hands the typed password to macOS once and clears the field, so the page keeps no copy either; an empty field lets
    /// macOS use the password it saved for a network this Mac knows.
    private func joinTyped(_ network: WiFiNetwork) {
        let typed = password
        (joining, password) = (nil, "")
        let given = typed.isEmpty ? nil : typed
        Task { await wifi.join(network, password: given) }
    }

    /// "Home · -48 dBm · 866 Mbit/s", or the name hidden for want of Location access.
    private func wifiState(_ status: WiFiStatus) -> String {
        guard status.on else { return "Off" }
        let name = status.network ?? (wifi.location == .allowed ? "Not joined" : "Network name hidden by macOS")
        return ([name] + [status.signal.map { "\($0) dBm" }, status.rate.map { "\(Int($0)) Mbit/s" }].compactMap { $0 }).joined(separator: " · ")
    }

    @ViewBuilder private var bluetoothDevices: some View {
        if bluetooth.offersShow {
            BlockRow(first: true) {
                Text("Paired devices")
                InfoMark(text: "The first time, macOS asks whether Pilot may use Bluetooth.")
                Spacer()
                Button("Show paired devices") { Task { await bluetooth.show() } }.buttonStyle(.pilotPrimary)
            }
        } else if bluetooth.access == .denied {
            // The Show row's shape with its way out (card agent-bo-95422970): macOS never asks twice by itself.
            BlockRow(first: true) {
                Text("Paired devices")
                InfoMark(text: "macOS asks an app only once. Ask again clears Pilot's answer, so macOS shows its prompt again.")
                Spacer()
                Button("Open Settings") { bluetooth.openSettings() }.buttonStyle(.pilot)
                Button("Ask again") { Task { await bluetooth.askAgain() } }.buttonStyle(.pilotPrimary)
            }
            problemLine(SetupBluetooth.deniedLine)
            if let failure = bluetooth.resetFailure { problemLine(failure) }
        } else {
            if bluetooth.read, bluetooth.devices.isEmpty {
                BlockRow(first: true) { Text("No paired devices").foregroundStyle(ink.muted) }
            }
            deviceRows
        }
    }

    @ViewBuilder private var deviceRows: some View {
        HidingList(list: .bluetooth, items: bluetooth.devices, id: { $0.address }, name: \.name, inUse: \.connected, slot: true) { device, first in
            let busy = bluetooth.busy.contains(device.address)
            BlockRow(first: first) {
                Image(systemName: SetupGlyph.device(device.name)).font(ink.ui(14))
                    .foregroundStyle(device.connected ? ink.green : ink.muted).frame(width: 22).accessibilityHidden(true)
                TitledText(title: device.name, detail: bluetooth.failures[device.address] ?? (device.connected ? "Connected" : "Not connected"))
                    .padding(.vertical, 4)
                InfoMark(text: "Connects or disconnects this paired device; pairing and forgetting stay in Control Centre.")
                Spacer()
                Button(busy ? "…" : device.connected ? "Disconnect" : "Connect") { Task { await bluetooth.toggle(device) } }
                    .buttonStyle(.pilot).disabled(busy)
            }
        }
    }

    /// Every device of one side of Sound, the one in use checked.
    @ViewBuilder private func soundDevices(_ direction: AudioDirection) -> some View {
        let side = sound.side(direction)
        if side.devices.isEmpty { BlockRow { Text("No \(direction.rawValue) device").foregroundStyle(ink.muted) } }
        HidingList(list: .sound(direction), items: side.devices, id: { $0.uid }, name: \.name, inUse: { $0.id == side.current }) { device, _ in
            let symbol = SetupGlyph.device(device.name, input: direction == .input)
            ChoiceRow(picked: device.id == side.current, title: device.name, detail: device.id == side.current ? "In use" : nil) {
                sound.pick(device.id, direction)
            } glyph: { Image(systemName: symbol).font(ink.ui(13)) }
        }
    }

    @ViewBuilder private func level(_ direction: AudioDirection) -> some View {
        let side = sound.side(direction)
        let fixed = "This device sets its own volume; macOS gives apps no slider for it."
        if side.volume != nil || side.muted != nil {
            BlockRow {
                Image(systemName: direction == .output ? "speaker.fill" : "mic.fill").foregroundStyle(ink.muted).frame(width: 16)
                    .accessibilityHidden(true)
                if let volume = side.volume {
                    if volume.settable {
                        KitSlider(value: Binding(get: { Double(volume.value) }, set: { sound.setVolume(Float($0), direction) }),
                                  label: "\(direction.rawValue.capitalized) volume")
                    } else {
                        Text("Fixed volume").foregroundStyle(ink.muted)
                        InfoMark(text: fixed)
                        Spacer()
                    }
                    Text("\(Int((volume.value * 100).rounded())) %").font(ink.mono(12)).foregroundStyle(ink.text2).monospacedDigit()
                        .frame(width: 44, alignment: .trailing)
                    if volume.settable { InfoMark(text: "Drag to set the \(direction.rawValue) volume of the device in use.") }
                } else {
                    Text("No volume").foregroundStyle(ink.muted)
                    InfoMark(text: "This device has no volume macOS shows to apps.")
                    Spacer()
                }
                if let muted = side.muted {
                    Spacer(minLength: 12)
                    Text("Mute").foregroundStyle(ink.text2)
                    Toggle("Mute", isOn: Binding(get: { muted }, set: { sound.setMuted($0, direction) })).toggleStyle(.pilotSwitch)
                }
            }
        } else if side.current != nil {
            BlockRow {
                Text("Fixed volume").foregroundStyle(ink.muted)
                InfoMark(text: fixed)
            }
        }
    }
}

extension SetupSection {
    var title: String {
        switch self {
        case .sound: "Sound"
        case .wifi: "Wi-Fi"
        case .bluetooth: "Bluetooth"
        case .displays: "Displays"
        case .keepAwake: "Keep awake"
        case .keyboard: "Keyboard layout"
        case .mouse: "Mouse"
        }
    }

    var symbol: String {
        switch self {
        case .sound: "speaker.wave.2"
        case .wifi: "wifi"
        case .bluetooth: "dot.radiowaves.left.and.right"
        case .displays: "display"
        case .keepAwake: "cup.and.saucer"
        case .keyboard: "keyboard"
        case .mouse: "computermouse"
        }
    }

    /// The card's squircle colour, a module colour (Theme.module).
    var colour: Int {
        switch self {
        case .sound: 5
        case .wifi: 0
        case .bluetooth: 3
        case .displays: 4
        case .keepAwake: 1
        case .keyboard: 2
        case .mouse: 3
        }
    }
}

/// Where the screens sit, as macOS's Displays settings draws them: each a box to scale, the main one outlined in the accent.
private struct Arrangement: View {
    @Environment(\.ink) private var ink
    let displays: [DisplayInfo]
    var nicknames: DisplayNicknames = .shared

    var body: some View {
        let union = displays.map(\.frame).reduce(CGRect.null) { $0.union($1) }
        GeometryReader { space in
            let scale = min(space.size.width / union.width, space.size.height / union.height)
            let offset = CGPoint(x: (space.size.width - union.width * scale) / 2, y: (space.size.height - union.height * scale) / 2)
            ForEach(displays, id: \.id) { display in
                let f = display.frame
                RoundedRectangle(cornerRadius: 4)
                    .fill(ink.raised)
                    .overlay { RoundedRectangle(cornerRadius: 4).strokeBorder(display.main ? ink.accent : ink.line2, lineWidth: display.main ? 2 : 1) }
                    .overlay {
                        VStack(spacing: 3) {
                            Image(systemName: display.rotation == 0 ? "display" : "rectangle.portrait").font(ink.ui(14)).foregroundStyle(display.main ? ink.accent : ink.muted)
                            Text(label(display)).font(ink.ui(12).weight(.semibold)).foregroundStyle(ink.text2).help(label(display))
                            Text(display.mode.sizeLabel).font(ink.mono(10)).foregroundStyle(ink.muted)
                        }
                        .lineLimit(1).minimumScaleFactor(0.7).padding(4)
                    }
                    .frame(width: f.width * scale - 4, height: f.height * scale - 4)
                    .position(x: offset.x + (f.midX - union.minX) * scale, y: offset.y + (f.midY - union.minY) * scale)
            }
        }
        .frame(height: 190)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Screen arrangement: " + displays.map(label).joined(separator: ", "))
    }

    private func label(_ display: DisplayInfo) -> String {
        let unique = displays.filter { $0.displayUUID == display.displayUUID }.count == 1
        return nicknames.label(systemName: display.name, displayUUID: unique ? display.displayUUID : nil)
    }
}

/// One choice among a part's devices or layouts: what it is, its name, and the one in use lit with a check.
private struct ChoiceRow<Glyph: View>: View {
    @Environment(\.ink) private var ink
    let picked: Bool
    let title: String
    var detail: String?
    let action: () -> Void
    @ViewBuilder var glyph: Glyph

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: ink.radius(8), style: .continuous)
        Button(action: action) {
            HStack(spacing: 10) {
                glyph.foregroundStyle(picked ? ink.accent : ink.text2).frame(width: 26, height: 26)
                    .background(picked ? ink.accent.opacity(0.14) : ink.background.opacity(0.5), in: shape)
                    .accessibilityHidden(true)
                TitledText(title: Text(title).foregroundStyle(picked ? ink.text : ink.text2), detail: detail)
                Spacer(minLength: 8)
                if picked { Image(systemName: "checkmark").font(ink.ui(11, .bold)).foregroundStyle(ink.accentInk) }
            }
            .padding(.horizontal, 8).padding(.vertical, 5)
            .frame(maxWidth: .infinity, minHeight: 40, alignment: .leading)
            .background(picked ? ink.selected : .clear, in: shape)
            .contentShape(shape)
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(picked ? .isSelected : [])
    }
}

/// What a device is, from its name, as a symbol: AirPods, a mouse, a keyboard, the Mac's own speakers, a screen's.
enum SetupGlyph {
    static func device(_ name: String, input: Bool = false) -> String {
        let n = name.lowercased()
        return kinds.first { $0.0.contains { n.contains($0) } }?.1 ?? (input ? "mic" : "hifispeaker")
    }

    private static let kinds: [([String], String)] = [
        (["airpods"], "airpods"), (["headphone", "buds", "wh-", "beats"], "headphones"),
        (["mouse", "mx master", "mx anywhere"], "computermouse"), (["trackpad"], "rectangle.and.hand.point.up.left"),
        (["keyboard", "keychron", "k2", "hhkb"], "keyboard"), (["macbook", "built-in", "internal"], "laptopcomputer"),
        (["tv", "hdmi", "display", "lg ", "dell", "monitor", "4k"], "tv"), (["controller", "dualsense", "xbox"], "gamecontroller"),
        (["watch"], "applewatch"), (["iphone"], "iphone"), (["ipad"], "ipad"),
    ]
}
