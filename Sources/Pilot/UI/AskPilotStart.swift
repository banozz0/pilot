import PilotCore
import SwiftUI

/// Ask Pilot's empty chat (Sven 2026-10-16, Q177): Pilot's mark, "What should Pilot do?", the way to the skills, whose
/// bubble in the input took the starters (P29, Q271), then what the agent changes, asks first and can't do. In a scroll
/// centred in the chat, so a short window keeps all of it. Codex's sign-in to Pilot's own Codex home comes before it
/// (CodexSignIn, Q203).
struct AskPilotStart: View {
    @Environment(\.ink) private var ink
    let provider: AIProvider
    /// Claude Code, which runs the makers, is not known to be missing.
    let makes: Bool

    var body: some View {
        GeometryReader { g in
            ScrollView {
                content.frame(maxWidth: 720).frame(maxWidth: .infinity, minHeight: g.size.height)
            }
            .scrollBounceBehavior(.basedOnSize)
        }
    }

    private var content: some View {
        VStack(spacing: 0) {
            InstrumentMark(size: 30).padding(.bottom, 14)
            Text("What should Pilot do?").font(ink.ui(19, .semibold)).foregroundStyle(ink.text)
                .accessibilityAddTraits(.isHeader)
            Text("Type it, or press / Skills for what Pilot knows how to do.")
                .font(ink.ui(13)).foregroundStyle(ink.text2).padding(.top, 6)
            let notes = (makes ? [] : ["Making extensions and widgets needs Claude Code installed, whichever provider you chat with."])
                + (provider.command == nil ? ["A model that takes no tools only explains Pilot, and says so."] : [])
            if !notes.isEmpty {
                Text(notes.joined(separator: " "))
                    .font(ink.ui(12)).foregroundStyle(ink.muted).padding(.top, 14)
            }
            reach.padding(.top, 22)
        }
        .multilineTextAlignment(.center)
        .padding(.vertical, 16)
    }

    private var reach: some View {
        HStack(alignment: .top, spacing: 18) {
            ForEach(AIPage.reach, id: \.title) { part in
                VStack(alignment: .leading, spacing: 3) {
                    Text(part.title).font(ink.ui(11.5, .semibold)).foregroundStyle(ink.text2)
                    Text(part.text).font(ink.ui(11.5)).foregroundStyle(ink.muted).fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityElement(children: .combine)
            }
        }
        .multilineTextAlignment(.leading)
        .padding(.horizontal, 2)
    }
}

/// Codex's empty chat while Pilot's own Codex home has no sign-in (Q203): Pilot runs codex apart from the person's own
/// setup, so it signs in once here, codex's own sign-in in the browser (AISettings.connect), then the starters show.
struct CodexSignIn: View {
    @Environment(\.ink) private var ink
    let waiting: Bool
    let problem: String?
    let signIn: () -> Void
    let cancel: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            AIPage.mark(.codex, size: 36).padding(.bottom, 14)
            Text("Sign in to Codex").font(ink.ui(19, .semibold)).foregroundStyle(ink.text).accessibilityAddTraits(.isHeader)
            Text("Pilot keeps its own Codex sign-in, apart from your own Codex setup, so Codex can only run pilot commands here.")
                .font(ink.ui(13)).foregroundStyle(ink.text2).padding(.top, 6).frame(maxWidth: 440)
            Text(waiting ? "Finish signing in to ChatGPT in your browser." : "Sign in once with your ChatGPT account; it opens in your browser.")
                .font(ink.ui(12)).foregroundStyle(ink.muted).padding(.top, 10)
            HStack(spacing: 8) {
                if waiting {
                    ProgressView().controlSize(.small)
                    Button("Cancel", action: cancel).buttonStyle(.pilot)
                } else {
                    Button("Sign in to Codex", action: signIn).buttonStyle(.pilotPrimary)
                }
            }
            .padding(.top, 18)
            if let problem { FinePrint(text: problem, color: ink.red).padding(.top, 10).frame(maxWidth: 440) }
        }
        .multilineTextAlignment(.center)
        .padding(.bottom, 24)
    }
}
