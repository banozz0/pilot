import PilotCore
import SwiftUI

/// Binds › Mouse's box and rows (Q257): the box beside the drawing runs the catch (waiting for the press, nothing
/// arrived, a press from another mouse), then the bind sheet picks the action; a row per button lists the same binds,
/// its Sends field starting the same catch. With Hyper held's rows run the same flow for the Hyper actions.
extension MouseButtonsPage {
    // MARK: Box

    @ViewBuilder func box(_ learn: MouseButtons.Learn, target: Int?, hyper: Bool, found: MouseButtons.Found) -> some View {
        let name = target.map { (hyper ? "Hyper + " : "") + MouseKeys.buttonName($0) }
        VStack(alignment: .leading, spacing: 10) {
            switch learn {
            case .listening:
                Text(name ?? "Press the button on your mouse now.").font(ink.ui(13.5, .semibold)).foregroundStyle(ink.text)
                if name != nil { muted(hyper ? "Press it on your mouse now, without Hyper." : "Press it on your mouse now.") }
                HStack(spacing: 12) {
                    SecondsLeft(deadline: deadline, fixed: shown?.left) { Countdown(seconds: $0) }
                    muted(target == nil ? "Then you pick what it runs. It shows in the list below."
                                        : "Pilot takes whatever it sends: a button or a key. Nothing else runs meanwhile.")
                }
                if let note = shown?.note ?? engine.mouseButtons.note { notice(note) }
                HStack(spacing: 8) {
                    if shown?.askAccess ?? engine.mouseButtons.askAccess {
                        Button("Allow…") { engine.mouseButtons.requestAccess() }.buttonStyle(.pilotPrimary)
                            .accessibilityHint("Opens macOS's Input Monitoring prompt")
                    }
                    Text("esc").font(ink.ui(11.5)).foregroundStyle(ink.muted)
                    Spacer(minLength: 8)
                    Button("Cancel") { cancel() }.buttonStyle(.pilot).keyboardShortcut(.cancelAction)
                }
            case .quiet:
                Text(MouseKeys.Catch.quiet(seconds: Int(MouseButtons.quietAfter))).font(ink.ui(13.5, .semibold)).foregroundStyle(ink.text)
                let report = shown.map(\.vendorReport) ?? engine.mouseButtons.vendorReport
                muted(report.map(MouseKeys.Catch.vendorWhy) ?? MouseKeys.Catch.quietWhy)
                HStack(spacing: 8) {
                    Spacer(minLength: 0)
                    Button("Cancel") { cancel() }.buttonStyle(.pilot).keyboardShortcut(.cancelAction)
                    Button("Try again") { press(target, hyper: hyper) }.buttonStyle(.pilotPrimary).keyboardShortcut(.defaultAction)
                }
            case .got(let key, let device):
                if Self.isOtherMouse(device, found: found), !anyway, let device {
                    Text(name ?? "Another button").font(ink.ui(13.5, .semibold)).foregroundStyle(ink.text)
                    notice(MouseKeys.Catch.otherMouse(device.name, not: found.names))
                    HStack(spacing: 8) {
                        Button("Use it anyway") { anyway = true }.buttonStyle(.pilot)
                        Spacer(minLength: 0)
                        Button("Keep waiting") { press(target, hyper: hyper) }.buttonStyle(.pilotPrimary).keyboardShortcut(.defaultAction)
                    }
                } else {
                    Text(name ?? MouseKeys.sends(key)).font(ink.ui(13.5, .semibold)).foregroundStyle(ink.text)
                    muted("Pick what it runs in the bind sheet.")
                }
            case .idle:
                muted("Click a button on the drawing, or a Sends field below, then press that button on your mouse.")
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(ink.raised))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(ink.line2, lineWidth: 1))
    }

    /// Each ring with the key that holds it open, from Keyboard.
    @ViewBuilder var ringKeys: some View {
        let rings = engine.rings.store.rings.rings
        ForEach(Array(rings.enumerated()), id: \.element.id) { i, ring in
            BlockRow(first: i == 0) {
                Text(ring.name).font(ink.ui(12.5)).foregroundStyle(ink.text)
                Spacer(minLength: 8)
                if let key = engine.binds.store.trigger(for: ring.openID) { Kbd(text: key.label, small: true) }
                else { Text("No key").font(ink.ui(12)).foregroundStyle(ink.muted) }
            }
        }
    }

    private func muted(_ text: String) -> some View {
        Text(text).font(ink.ui(12)).foregroundStyle(ink.muted).fixedSize(horizontal: false, vertical: true)
    }

    private func notice(_ text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: "info.circle").foregroundStyle(ink.accent).accessibilityHidden(true)
            Text(text).foregroundStyle(ink.text).fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .font(ink.ui(12))
        .padding(.horizontal, 10).padding(.vertical, 8)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(ink.selection))
    }

    // MARK: Table

    /// A row per button: its name, what it sends (a click starts the catch), what it runs (a click changes it), and ⋯.
    @ViewBuilder func table(_ rows: [Row], learn: MouseButtons.Learn, target: Int?, hyper: Bool) -> some View {
        heading("Button")
        ForEach(rows, id: \.self.id) { row in
            BlockRow { tableRow(row, learn: learn, target: target, hyper: hyper) }
        }
        if learn == .listening, target == nil {
            BlockRow {
                columns(name("?", "New button"),
                        field(on: true) { waitingText(nil) },
                        field { Text("Nothing").foregroundStyle(ink.muted) },
                        Color.clear.frame(width: 1, height: 1))
            }
        }
        BlockRow {
            Button("＋ Other button…") { press(nil) }.buttonStyle(.pilot)
            Text("For a button the drawing lacks.").font(ink.ui(12)).foregroundStyle(ink.muted)
            Spacer(minLength: 0)
        }
    }

    /// With Hyper held (P51): a row per button and two for the wheel, each running the flow for its Hyper action; a note
    /// when Hyper is the drag modifier, which keeps left and right for moving and resizing windows.
    @ViewBuilder func hyperTable(_ rows: [Row], learn: MouseButtons.Learn, target: Int?, hyper: Bool, dragsWithHyper: Bool) -> some View {
        heading("Hyper +", first: true)
        ForEach(rows, id: \.self.id) { row in
            BlockRow { tableRow(row, learn: learn, target: target, hyper: hyper) }
        }
        BlockRow {
            muted("A wheel direction with no action steps through workspaces by notch."
                  + (dragsWithHyper ? " Left and right stay out: Hyper + drag moves and resizes windows (Tiling › Drag modifier)." : ""))
            Spacer(minLength: 0)
        }
    }

    private func heading(_ name: String, first: Bool = false) -> some View {
        BlockRow(first: first) {
            columns(Text(name), Text("Sends"), Text("Runs"), Color.clear.frame(width: 1, height: 1))
                .font(ink.ui(10.5, .semibold)).textCase(.uppercase).foregroundStyle(ink.muted)
        }
    }

    @ViewBuilder private func tableRow(_ row: Row, learn: MouseButtons.Learn, target: Int?, hyper: Bool) -> some View {
        let wheel = row.isWheel
        let mine = row.hyper == hyper && row.button != nil && row.button == target
        let caught: (key: Key, device: MouseKeys.Device?)? = if case .got(let key, let device) = learn, row.hyper == hyper,
            row.button != nil ? Self.button(of: key, target: target) == row.button : wheel && key == row.sends { (key, device) } else { nil }
        columns(
            name(row.button.map(String.init) ?? (wheel ? (row.sends == MouseKeys.scrollUp ? "↑" : "↓") : ""), row.name),
            Button { if !wheel { press(row.button, hyper: row.hyper) } } label: {
                field(on: mine && learn == .listening) {
                    if mine && learn == .listening {
                        waitingText(row.name)
                    } else if mine && learn == .quiet {
                        Text("Nothing in \(Int(MouseButtons.quietAfter)) s · ").foregroundStyle(ink.text2) + Text("Try again").foregroundStyle(ink.accentText)
                    } else if let sent = caught ?? (row.trigger ?? row.sends).map({ ($0, row.device) }) {
                        sends(sent.key, device: sent.device)
                    } else {
                        Text("Click, then press it").foregroundStyle(ink.muted)
                    }
                }
            }
            .buttonStyle(.plain)
            .disabled(wheel)
            .accessibilityLabel("\(row.name) sends")
            .accessibilityHint(wheel ? "" : "Starts the catch: press the button on your mouse"),
            Button { change(row) } label: {
                field(on: caught != nil) {
                    if caught != nil {
                        Text("Pick what it runs").foregroundStyle(ink.accentText)
                    } else {
                        Text(row.runs ?? (wheel ? "Steps workspaces" : "Nothing")).foregroundStyle(row.runs == nil ? ink.muted : ink.text)
                    }
                }
            }
            .buttonStyle(.plain)
            .accessibilityLabel("\((row.hyper ? "Hyper + " : "") + row.name) runs \(row.label ?? "nothing")"),
            more(row)
        )
    }

    /// A bound row's ⋯: Change action, Press it again (not the wheel's), Remove.
    @ViewBuilder private func more(_ row: Row) -> some View {
        if row.trigger != nil {
            Menu {
                Button("Change action") { change(row) }
                if !row.isWheel { Button("Press it again") { press(row.button, hyper: row.hyper) } }
                Divider()
                Button("Remove") { remove(row) }
            } label: {
                Image(systemName: "ellipsis").foregroundStyle(ink.muted).frame(width: 26, height: 26).contentShape(.rect)
            }
            .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize()
            .accessibilityLabel("More for \(row.name)")
        } else {
            Color.clear.frame(width: 26, height: 1)
        }
    }

    private func columns(_ a: some View, _ b: some View, _ c: some View, _ d: some View) -> some View {
        HStack(spacing: 10) {
            a.frame(width: 120, alignment: .leading)
            b.frame(maxWidth: .infinity, alignment: .leading)
            c.frame(maxWidth: .infinity, alignment: .leading)
            d.frame(width: 26)
        }
    }

    private func name(_ number: String, _ name: String) -> some View {
        HStack(spacing: 7) {
            if !number.isEmpty {
                Text(number).font(ink.mono(9.5, weight: .semibold)).foregroundStyle(ink.muted)
                    .padding(.horizontal, 4).padding(.vertical, 1)
                    .background(RoundedRectangle(cornerRadius: 4).fill(ink.raised))
                    .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(ink.line2, lineWidth: 1))
            }
            Text(name).font(ink.ui(12.5)).foregroundStyle(ink.text).lineLimit(1)
        }
    }

    private func field(on: Bool = false, @ViewBuilder _ content: () -> some View) -> some View {
        HStack(spacing: 6) { content() }
            .font(ink.ui(12)).lineLimit(1)
            .padding(.horizontal, 9).frame(maxWidth: .infinity, minHeight: 28, maxHeight: 28, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(ink.well))
            .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous).strokeBorder(on ? ink.accent : ink.line2, lineWidth: on ? 2 : 1))
            .contentShape(.rect)
    }

    @ViewBuilder private func sends(_ key: Key, device: MouseKeys.Device?) -> some View {
        Kbd(text: MouseKeys.sends(key), small: true)
        if let device { Text(device.name).font(ink.ui(10.5)).foregroundStyle(ink.muted).truncationMode(.tail) }
    }

    /// "Press Back now… 6 s", counting down.
    private func waitingText(_ name: String?) -> some View {
        let lead = name.map { "Press \($0) now…" } ?? "Press it now…"
        return SecondsLeft(deadline: deadline, fixed: shown?.left) { Text("\(lead) \($0) s") }.foregroundStyle(ink.accentText)
    }

    /// When the catch's wait runs out; nil in a render.
    private var deadline: Date? { shown == nil ? engine.mouseButtons.deadline : nil }
}

extension MouseButtonsPage.Row {
    /// A row's identity in its list: its button, else its trigger, else what it sends (the wheel's).
    var id: String { button.map { "b\($0)" } ?? (trigger ?? sends).map { "k\($0.keyCode)" } ?? "" }
}

/// The seconds left of the catch's wait, ticking once a second while it runs; `fixed` (a render) or the whole wait otherwise.
struct SecondsLeft<Content: View>: View {
    let deadline: Date?
    var fixed: Int?
    @ViewBuilder let content: (Int) -> Content

    var body: some View {
        if let deadline {
            TimelineView(.periodic(from: .now, by: 1)) { context in
                content(max(0, Int(deadline.timeIntervalSince(context.date).rounded(.up))))
            }
        } else {
            content(fixed ?? Int(MouseButtons.quietAfter))
        }
    }
}

/// The catch's ring: the seconds left of its wait, counting down.
struct Countdown: View {
    @Environment(\.ink) private var ink
    let seconds: Int

    var body: some View {
        ZStack {
            TimerRing(left: Double(seconds) / MouseButtons.quietAfter, lineWidth: 3, track: ink.line2, tint: ink.accent)
                .animation(.linear(duration: 1), value: seconds)
            Text("\(seconds)").font(ink.mono(13, weight: .semibold)).foregroundStyle(ink.accentText)
        }
        .frame(width: 38, height: 38)
        .accessibilityElement().accessibilityLabel("\(seconds) seconds left")
    }
}
