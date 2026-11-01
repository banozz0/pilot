import AppKit
import PilotCore
import SwiftUI

/// Pilot's own Allow prompt for the control gate (ADR 0013): a HUD naming the asking program and the exact thing, whole,
/// Deny first and the default, Escape denying. It never takes focus from Sven's window, so no key he is typing can allow.
/// One shows at a time; a second ask waits its turn, and the gate's clock runs while it waits. While the AI chat shows a
/// turn running a `pilot` command, the question goes on that command's row instead (T16), the same words and answers.
@MainActor
enum AllowPrompt {
    /// The gate every verb family asks through.
    static let gate = ControlGate { ask, peer in await decide(ask, peer: peer) }
    /// Where else the question may go first, given who asks: Allow or Deny, or nil when it is not shown there. The AI chat
    /// signs its own up (AIChatPanel.shared); none, and the HUD asks.
    static var inline: (@MainActor (ControlGate.Ask, String) async -> Bool?)?
    private static var turn: Task<Bool, Never>?
    private static var open: (panel: NSPanel, answer: CheckedContinuation<Bool, Never>)?
    /// Which showing the panel is, so a late cancel closes its own and never the next one's.
    private static var showing = 0

    /// Shows the question once every earlier one is answered; cancelled (the gate's clock ran out), it closes or never shows.
    static func decide(_ ask: ControlGate.Ask, peer: ControlPeer?) async -> Bool {
        let before = turn
        let mine = Task {
            _ = await before?.value
            if !Task.isCancelled, let answer = await inline?(ask, program(peer)) { return answer }
            return Task.isCancelled ? false : await show(ask, peer: peer)
        }
        turn = mine
        return await withTaskCancellationHandler { await mine.value } onCancel: { mine.cancel() }
    }

    private static func show(_ ask: ControlGate.Ask, peer: ControlPeer?) async -> Bool {
        showing += 1
        let mine = showing
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                let p = HUD.makePanel(AllowPromptView(program: program(peer), ask: ask) { close(allowing: $0) }
                    .onGeometryChange(for: CGSize.self, of: \.size) { refit($0, mine) })
                p.escape = { close(allowing: false) }
                p.orderFrontRegardless()
                open = (p, continuation)
            }
        } onCancel: {
            Task { @MainActor in if showing == mine { close(allowing: false) } }
        }
    }

    /// The panel fitted about its centre to the prompt's new size, as Show details opens or closes; nothing once another
    /// showing replaced it.
    private static func refit(_ face: CGSize, _ mine: Int) {
        guard showing == mine, let panel = open?.panel as? KeyPanel else { return }
        let size = PopSurface.window(face, panel.margins)
        guard abs(panel.frame.width - size.width) >= 1 || abs(panel.frame.height - size.height) >= 1 else { return }
        panel.setFrame(CGRect(x: panel.frame.midX - size.width / 2, y: panel.frame.midY - size.height / 2,
                              width: size.width, height: size.height), display: true)
    }

    private static func close(allowing allowed: Bool) {
        guard let (panel, answer) = open else { return }
        open = nil
        panel.orderOut(nil)
        answer.resume(returning: allowed)
    }

    /// The program behind the request: the peer is the pilot command, so its first ancestor that is not a shell, as
    /// "pilot, from claude"; the peer's own name when none is found. Each name is the one the process gave itself.
    static func program(_ peer: ControlPeer?) -> String {
        guard let peer, let own = process(peer.pid) else { return "a program" }
        var parent = own.parent
        for _ in 0..<4 {
            guard parent > 1, let p = process(parent) else { break }
            if !shells.contains(p.name) { return "\(own.name), from \(p.name)" }
            parent = p.parent
        }
        return own.name
    }

    private static let shells: Set<String> = ["sh", "bash", "zsh", "fish", "dash", "login", "-zsh", "-bash"]

    /// A process's short name and parent, from the kernel's process table.
    private static func process(_ pid: pid_t) -> (name: String, parent: pid_t)? {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.size
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        guard sysctl(&mib, 4, &info, &size, nil, 0) == 0, size > 0 else { return nil }
        let name = withUnsafeBytes(of: info.kp_proc.p_comm) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
        return (name, info.kp_eproc.e_ppid)
    }
}

extension ControlGate.Ask {
    /// The question running action `id` asks, its quicklink or extension command read from the live stores.
    @MainActor static func running(_ id: String) -> Self? {
        run(id, quicklinks: QuicklinkBook.shared.links, extensions: Extension.find().extensions)
    }
}

/// The prompt's face: the extension alert in Sven's style, naming who asks, then the exact thing whole with every hidden
/// character written out (ControlGate.Ask.visible; the gate denies one too long to show whole), then Deny, primary, and
/// Allow. An ask with a summary leads with its headline and short lines instead, the whole behind Show details, which
/// answers nothing.
struct AllowPromptView: View {
    @Environment(\.style) private var style
    let program: String
    let ask: ControlGate.Ask
    @State var details = false
    let answer: (Bool) -> Void

    var body: some View {
        // The kinds never run: a press answers by its index, and the first button, Deny, is the primary one.
        let buttons = [Extension.Item.Action(kind: .hud("Deny"), title: "Deny"), Extension.Item.Action(kind: .hud("Allow"), title: "Allow")]
        let toggle = ask.summary.map { _ in
            AnyView(Button(details ? "Hide details" : "Show details") { details.toggle() }
                .buttonStyle(.plain).styleText(\.caption).foregroundStyle(style.color(\.text2)).padding(.trailing, 6))
        }
        ExtensionAlertView(alert: Extension.AlertSpec(text: Self.heading(ask, program), note: Self.note(ask, program, details: details),
                                                      actions: buttons), extra: toggle) {
            answer($0 == 1)
        }
        .frame(width: 480)
        .fixedSize(horizontal: false, vertical: true)
    }

    // The words both faces say, the HUD and the chat's row (T16).

    /// "Allow pilot, from claude?"
    static func question(_ program: String) -> String { "Allow \(ControlGate.Ask.visible(program))?" }

    /// The summary's headline, else who asks.
    static func heading(_ ask: ControlGate.Ask, _ program: String) -> String {
        ask.summary.map { line($0.headline) } ?? question(program)
    }

    /// The summary's lines, one each.
    static func points(_ summary: ControlGate.Ask.Summary) -> String { summary.points.map(line).joined(separator: "\n") }

    /// `text` escaped as the thing is, but a line break inside it only marked ⏎, so a path or a name in a summary can
    /// never start a line of its own that reads as Pilot's.
    static func line(_ text: String) -> String { ControlGate.Ask.visible(text).replacingOccurrences(of: "⏎\n", with: "⏎", options: .literal) }

    /// Under the heading: the summary's lines, or with `details` the thing whole, then who asks and the warning; an ask
    /// with no summary shows the thing whole and the warning, as it always has.
    static func note(_ ask: ControlGate.Ask, _ program: String, details: Bool) -> String {
        guard let summary = ask.summary else { return thing(ask, joiner: ":\n") + "\n\n" + warning }
        let asked = "Asked by \(ControlGate.Ask.visible(program))."
        if details { return thing(ask, joiner: ":\n") + "\n\n" + asked + " " + warning }
        return points(summary) + "\n\n" + asked + " " + deadline
    }

    /// "Run shell: brew upgrade", every hidden character written out; a plan's rows a line each, a line break inside one
    /// written out; an ask's own lines a line each, a line break inside one only marked ⏎ (`line`).
    static func thing(_ ask: ControlGate.Ask, joiner: String = ": ") -> String {
        let detail = !ask.rows.isEmpty ? ask.rows.map { ControlGate.Ask.visible($0.line) }.joined(separator: "\n")
            : ask.lines.map { $0.map(line).joined(separator: "\n") } ?? ControlGate.Ask.visible(ask.detail)
        return ControlGate.Ask.visible(ask.title) + joiner + detail
    }

    static let warning = "Program names are what each process calls itself. Nothing runs unless you press Allow; no answer in "
        + "\(ControlGate.wait.components.seconds) s denies."
    static let deadline = "No answer in \(ControlGate.wait.components.seconds) s denies."
}
