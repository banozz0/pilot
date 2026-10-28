import AppKit
import CoreWLAN
import PilotCore
import SwiftUI

/// What the info HUD shows (story 188): the time and date, and the battery, the weather and the Wi-Fi network where this
/// Mac has them. Read once on the press, never polled; a reading this Mac lacks is left out without a word.
struct InfoModel {
    let time: String
    let date: String
    /// The lines under the time, in order, each a name and its value: the battery, the Weather extension's bar text
    /// ("☀️ 24°") as its bar item last answered, and the joined network's name, which macOS hides from an app without
    /// Location (the press never asks for it).
    let rows: [(name: String, value: String)]

    init(time: String, date: String, battery: SystemStats.Battery? = nil, weather: String? = nil, wifi: String? = nil) {
        self.time = time; self.date = date
        rows = [battery.map { ("Battery", $0.phrase) }, weather.map { ("Weather", $0) }, wifi.map { ("Wi-Fi", $0) }].compactMap(\.self)
    }

    /// Every reading as the press finds it: what Pilot already holds or macOS answers at once, nothing that asks.
    @MainActor static func read(now: Date = Date()) -> InfoModel {
        InfoModel(time: now.formatted(date: .omitted, time: .shortened),
                  date: ClockMonth.fullDate(now, timeZone: .autoupdatingCurrent, locale: .autoupdatingCurrent),
                  battery: SystemReader.battery(), weather: ExtensionBar.shared.text(for: "weather"),
                  wifi: CWWiFiClient.shared().interface()?.ssid())
    }

    /// The one element VoiceOver reads.
    var label: String { ([time, date] + rows.map { "\($0.name) \($0.value)" }).joined(separator: ", ") }
}

/// The info HUD (story 188): one panel on the focused window's screen, where the level HUD sits, never taking a click. A
/// press while it shows reads again and starts its time over.
@MainActor
enum InfoHUD {
    /// Seconds it stays: long enough to read four lines.
    static let seconds: TimeInterval = 4
    private static var panel: NSPanel?
    private static var fade: Timer?

    /// Reads and shows once the tap's callback has returned, so IOKit and CoreWLAN never hold a key.
    static func show() {
        DispatchQueue.main.async { present(InfoModel.read()) }
    }

    private static func present(_ model: InfoModel) {
        hide()
        let shown = HUD.makePanel(InfoView(model: model).fixedSize())
        shown.ignoresMouseEvents = true
        if let screen = Screens.focusedScreen ?? NSScreen.main {
            shown.setFrameOrigin(LevelHUD.origin(for: shown.frame.size, in: screen.visibleFrame))
        }
        shown.orderFrontRegardless()
        panel = shown
        // A press during the fade has already hidden this panel and shown its own, so the close checks it is still the one.
        fade = Timer.scheduledTimer(withTimeInterval: seconds, repeats: false) { _ in
            MainActor.assumeIsolated {
                NSAnimationContext.runAnimationGroup({ $0.duration = 0.3; shown.animator().alphaValue = 0 }) {
                    MainActor.assumeIsolated { if panel === shown { hide() } }
                }
            }
        }
    }

    private static func hide() {
        fade?.invalidate()
        fade = nil
        panel?.orderOut(nil)
        panel = nil
    }
}

/// The info HUD's face in the picked style.
struct InfoView: View {
    @Environment(\.style) private var style
    let model: InfoModel

    var body: some View {
        Group {
            switch style.kind {
            case .instrument: InstrumentInfo(model: model)
            case .toybox: ToyInfo(model: model)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(model.label)
    }
}

/// Instrument's: a clock on a tile beside the time in Geist Mono and the date, then each reading's name in the third
/// text colour and its value at the right, under a hairline. The level HUD's width.
private struct InstrumentInfo: View {
    @Environment(\.style) private var style
    let model: InfoModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 14) {
                Image(systemName: "clock").font(.system(size: 17, weight: .regular)).foregroundStyle(style.color(\.text2)).instrumentTile(36)
                VStack(alignment: .leading, spacing: 2) {
                    Text(model.time).font(style.font(\.key, size: 20)).monospacedDigit().foregroundStyle(style.color(\.text))
                    Text(model.date).styleText(\.caption).foregroundStyle(style.color(\.text2)).lineLimit(1)
                }
            }
            if !model.rows.isEmpty {
                InstrumentRule()
                VStack(spacing: 7) {
                    ForEach(model.rows, id: \.name) { row in
                        HStack(alignment: .firstTextBaseline, spacing: 12) {
                            Text(row.name).styleText(\.caption).foregroundStyle(style.color(\.text3))
                            Spacer(minLength: 0)
                            Text(row.value).styleText(\.body).monospacedDigit().foregroundStyle(style.color(\.text)).lineLimit(1).minimumScaleFactor(0.8)
                        }
                    }
                }
            }
        }
        .padding(.leading, 14).padding(.trailing, 18).padding(.vertical, 14)
        .frame(width: 320, alignment: .leading)
    }
}

/// Toybox's: the clock on a raised key beside the time in Fredoka and the date, then each reading in a sunk well, its
/// name quiet and its value at the right. The level HUD's width.
private struct ToyInfo: View {
    @Environment(\.style) private var style
    let model: InfoModel

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 14) {
                Image(systemName: "clock.fill").font(.system(size: 20, weight: .bold)).foregroundStyle(style.color(\.text))
                    .frame(width: 40, height: 40)
                    .padding(EdgeInsets(top: 2, leading: 2, bottom: 4, trailing: 2))
                    .background(Toy.block(style, fill: style.color(\.raised), radius: style.radii.key, edge: 4))
                VStack(alignment: .leading, spacing: 0) {
                    Text(model.time).font(Toy.fredoka(24)).monospacedDigit().foregroundStyle(style.color(\.text))
                    Text(model.date).font(Toy.nunito(800, 13)).foregroundStyle(style.color(\.text2)).lineLimit(1)
                }
            }
            if !model.rows.isEmpty {
                VStack(spacing: 6) {
                    ForEach(model.rows, id: \.name) { row in
                        HStack(alignment: .firstTextBaseline, spacing: 12) {
                            Text(row.name).font(Toy.nunito(800, 13)).foregroundStyle(style.color(\.text2))
                            Spacer(minLength: 0)
                            Text(row.value).font(Toy.nunito(700, 14)).monospacedDigit().foregroundStyle(style.color(\.text)).lineLimit(1)
                                .minimumScaleFactor(0.8)
                        }
                    }
                }
                .padding(.horizontal, 12).padding(.vertical, 9)
                .toyWell(radius: style.radii.key)
            }
        }
        .padding(.leading, 12).padding(.trailing, 20).padding(.vertical, 12)
        .frame(width: 340, alignment: .leading)
    }
}
