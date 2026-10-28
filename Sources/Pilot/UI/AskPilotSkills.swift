import PilotCore
import SwiftUI

/// Ask Pilot's Skills (P29, Sven Q268–Q271, 2026-10-18): the "/ Skills" bubble in the input and the list that rises
/// above it, search first when the bubble opens it, filtered by what follows a / typed at the start of an empty field.
/// A pick puts the skill's command and its starter in the chat box as plain text and never sends (Q270 B).
enum AskPilotSkills {
    /// The skills `query` finds, by command, then by title, so the one Return picks for a typed /se is /settings; when
    /// none, by a typo of the title (FuzzyRanker.Filter); all for an empty one.
    static func matching(_ skills: [AISkill], _ query: String) -> [AISkill] {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else { return skills }
        let named = skills.filter { $0.name.hasPrefix(q) }
        return FuzzyRanker.Filter(q).search { test in named + skills.filter { !named.contains($0) && test([$0.title]) } }
    }

    /// The chat box after picking `skill` over `draft`: its command, then the words already typed, else its starter.
    static func draft(picking skill: AISkill, over draft: String) -> String {
        var words = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        // A command already there (a typed /bi, another skill's) gives way.
        if words.hasPrefix("/") { words = words.split(maxSplits: 1, whereSeparator: \.isWhitespace).dropFirst().first.map(String.init) ?? "" }
        return skill.command + " " + (words.isEmpty ? skill.starter : words)
    }
}

/// The input's "/ Skills" bubble, the style's chip: the / key teaches the typed way in.
struct SkillsBubble: View {
    let open: Bool
    let toggle: () -> Void

    var body: some View {
        Button(action: toggle) { Chip(text: "Skills", on: open, count: "/") }
            .buttonStyle(.plain)
            .help("What Pilot knows how to do (or type / in an empty box)")
            .accessibilityLabel("Skills")
    }
}

/// The open list in the style's pop face: one line on what a skill is (P47, Sven on Build 67: "skills should be better
/// explained"), a search field when the bubble opened it, a row per skill (its icon, title and command, what the AI does
/// for you, and its starter as the example; the style's current row on the one Return picks), and the keys in the foot.
struct SkillsList: View {
    @Environment(\.ink) private var ink
    @Environment(\.style) private var style
    let skills: [AISkill]
    let picked: Int
    /// The list's whole height at most: its rows scroll inside what the intro, search and foot leave.
    let room: CGFloat
    /// The bubble's own search field, focused as the list opens; nil when the chat box's typed / is the search.
    var search: Binding<String>?
    var searching: FocusState<Bool>.Binding
    let hover: (Int) -> Void
    let pick: (AISkill) -> Void
    let submit: () -> Void
    let key: (KeyPress) -> KeyPress.Result

    private static let hints: [KeyHint] = [("↵", "put in chat"), ("↑↓", "move"), ("esc", "close")]
    static let intro = "A skill is a job Pilot's AI knows. Pick one, add your details, press Return: it follows that job's steps "
        + "and asks before it changes anything."

    var body: some View {
        KitPopover(width: 540, arrow: false) {
            Text(Self.intro).font(ink.ui(12)).foregroundStyle(ink.text2).fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 8).padding(.top, 4).padding(.bottom, 8)
            if let search {
                SearchBox(prompt: "Search skills", text: search, focused: searching)
                    .onSubmit(submit)
                    .onKeyPress(keys: [.upArrow, .downArrow, .escape], action: key)
                    .padding(.bottom, 6)
            }
            if skills.isEmpty {
                Text("No skill matches").font(ink.ui(12)).foregroundStyle(ink.muted).padding(10)
            }
            // A short window scrolls the rows, the picked one kept in sight.
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(spacing: 0) {
                        ForEach(skills.indices, id: \.self) { i in
                            let skill = skills[i]
                            Button { pick(skill) } label: { row(skill, on: i == picked) }
                                .buttonStyle(.plain)
                                .onHover { if $0 { hover(i) } }
                                .accessibilityLabel(skill.title)
                                .accessibilityHint(skill.description)
                                .id(i)
                        }
                    }
                }
                .scrollBounceBehavior(.basedOnSize)
                .frame(maxHeight: max(120, room - (search == nil ? 110 : 156)))
                .onChange(of: picked) { proxy.scrollTo(picked) }
            }
            foot.padding(.top, 6)
        }
    }

    private func row(_ skill: AISkill, on: Bool) -> some View {
        KitRow(selected: on) {
            Image(systemName: skill.symbol).font(.system(size: 13, weight: .medium)).frame(width: 20)
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 8) {
                    Text(skill.title).font(ink.ui(13, .semibold))
                    Spacer(minLength: 8)
                    Text(skill.command).font(ink.mono(11)).opacity(0.7)
                }
                Text(skill.description).font(ink.ui(12)).opacity(0.8)
                if let example = Self.example(skill) { Text(example).font(ink.ui(11.5)).italic().opacity(0.6) }
            }
        }
        .contentShape(.rect)
    }

    /// The starter as the row's example, an unfinished one ending in an ellipsis: e.g. “Build me a workspace for …”.
    static func example(_ skill: AISkill) -> String? {
        let words = skill.example.trimmingCharacters(in: .whitespaces)
        guard !words.isEmpty else { return nil }
        return "e.g. “" + words + (skill.example.hasSuffix(" ") ? " …" : words.hasSuffix("+") ? "…" : "") + "”"
    }

    @ViewBuilder private var foot: some View {
        if style.kind == .toybox {
            ToyFoot(hints: Self.hints)
        } else {
            HStack(spacing: 14) { ForEach(Self.hints, id: \.key) { InstrumentHint(hint: $0) } }.padding(.horizontal, 6)
        }
    }
}
