import PilotCore
import SwiftUI

/// Story 160's password settings under Generate a password on Launcher › Abilities (page map, Sven 2026-10-17: a
/// command's settings under the command; Menu's Passwords block until then): its length and symbols, and how long the
/// copied password stays before the pasteboard is cleared. Bitwarden's bw makes it. Rows alone, no block: the
/// Abilities list draws them beneath the ability's row.
struct PasswordsBlock: View {
    @Environment(\.ink) private var ink
    @Bindable var settings: PasswordSettings

    init(settings: PasswordSettings = .shared) { self.settings = settings }

    var body: some View {
        VStack(spacing: 0) {
            BlockRow {
                label("Length", "Characters in each new password: upper and lower case and digits, plus symbols when on.")
                Stepper(value: $settings.length, in: PasswordSettings.lengths) {
                    Text("\(settings.length)").font(ink.mono(12)).foregroundStyle(ink.text2)
                }
                .accessibilityLabel("Length").accessibilityValue("\(settings.length) characters")
            }
            BlockRow { Toggle("Symbols", isOn: $settings.symbols).toggleStyle(.pilotSwitchRow(info: "New passwords have symbols such as ! and #; off, for a site that refuses them.")) }
            BlockRow {
                label("Clear after", "The pasteboard is emptied then, unless you copied something else meanwhile.")
                Picker("Clear after", selection: $settings.clearAfter) {
                    ForEach(PasswordSettings.clearChoices, id: \.self) { Text($0 < 120 ? "\($0) seconds" : "\($0 / 60) minutes").tag($0) }
                }
                .labelsHidden().fixedSize()
            }
        }
    }

    private func label(_ title: String, _ info: String) -> some View {
        HStack(spacing: 6) { Text(title); InfoMark(text: info) }.frame(maxWidth: .infinity, alignment: .leading)
    }
}
